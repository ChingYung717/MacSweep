import Darwin
import Foundation

public struct MemoryReleaseService: Sendable {
    public typealias SnapshotProvider = @Sendable () -> MemorySnapshot
    public typealias StandardReliefHandler = @Sendable () -> Void
    public typealias ElevatedPurgeHandler = @Sendable () throws -> Void

    public let privilegedExecutor: PrivilegedExecutor
    private let snapshotProvider: SnapshotProvider?
    private let standardReliefHandler: StandardReliefHandler?
    private let elevatedPurgeHandler: ElevatedPurgeHandler?

    public init(privilegedExecutor: PrivilegedExecutor = PrivilegedExecutor()) {
        self.privilegedExecutor = privilegedExecutor
        self.snapshotProvider = nil
        self.standardReliefHandler = nil
        self.elevatedPurgeHandler = nil
    }

    internal init(
        privilegedExecutor: PrivilegedExecutor = PrivilegedExecutor(),
        snapshotProvider: SnapshotProvider? = nil,
        standardReliefHandler: StandardReliefHandler? = nil,
        elevatedPurgeHandler: ElevatedPurgeHandler? = nil
    ) {
        self.privilegedExecutor = privilegedExecutor
        self.snapshotProvider = snapshotProvider
        self.standardReliefHandler = standardReliefHandler
        self.elevatedPurgeHandler = elevatedPurgeHandler
    }

    public func captureSnapshot() -> MemorySnapshot {
        if let snapshotProvider {
            return snapshotProvider()
        }
        return Self.readLiveMachSnapshot()
    }

    public func releaseMemory(allowElevation: Bool) async throws -> MemoryReleaseResult {
        if allowElevation {
            return try await performElevatedPurge()
        } else {
            return await performStandardRelief()
        }
    }

    public func performStandardRelief() async -> MemoryReleaseResult {
        let before = captureSnapshot()
        if let standardReliefHandler {
            standardReliefHandler()
        } else {
            _ = Darwin.malloc_zone_pressure_relief(nil, 0)
            URLCache.shared.removeAllCachedResponses()
        }
        let after = captureSnapshot()
        let freeGain = after.freeBytes > before.freeBytes ? (after.freeBytes - before.freeBytes) : 0
        let estimate = min(before.totalBytes, freeGain)
        return MemoryReleaseResult(
            before: before,
            after: after,
            reclaimedEstimateBytes: estimate,
            methodUsed: "standard_pressure_relief",
            usedElevation: false,
            note: "Trimmed MacSweep's own heap and URL caches. macOS manages inactive memory automatically; clearing system disk caches requires administrator purge."
        )
    }

    public func performElevatedPurge() async throws -> MemoryReleaseResult {
        try Task.checkCancellation()
        let before = captureSnapshot()
        try Task.checkCancellation()
        if let elevatedPurgeHandler {
            try elevatedPurgeHandler()
        } else {
            _ = try privilegedExecutor.runWithAdministratorPrivileges(shellCommand: "/usr/sbin/purge")
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        try Task.checkCancellation()
        let after = captureSnapshot()
        let freeGain = after.freeBytes > before.freeBytes ? (after.freeBytes - before.freeBytes) : 0
        let cachedDrop = before.cachedFilesBytes > after.cachedFilesBytes ? (before.cachedFilesBytes - after.cachedFilesBytes) : 0
        let estimate = min(before.totalBytes, freeGain)
        return MemoryReleaseResult(
            before: before,
            after: after,
            reclaimedEstimateBytes: estimate,
            methodUsed: "purge",
            usedElevation: true,
            note: "Executed /usr/sbin/purge to flush kernel disk buffers and inactive file caches (cached delta: \(cachedDrop) bytes)."
        )
    }

    // MARK: - Live Darwin / Mach VM Snapshot

    private static func readLiveMachSnapshot() -> MemorySnapshot {
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        let hostPort = mach_host_self()
        defer {
            if hostPort != mach_port_t(MACH_PORT_NULL) {
                mach_port_deallocate(mach_task_self_, hostPort)
            }
        }

        var pageSizeVM: vm_size_t = 0
        let pageSizeBytes: UInt64
        if host_page_size(hostPort, &pageSizeVM) == KERN_SUCCESS, pageSizeVM > 0 {
            pageSizeBytes = UInt64(pageSizeVM)
        } else {
            var sysPage: UInt64 = 0
            var len = MemoryLayout<UInt64>.size
            if sysctlbyname("vm.pagesize", &sysPage, &len, nil, 0) == 0, sysPage > 0 {
                pageSizeBytes = sysPage
            } else {
                let sc = sysconf(_SC_PAGESIZE)
                pageSizeBytes = sc > 0 ? UInt64(sc) : 16_384
            }
        }

        var vmStats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr: kern_return_t = withUnsafeMutablePointer(to: &vmStats) { statsPtr in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }

        let activeBytes: UInt64
        let inactiveBytes: UInt64
        let wiredBytes: UInt64
        let compressedBytes: UInt64
        let cachedFilesBytes: UInt64
        let appMemoryBytes: UInt64
        let freeBytes: UInt64

        if kr == KERN_SUCCESS {
            activeBytes = UInt64(vmStats.active_count) &* pageSizeBytes
            inactiveBytes = UInt64(vmStats.inactive_count) &* pageSizeBytes
            wiredBytes = UInt64(vmStats.wire_count) &* pageSizeBytes
            compressedBytes = UInt64(vmStats.compressor_page_count) &* pageSizeBytes
            cachedFilesBytes = (UInt64(vmStats.external_page_count) &+ UInt64(vmStats.purgeable_count)) &* pageSizeBytes
            let appPages = vmStats.internal_page_count > vmStats.purgeable_count
                ? (vmStats.internal_page_count - vmStats.purgeable_count)
                : 0
            appMemoryBytes = UInt64(appPages) &* pageSizeBytes
            freeBytes = UInt64(vmStats.free_count) &* pageSizeBytes
        } else {
            activeBytes = 0
            inactiveBytes = 0
            wiredBytes = 0
            compressedBytes = 0
            cachedFilesBytes = 0
            appMemoryBytes = 0
            freeBytes = 0
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        var swapUsedBytes: UInt64 = 0
        var swapTotalBytes: UInt64 = 0
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            swapTotalBytes = swap.xsu_total
            swapUsedBytes = min(swap.xsu_used, swap.xsu_total)
        }

        var pressureRaw: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        let pressureLevel: MemoryPressureLevel
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureRaw, &pressureSize, nil, 0) == 0 {
            switch pressureRaw {
            case ...1:
                pressureLevel = .normal
            case 2...3:
                pressureLevel = .warning
            default:
                pressureLevel = .critical
            }
        } else {
            let used = min(totalBytes, appMemoryBytes &+ wiredBytes &+ compressedBytes)
            let ratio = totalBytes > 0 ? Double(used) / Double(totalBytes) : 0
            if ratio >= 0.88 {
                pressureLevel = .critical
            } else if ratio >= 0.72 {
                pressureLevel = .warning
            } else {
                pressureLevel = .normal
            }
        }

        return MemorySnapshot(
            capturedAt: Date(),
            totalBytes: totalBytes,
            activeBytes: activeBytes,
            inactiveBytes: inactiveBytes,
            wiredBytes: wiredBytes,
            compressedBytes: compressedBytes,
            cachedFilesBytes: cachedFilesBytes,
            appMemoryBytes: appMemoryBytes,
            freeBytes: freeBytes,
            swapUsedBytes: swapUsedBytes,
            swapTotalBytes: swapTotalBytes,
            pageSizeBytes: pageSizeBytes,
            pressureLevel: pressureLevel
        )
    }
}

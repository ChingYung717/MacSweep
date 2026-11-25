import Darwin
import E2EHarness
import Foundation
import MacSweepCore

let runner = E2ERunner(probeName: "E2EM2Probe")

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiskScanProgress] = []

    func record(_ event: DiskScanProgress) {
        lock.withLock { events.append(event) }
    }

    func snapshot() -> [DiskScanProgress] {
        lock.withLock { events }
    }
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { cont in
            let shouldResumeImmediately: Bool = lock.withLock {
                if isOpen {
                    return true
                }
                continuation = cont
                return false
            }
            if shouldResumeImmediately {
                cont.resume()
            }
        }
    }

    func open() {
        let cont: CheckedContinuation<Void, Never>? = lock.withLock {
            isOpen = true
            let c = continuation
            continuation = nil
            return c
        }
        cont?.resume()
    }
}

private final class CancelProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var _invoked = false
    private var _progressEvents: [DiskScanProgress] = []
    private var _taskToCancel: Task<Void, Error>?

    func markInvoked() {
        lock.withLock { _invoked = true }
    }

    func setTaskToCancel(_ task: Task<Void, Error>) {
        lock.withLock { _taskToCancel = task }
    }

    func recordProgressAndCancel(_ progress: DiskScanProgress) {
        let task: Task<Void, Error>? = lock.withLock {
            _progressEvents.append(progress)
            return _taskToCancel
        }
        task?.cancel()
    }

    var invoked: Bool {
        lock.withLock { _invoked }
    }

    var progressEvents: [DiskScanProgress] {
        lock.withLock { _progressEvents }
    }
}

private func setFileTimes(at url: URL, accessDate: Date, modificationDate: Date) throws {
    let atimeSec = accessDate.timeIntervalSince1970
    let mtimeSec = modificationDate.timeIntervalSince1970
    var times = [
        timeval(tv_sec: Int(atimeSec), tv_usec: 0),
        timeval(tv_sec: Int(mtimeSec), tv_usec: 0),
    ]
    guard Darwin.utimes(url.path, &times) == 0 else {
        throw E2EAssertionFailure("utimes failed for \(url.path): errno=\(errno)")
    }
}

private func allocatedBytesViaLstat(_ url: URL) throws -> UInt64 {
    var st = stat()
    guard Darwin.lstat(url.path, &st) == 0 else {
        throw E2EAssertionFailure("lstat failed for \(url.path): errno=\(errno)")
    }
    if st.st_blocks > 0 {
        return UInt64(st.st_blocks) * 512
    }
    return UInt64(max(0, st.st_size))
}

private func minimalValidPNGData() -> Data {
    // Valid 1x1 RGB PNG (69 bytes)
    Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x03, 0x01, 0x01, 0x00, 0xC9, 0xFE, 0x92,
        0xEF, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    ])
}

// MARK: - F-4: Disk Space Analyzer (5 Tier 1 + 5 Tier 2)

runner.register(
    id: "f4-analyze-tree-totals-and-sort",
    tier: 1,
    feature: "F-4",
    name: "DiskSpaceAnalyzer.analyze computes exact recursive bytes, counts, descending child sort, and canonical parents"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f4-tree")
    defer { sandbox.cleanup() }

    let alpha = try sandbox.createExactSizeFile("Alpha/a.bin", byteCount: 16_384)
    let beta1 = try sandbox.createExactSizeFile("Beta/b1.bin", byteCount: 8_192)
    let beta2 = try sandbox.createExactSizeFile("Beta/Deep/b2.bin", byteCount: 65_536)
    let gamma = try sandbox.createExactSizeFile("Gamma/g.bin", byteCount: 4_096)
    _ = try sandbox.createDirectory("EmptyDir")

    let expectedAlpha = try allocatedBytesViaLstat(alpha)
    let expectedBeta = try allocatedBytesViaLstat(beta1) + (try allocatedBytesViaLstat(beta2))
    let expectedGamma = try allocatedBytesViaLstat(gamma)
    let expectedTotal = expectedAlpha + expectedBeta + expectedGamma

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let analyzer = DiskSpaceAnalyzer(safetyGuard: sg)
    let root = try await analyzer.analyze(root: sandbox.rootURL, maxDepth: 5)

    try E2ERunner.expectEqual(root.bytes, expectedTotal)
    try E2ERunner.expectEqual(root.fileCount, 4)
    try E2ERunner.expectEqual(root.folderCount, 5) // Alpha, Beta, Deep, Gamma, EmptyDir
    try E2ERunner.expect(!root.isTruncated)
    try E2ERunner.expect(!root.hasTruncatedDescendant)
    try E2ERunner.expectEqual(root.expectedCanonicalParent, sandbox.canonicalParentPath(for: sandbox.rootURL))

    // Descending byte order: Beta > Alpha > Gamma > EmptyDir (0)
    try E2ERunner.expectEqual(root.children.map(\.name), ["Beta", "Alpha", "Gamma", "EmptyDir"])
    let betaNode = try E2ERunner.expectNotNil(root.children.first { $0.name == "Beta" })
    try E2ERunner.expectEqual(betaNode.bytes, expectedBeta)
    try E2ERunner.expectEqual(betaNode.fileCount, 2)
    try E2ERunner.expectEqual(betaNode.folderCount, 1)
    try E2ERunner.expectEqual(betaNode.expectedCanonicalParent, sandbox.canonicalRootPath)

    let emptyNode = try E2ERunner.expectNotNil(root.children.first { $0.name == "EmptyDir" })
    try E2ERunner.expectEqual(emptyNode.bytes, 0)
    try E2ERunner.expectEqual(emptyNode.fileCount, 0)
    try E2ERunner.expect(!emptyNode.isTruncated)
}

runner.register(
    id: "f4-volume-info-and-mounted-volumes",
    tier: 1,
    feature: "F-4",
    name: "DiskSpaceAnalyzer.volumeInfo and mountedVolumes report valid capacity breakdown with root volume first"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f4-vol")
    defer { sandbox.cleanup() }

    let info = try DiskSpaceAnalyzer.volumeInfo(for: sandbox.rootURL)
    try E2ERunner.expect(info.totalBytes > 0, "totalBytes must be > 0")
    try E2ERunner.expectEqual(info.usedBytes + info.availableBytes, info.totalBytes)
    try E2ERunner.expect(info.usedFraction >= 0.0 && info.usedFraction <= 1.0, "usedFraction out of bounds")
    try E2ERunner.expect(!info.isReadOnly, "Temp volume should be writable")

    let volumes = DiskSpaceAnalyzer.mountedVolumes()
    try E2ERunner.expect(!volumes.isEmpty, "mountedVolumes must not be empty")
    try E2ERunner.expectEqual(volumes.first?.id, "/", "Root volume '/' should be sorted first")
}

runner.register(
    id: "f4-filter-size-age-search",
    tier: 1,
    feature: "F-4",
    name: "DiskSpaceAnalyzer.filterNodes and findMatchingFiles accurately filter by minBytes, olderThanDays, searchText, and ageBasis"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f4-filter")
    defer { sandbox.cleanup() }

    let bigOld = try sandbox.createExactSizeFile("Builds/archive-old.tar", byteCount: 120_000)
    let bigNew = try sandbox.createExactSizeFile("Builds/archive-fresh.tar", byteCount: 120_000)
    let smallOld = try sandbox.createExactSizeFile("Docs/small-old.txt", byteCount: 4_096)

    let now = Date()
    let oldDate = now.addingTimeInterval(-200 * 86_400)
    let recentDate = now.addingTimeInterval(-5 * 86_400)

    try setFileTimes(at: bigOld, accessDate: recentDate, modificationDate: oldDate)
    try setFileTimes(at: bigNew, accessDate: recentDate, modificationDate: recentDate)
    try setFileTimes(at: smallOld, accessDate: oldDate, modificationDate: oldDate)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let analyzer = DiskSpaceAnalyzer(safetyGuard: sg)
    let root = try await analyzer.analyze(root: sandbox.rootURL, maxDepth: 4)

    let filterMod = DiskEntryFilter(
        minBytes: 50_000,
        olderThanDays: 90,
        ageBasis: .modificationDate,
        scope: .filesAndPackages,
        searchText: "ARCHIVE"
    )
    let nodeMatches = DiskSpaceAnalyzer.filterNodes(in: root, filter: filterMod, referenceDate: now)
    let diskMatches = try await analyzer.findMatchingFiles(under: sandbox.rootURL, filter: filterMod, referenceDate: now)

    try E2ERunner.expectEqual(nodeMatches.count, 1)
    try E2ERunner.expectEqual(nodeMatches.first?.name, "archive-old.tar")
    try E2ERunner.expectEqual(nodeMatches.first?.expectedCanonicalParent, sandbox.canonicalParentPath(for: bigOld))
    try E2ERunner.expectEqual(diskMatches.map(\.id), nodeMatches.map(\.id))

    // Distinct mtime (200d old) vs atime (5d old): .accessDate and .latestOfModificationAndAccess must exclude bigOld when olderThanDays = 90
    let filterAcc = DiskEntryFilter(
        minBytes: 50_000,
        olderThanDays: 90,
        ageBasis: .accessDate,
        scope: .filesAndPackages,
        searchText: "ARCHIVE"
    )
    let filterLatest = DiskEntryFilter(
        minBytes: 50_000,
        olderThanDays: 90,
        ageBasis: .latestOfModificationAndAccess,
        scope: .filesAndPackages,
        searchText: "ARCHIVE"
    )
    try E2ERunner.expect(DiskSpaceAnalyzer.filterNodes(in: root, filter: filterAcc, referenceDate: now).isEmpty)
    try E2ERunner.expect(try await analyzer.findMatchingFiles(under: sandbox.rootURL, filter: filterAcc, referenceDate: now).isEmpty)
    try E2ERunner.expect(DiskSpaceAnalyzer.filterNodes(in: root, filter: filterLatest, referenceDate: now).isEmpty)
    try E2ERunner.expect(try await analyzer.findMatchingFiles(under: sandbox.rootURL, filter: filterLatest, referenceDate: now).isEmpty)

    // When bigOld's atime is also aged to 200d old, both .accessDate and .latestOfModificationAndAccess must include it
    try setFileTimes(at: bigOld, accessDate: oldDate, modificationDate: oldDate)
    let accMatches = try await analyzer.findMatchingFiles(under: sandbox.rootURL, filter: filterAcc, referenceDate: now)
    let latestMatches = try await analyzer.findMatchingFiles(under: sandbox.rootURL, filter: filterLatest, referenceDate: now)
    try E2ERunner.expectEqual(accMatches.map(\.name), ["archive-old.tar"])
    try E2ERunner.expectEqual(latestMatches.map(\.name), ["archive-old.tar"])

    // Size-only filter without age restriction should return both big files
    let sizeOnlyFilter = DiskEntryFilter(minBytes: 50_000, olderThanDays: nil, ageBasis: .latestOfModificationAndAccess, scope: .filesOnly)
    let bothBig = try await analyzer.findMatchingFiles(under: sandbox.rootURL, filter: sizeOnlyFilter, referenceDate: now)
    try E2ERunner.expectEqual(bothBig.count, 2)
}

runner.register(
    id: "f4-progress-callbacks-fire",
    tier: 1,
    feature: "F-4",
    name: "DiskSpaceAnalyzer.analyze emits onProgress updates with accurate final file/folder/byte statistics"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f4-prog")
    defer { sandbox.cleanup() }

    _ = try sandbox.createExactSizeFile("One/a.bin", byteCount: 8_192)
    _ = try sandbox.createExactSizeFile("Two/b.bin", byteCount: 16_384)
    _ = try sandbox.createExactSizeFile("Two/Sub/c.bin", byteCount: 4_096)

    let collector = ProgressCollector()
    let analyzer = DiskSpaceAnalyzer(
        safetyGuard: SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil),
        progressThrottleInterval: 0.01
    )
    let root = try await analyzer.analyze(root: sandbox.rootURL, maxDepth: 4) { prog in
        collector.record(prog)
    }

    let events = collector.snapshot()
    try E2ERunner.expect(!events.isEmpty, "onProgress must fire at least once")
    let last = try E2ERunner.expectNotNil(events.last)
    try E2ERunner.expectEqual(last.scannedFiles, root.fileCount)
    try E2ERunner.expectEqual(last.scannedFolders, root.folderCount)
    try E2ERunner.expectEqual(last.totalBytes, root.bytes)
    try E2ERunner.expect(last.elapsedSeconds >= 0)
    try E2ERunner.expect(!last.currentPath.isEmpty)
}

runner.register(
    id: "f4-protection-and-uchg-flags",
    tier: 1,
    feature: "F-4",
    name: "DiskSpaceAnalyzer tags isProtected and isUserImmutable accurately and supports dynamic updatingProtection(using:)"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f4-flags")
    defer { sandbox.cleanup() }

    let protDir = try sandbox.createDirectory("Protected")
    _ = try sandbox.createExactSizeFile("Protected/secret.dat", byteCount: 4_096)
    _ = try sandbox.createDirectory("Free")
    let lockedFile = try sandbox.createExactSizeFile("Free/locked.dat", byteCount: 4_096)
    try sandbox.setUserImmutable(lockedFile, locked: true)
    let normalFile = try sandbox.createExactSizeFile("Free/normal.dat", byteCount: 4_096)

    let sg1 = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil, protectedPaths: [protDir.path])
    let analyzer = DiskSpaceAnalyzer(safetyGuard: sg1)
    let root = try await analyzer.analyze(root: sandbox.rootURL, maxDepth: 4)

    let protNode = try E2ERunner.expectNotNil(root.children.first { $0.name == "Protected" })
    try E2ERunner.expect(protNode.isProtected, "Protected dir should have isProtected == true")
    try E2ERunner.expect(protNode.children.first?.isProtected == true, "Protected child should have isProtected == true")

    let freeNode = try E2ERunner.expectNotNil(root.children.first { $0.name == "Free" })
    try E2ERunner.expect(!freeNode.isProtected)
    let lockedNode = try E2ERunner.expectNotNil(freeNode.children.first { $0.name == "locked.dat" })
    try E2ERunner.expect(lockedNode.isUserImmutable, "uchg file must report isUserImmutable == true")
    let normalNode = try E2ERunner.expectNotNil(freeNode.children.first { $0.name == "normal.dat" })
    try E2ERunner.expect(!normalNode.isProtected)
    try E2ERunner.expect(!normalNode.isUserImmutable)

    let sg2 = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil, protectedPaths: [normalFile.path])
    let updatedRoot = root.updatingProtection(using: sg2)
    let updatedFree = try E2ERunner.expectNotNil(updatedRoot.children.first { $0.name == "Free" })
    let updatedNormal = try E2ERunner.expectNotNil(updatedFree.children.first { $0.name == "normal.dat" })
    try E2ERunner.expect(updatedNormal.isProtected, "updatingProtection must mark newly protected path")
}

runner.register(
    id: "f4-symlink-loop-and-hardlink-dedup",
    tier: 2,
    feature: "F-4",
    name: "DiskSpaceAnalyzer skips external and cyclic symlinks and deduplicates hardlinks by (st_dev, st_ino)"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f4-links")
    let external = try E2ESandbox(prefix: "e2e-f4-ext")
    defer {
        sandbox.cleanup()
        external.cleanup()
    }

    _ = try external.createExactSizeFile("huge.bin", byteCount: 131_072)
    let orig = try sandbox.createExactSizeFile("DirA/orig.bin", byteCount: 32_768)
    let origBytes = try allocatedBytesViaLstat(orig)
    _ = try sandbox.createHardlink(atRelativePath: "DirB/hard.bin", to: orig)
    _ = try sandbox.createSymlink(atRelativePath: "ext-link", targetURL: external.rootURL)
    _ = try sandbox.createSymlink(atRelativePath: "DirA/cycle-link", targetURL: sandbox.rootURL)

    let collector = ProgressCollector()
    let analyzer = DiskSpaceAnalyzer(
        safetyGuard: SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil),
        progressThrottleInterval: 0.01
    )
    let root = try await analyzer.analyze(root: sandbox.rootURL, maxDepth: 5) { prog in
        collector.record(prog)
    }

    try E2ERunner.expectEqual(root.bytes, origBytes, "Hardlink + symlinks must not inflate bytes")
    try E2ERunner.expectEqual(root.fileCount, 2)
    let last = try E2ERunner.expectNotNil(collector.snapshot().last)
    try E2ERunner.expect(last.skippedSymlinks >= 2, "Expected >= 2 skipped symlinks, got \(last.skippedSymlinks)")
    try E2ERunner.expectEqual(last.deduplicatedHardlinks, 1)
}

runner.register(
    id: "f4-depth-and-child-truncation-rollup",
    tier: 2,
    feature: "F-4",
    name: "DiskSpaceAnalyzer enforces maxDepth and maxChildrenPerDirectory with exact parent roll-ups and unlistedChildrenBytes"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f4-trunc")
    defer { sandbox.cleanup() }

    let deep1 = try sandbox.createExactSizeFile("Deep/L1/f1.bin", byteCount: 8_192)
    let deep2 = try sandbox.createExactSizeFile("Deep/L1/L2/f2.bin", byteCount: 16_384)
    _ = try sandbox.createDirectory("Empty")

    var manySizes: [UInt64] = []
    for (idx, sz) in [4_096, 12_288, 24_576, 36_864, 8_192].enumerated() {
        let u = try sandbox.createExactSizeFile("Many/item-\(idx).bin", byteCount: Int64(sz))
        manySizes.append(try allocatedBytesViaLstat(u))
    }
    let manyTotal = manySizes.reduce(0, +)
    let manySortedDesc = manySizes.sorted(by: >)
    let deepTotal = (try allocatedBytesViaLstat(deep1)) + (try allocatedBytesViaLstat(deep2))

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)

    // 1. maxDepth: 1 roll-up
    let depthAnalyzer = DiskSpaceAnalyzer(safetyGuard: sg, maxChildrenPerDirectory: 100)
    let depthRoot = try await depthAnalyzer.analyze(root: sandbox.rootURL, maxDepth: 1)
    try E2ERunner.expectEqual(depthRoot.bytes, deepTotal + manyTotal)
    try E2ERunner.expect(!depthRoot.isTruncated)
    try E2ERunner.expect(depthRoot.hasTruncatedDescendant)

    let deepNode = try E2ERunner.expectNotNil(depthRoot.children.first { $0.name == "Deep" })
    try E2ERunner.expectEqual(deepNode.bytes, deepTotal)
    try E2ERunner.expectEqual(deepNode.children.count, 0)
    try E2ERunner.expect(deepNode.isTruncated, "Collapsed non-empty Deep dir should be marked isTruncated")

    let emptyNode = try E2ERunner.expectNotNil(depthRoot.children.first { $0.name == "Empty" })
    try E2ERunner.expect(!emptyNode.isTruncated, "Empty dir at maxDepth must remain isTruncated == false")

    // 2. maxChildrenPerDirectory: 2 roll-up
    let capAnalyzer = DiskSpaceAnalyzer(safetyGuard: sg, maxChildrenPerDirectory: 2)
    let manyRoot = try await capAnalyzer.analyze(root: sandbox.url("Many"), maxDepth: 3)
    try E2ERunner.expectEqual(manyRoot.bytes, manyTotal)
    try E2ERunner.expectEqual(manyRoot.children.count, 2)
    try E2ERunner.expectEqual(manyRoot.children.map(\.bytes), Array(manySortedDesc.prefix(2)))
    try E2ERunner.expect(manyRoot.isTruncated)
    try E2ERunner.expectEqual(manyRoot.truncatedChildCount, 3)
    try E2ERunner.expectEqual(manyRoot.unlistedChildrenBytes, manySortedDesc.dropFirst(2).reduce(0, +))
}

runner.register(
    id: "f4-empty-files-and-filter-scopes",
    tier: 2,
    feature: "F-4",
    name: "DiskSpaceAnalyzer handles 0-byte files/empty dirs cleanly and matches filter scopes (.filesOnly, .filesAndPackages, .allItems)"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f4-scopes")
    defer { sandbox.cleanup() }

    _ = try sandbox.createExactSizeFile("Workspace/zero.dat", byteCount: 0)
    _ = try sandbox.createDirectory("Workspace/EmptySub")
    let reg = try sandbox.createExactSizeFile("Workspace/regular.dat", byteCount: 8_192)
    let protDir = try sandbox.createDirectory("Workspace/Protected")
    _ = try sandbox.createExactSizeFile("Workspace/Protected/secret.dat", byteCount: 16_384)
    let app = try sandbox.createMockAppBundle(
        atRelativePath: "Workspace/Tool.app",
        bundleID: "com.example.tool",
        name: "Tool"
    )
    _ = try sandbox.createExactSizeFile("Workspace/Tool.app/Contents/MacOS/Tool", byteCount: 32_768)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil, protectedPaths: [protDir.path])
    let analyzer = DiskSpaceAnalyzer(safetyGuard: sg)
    let root = try await analyzer.analyze(root: sandbox.url("Workspace"), maxDepth: 5)

    let zeroNode = try E2ERunner.expectNotNil(root.children.first { $0.name == "zero.dat" })
    try E2ERunner.expectEqual(zeroNode.bytes, 0)
    try E2ERunner.expect(!zeroNode.isTruncated)

    let emptySub = try E2ERunner.expectNotNil(root.children.first { $0.name == "EmptySub" })
    try E2ERunner.expectEqual(emptySub.bytes, 0)
    try E2ERunner.expect(!emptySub.isTruncated)

    // filesOnly + excludeProtected: includes regular.dat + zero.dat (not Tool.app package itself, not Protected)
    let filesOnly = DiskEntryFilter(scope: .filesOnly, excludeProtected: true)
    let filesOnlyTree = DiskSpaceAnalyzer.filterNodes(in: root, filter: filesOnly)
    let filesOnlyDisk = try await analyzer.findMatchingFiles(under: sandbox.url("Workspace"), filter: filesOnly)
    try E2ERunner.expectEqual(Set(filesOnlyTree.map(\.id)), Set(filesOnlyDisk.map(\.id)))
    try E2ERunner.expect(filesOnlyTree.contains { $0.name == reg.lastPathComponent })
    try E2ERunner.expect(!filesOnlyTree.contains { $0.name == app.lastPathComponent })
    try E2ERunner.expect(!filesOnlyTree.contains { $0.isProtected })

    // filesAndPackages + excludeProtected: includes Tool.app package
    let filesAndPkgs = DiskEntryFilter(scope: .filesAndPackages, excludeProtected: true)
    let pkgTree = DiskSpaceAnalyzer.filterNodes(in: root, filter: filesAndPkgs)
    let pkgDisk = try await analyzer.findMatchingFiles(under: sandbox.url("Workspace"), filter: filesAndPkgs)
    try E2ERunner.expectEqual(Set(pkgTree.map(\.id)), Set(pkgDisk.map(\.id)))
    try E2ERunner.expect(pkgTree.contains { $0.name == app.lastPathComponent && $0.isPackage })

    // allItems: includes directories too
    let allItems = DiskEntryFilter(scope: .allItems, excludeProtected: false)
    let allTree = DiskSpaceAnalyzer.filterNodes(in: root, filter: allItems)
    try E2ERunner.expect(allTree.contains { $0.name == emptySub.name && $0.isDirectory })
}

runner.register(
    id: "f4-cancellation-and-fifo-safety",
    tier: 2,
    feature: "F-4",
    name: "DiskSpaceAnalyzer honors cooperative Task cancellation and never hangs on mkfifo special files"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f4-cancel")
    defer { sandbox.cleanup() }

    let normal = try sandbox.createExactSizeFile("Data/normal.bin", byteCount: 8_192)
    let expectedBytes = try allocatedBytesViaLstat(normal)
    _ = try sandbox.createFIFO(atRelativePath: "Data/pipe.fifo")

    let analyzer = DiskSpaceAnalyzer(safetyGuard: SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil))

    // 1. FIFO non-blocking scan
    let t0 = Date()
    let node = try await analyzer.analyze(root: sandbox.url("Data"), maxDepth: 3)
    let elapsed = Date().timeIntervalSince(t0)
    try E2ERunner.expect(elapsed < 1.0, "Scanning directory with FIFO took \(elapsed)s (>= 1.0s)")
    try E2ERunner.expectEqual(node.bytes, expectedBytes)
    try E2ERunner.expectEqual(node.fileCount, 1)

    // 2a. Pre-cancelled direct entry into DiskSpaceAnalyzer.analyze (no throwing Task.sleep)
    let preGate = AsyncGate()
    let preState = CancelProbeState()
    let preCancelledTask = Task {
        await preGate.wait()
        preState.markInvoked()
        _ = try await analyzer.analyze(root: sandbox.url("Data"), maxDepth: 4)
    }
    preCancelledTask.cancel()
    preGate.open()
    do {
        _ = try await preCancelledTask.value
        throw E2EAssertionFailure("Pre-cancelled DiskSpaceAnalyzer.analyze should throw CancellationError")
    } catch is CancellationError {
        // Expected
    }
    try E2ERunner.expect(preState.invoked, "DiskSpaceAnalyzer.analyze must be invoked before CancellationError")

    // 2b. Mid-scan cooperative cancellation triggered inside onProgress on a 250-file multi-directory tree
    let totalFiles = 250
    for dirIdx in 0..<25 {
        for fileIdx in 0..<10 {
            _ = try sandbox.createExactSizeFile("BulkTree/Dir_\(dirIdx)/file_\(fileIdx).bin", byteCount: 64)
        }
    }

    let midGate = AsyncGate()
    let midState = CancelProbeState()
    let midAnalyzer = DiskSpaceAnalyzer(
        safetyGuard: SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil),
        progressThrottleInterval: 0
    )
    let midCancelledTask = Task {
        await midGate.wait()
        midState.markInvoked()
        _ = try await midAnalyzer.analyze(root: sandbox.url("BulkTree"), maxDepth: 4) { progress in
            midState.recordProgressAndCancel(progress)
        }
    }
    midState.setTaskToCancel(midCancelledTask)
    midGate.open()
    do {
        _ = try await midCancelledTask.value
        throw E2EAssertionFailure("Mid-scan cancelled DiskSpaceAnalyzer.analyze should throw CancellationError")
    } catch is CancellationError {
        // Expected
    }
    let midEvents = midState.progressEvents
    try E2ERunner.expect(midState.invoked, "Mid-scan DiskSpaceAnalyzer.analyze must be invoked")
    try E2ERunner.expect(!midEvents.isEmpty, "onProgress must fire at least once before mid-scan cancellation")
    if let last = midEvents.last {
        try E2ERunner.expect(last.scannedFiles < totalFiles, "Expected scan to abort mid-tree (< \(totalFiles) files), got \(last.scannedFiles)")
    }
}

runner.register(
    id: "f4-invalid-paths-chmod000-and-mount-boundary",
    tier: 2,
    feature: "F-4",
    name: "DiskSpaceAnalyzer rejects invalid/missing/0000 roots, marks 0000 child inaccessible, and skips /System/Volumes/Data"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f4-errs")
    defer { sandbox.cleanup() }

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let analyzer = DiskSpaceAnalyzer(safetyGuard: sg)

    // 1. Invalid & missing paths
    let badURLs: [URL] = [
        try E2ERunner.expectNotNil(URL(string: "https://example.com/dir")),
        try E2ERunner.expectNotNil(URL(string: "file:///tmp/bad%00dir")),
        URL(fileURLWithPath: sandbox.rootURL.path + "/Sub/../Work"),
    ]
    for bad in badURLs {
        let err = try await E2ERunner.expectThrowsAsync("Invalid URL \(bad) must throw DiskScanError.invalidPath") {
            _ = try await analyzer.analyze(root: bad)
        }
        if case .invalidPath = err as? DiskScanError {} else {
            throw E2EAssertionFailure("Expected .invalidPath for \(bad), got \(err)")
        }
    }

    let missingErr = try await E2ERunner.expectThrowsAsync("Missing path must throw .notFound") {
        _ = try await analyzer.analyze(root: sandbox.url("DoesNotExist"))
    }
    if case .notFound = missingErr as? DiskScanError {} else {
        throw E2EAssertionFailure("Expected .notFound, got \(missingErr)")
    }

    // 2. chmod 000 root vs chmod 000 child (pre-create parent first!)
    if Darwin.geteuid() != 0 {
        _ = try sandbox.createDirectory("Tree")
        let lockedChild = try sandbox.createDirectory("Tree/LockedChild", permissions: 0o000)
        _ = try sandbox.createExactSizeFile("Tree/ok.bin", byteCount: 4_096)

        let parentScan = try await analyzer.analyze(root: sandbox.url("Tree"), maxDepth: 4)
        let childNode = try E2ERunner.expectNotNil(parentScan.children.first { $0.name == "LockedChild" })
        try E2ERunner.expect(!childNode.isAccessible, "0o000 child subdir must report isAccessible == false")
        try E2ERunner.expectEqual(parentScan.fileCount, 1)

        let rootErr = try await E2ERunner.expectThrowsAsync("0o000 root must throw .permissionDenied") {
            _ = try await analyzer.analyze(root: lockedChild)
        }
        if case .permissionDenied = rootErr as? DiskScanError {} else {
            throw E2EAssertionFailure("Expected .permissionDenied for 0o000 root, got \(rootErr)")
        }
    }

    // 3. /System/Volumes skips /System/Volumes/Data mountpoint
    let sysVolumes = URL(fileURLWithPath: "/System/Volumes", isDirectory: true)
    if FileManager.default.fileExists(atPath: sysVolumes.path) {
        let collector = ProgressCollector()
        let boundedAnalyzer = DiskSpaceAnalyzer(
            safetyGuard: SafetyGuard(),
            maxChildrenPerDirectory: 50,
            progressThrottleInterval: 0.01,
            maxTotalEntries: 25
        )
        let volNode = try await boundedAnalyzer.analyze(root: sysVolumes, maxDepth: 1) { prog in
            collector.record(prog)
        }
        try E2ERunner.expect(
            !volNode.children.contains { $0.url.path == "/System/Volumes/Data" },
            "/System/Volumes/Data must be skipped when scanning /System/Volumes"
        )
        let last = collector.snapshot().last
        try E2ERunner.expect((last?.skippedCrossVolume ?? 0) >= 1, "Expected skippedCrossVolume >= 1 for /System/Volumes")
    }
}

// MARK: - F-5: General File Browser & Daily Ops (5 Tier 1 + 5 Tier 2)

runner.register(
    id: "f5-list-and-hidden-toggle",
    tier: 1,
    feature: "F-5",
    name: "FileBrowserService.listDirectory accurately lists entries, toggles dotfiles and UF_HIDDEN, and sets expectedCanonicalParent"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f5-list")
    defer { sandbox.cleanup() }

    let dir = try sandbox.createDirectory("Browse")
    let visible = try sandbox.createFile("Browse/notes.txt", utf8: "visible")
    let dotfile = try sandbox.createFile("Browse/.env", utf8: "SECRET=1")
    let flagHidden = try sandbox.createFile("Browse/uf_hidden.txt", utf8: "uf-hidden")
    var st = stat()
    try E2ERunner.expectEqual(Darwin.lstat(flagHidden.path, &st), 0)
    try E2ERunner.expectEqual(Darwin.lchflags(flagHidden.path, st.st_flags | UInt32(UF_HIDDEN)), 0)
    _ = try sandbox.createDirectory("Browse/Folder")

    let service = FileBrowserService(
        safetyGuard: SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil),
        homeDirectory: sandbox.rootURL
    )
    let expectedParent = sandbox.canonicalPath(for: dir)

    let defaultList = try service.listDirectory(at: dir, showHidden: false)
    try E2ERunner.expectEqual(Set(defaultList.map(\.name)), Set(["notes.txt", "Folder"]))
    let notesEntry = try E2ERunner.expectNotNil(defaultList.first { $0.url == visible.standardizedFileURL })
    try E2ERunner.expectEqual(notesEntry.kind, .regularFile)
    try E2ERunner.expectEqual(notesEntry.expectedCanonicalParent, expectedParent)
    try E2ERunner.expect(!notesEntry.isHidden)

    let allList = try service.listDirectory(at: dir, showHidden: true)
    try E2ERunner.expectEqual(Set(allList.map(\.name)), Set(["notes.txt", "Folder", ".env", "uf_hidden.txt"]))
    let dotEntry = try E2ERunner.expectNotNil(allList.first { $0.url == dotfile.standardizedFileURL })
    try E2ERunner.expect(dotEntry.isHidden)
    let ufEntry = try E2ERunner.expectNotNil(allList.first { $0.url == flagHidden.standardizedFileURL })
    try E2ERunner.expect(ufEntry.isHidden)
}

runner.register(
    id: "f5-sort-and-search-query",
    tier: 1,
    feature: "F-5",
    name: "FileBrowserService.listDirectory sorts ascending/descending by name, size, modificationDate, and kind with searchQuery"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f5-sort")
    defer { sandbox.cleanup() }

    let dir = try sandbox.createDirectory("SortRoom")
    let fSmall = try sandbox.createExactSizeFile("SortRoom/alpha.log", byteCount: 100)
    let fMed = try sandbox.createExactSizeFile("SortRoom/beta.txt", byteCount: 500)
    let fBig = try sandbox.createExactSizeFile("SortRoom/gamma.bin", byteCount: 2000)
    let zetaDir = try sandbox.createDirectory("SortRoom/ZetaFolder")

    let now = Date()
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: fSmall.path)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: fMed.path)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: fBig.path)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: zetaDir.path)

    let service = FileBrowserService(
        safetyGuard: SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil),
        homeDirectory: sandbox.rootURL
    )

    let byNameAsc = try service.listDirectory(at: dir, sortBy: .name, ascending: true)
    try E2ERunner.expectEqual(byNameAsc.map(\.name), ["alpha.log", "beta.txt", "gamma.bin", "ZetaFolder"])
    let byNameDesc = try service.listDirectory(at: dir, sortBy: .name, ascending: false)
    try E2ERunner.expectEqual(byNameDesc.map(\.name), ["ZetaFolder", "gamma.bin", "beta.txt", "alpha.log"])

    let bySizeAsc = try service.listDirectory(at: dir, sortBy: .size, ascending: true)
    try E2ERunner.expectEqual(bySizeAsc.map(\.name), ["ZetaFolder", "alpha.log", "beta.txt", "gamma.bin"])
    let bySizeDesc = try service.listDirectory(at: dir, sortBy: .size, ascending: false)
    try E2ERunner.expectEqual(bySizeDesc.map(\.name), ["gamma.bin", "beta.txt", "alpha.log", "ZetaFolder"])

    let byDateAsc = try service.listDirectory(at: dir, sortBy: .modificationDate, ascending: true)
    try E2ERunner.expectEqual(byDateAsc.map(\.name), ["alpha.log", "beta.txt", "gamma.bin", "ZetaFolder"])
    let byDateDesc = try service.listDirectory(at: dir, sortBy: .modificationDate, ascending: false)
    try E2ERunner.expectEqual(byDateDesc.map(\.name), ["ZetaFolder", "gamma.bin", "beta.txt", "alpha.log"])

    let byKindAsc = try service.listDirectory(at: dir, sortBy: .kind, ascending: true)
    try E2ERunner.expectEqual(Set(byKindAsc.map(\.name)), Set(["alpha.log", "beta.txt", "gamma.bin", "ZetaFolder"]))
    try E2ERunner.expect(Set(byKindAsc.map(\.kindDescription)).count >= 2, "Expected distinct kindDescription values")
    for (lhs, rhs) in zip(byKindAsc, byKindAsc.dropFirst()) {
        let kindCmp = lhs.kindDescription.localizedStandardCompare(rhs.kindDescription)
        if kindCmp == .orderedSame {
            try E2ERunner.expectEqual(
                lhs.name.localizedStandardCompare(rhs.name),
                .orderedAscending,
                "Expected ascending name tie-breaker between '\(lhs.name)' and '\(rhs.name)'"
            )
        } else {
            try E2ERunner.expectEqual(
                kindCmp,
                .orderedAscending,
                "Expected ascending kindDescription order between '\(lhs.kindDescription)' and '\(rhs.kindDescription)'"
            )
        }
    }

    let byKindDesc = try service.listDirectory(at: dir, sortBy: .kind, ascending: false)
    try E2ERunner.expectEqual(Set(byKindDesc.map(\.name)), Set(["alpha.log", "beta.txt", "gamma.bin", "ZetaFolder"]))
    for (lhs, rhs) in zip(byKindDesc, byKindDesc.dropFirst()) {
        let kindCmp = lhs.kindDescription.localizedStandardCompare(rhs.kindDescription)
        if kindCmp == .orderedSame {
            try E2ERunner.expectEqual(
                lhs.name.localizedStandardCompare(rhs.name),
                .orderedAscending,
                "Expected ascending name tie-breaker between '\(lhs.name)' and '\(rhs.name)'"
            )
        } else {
            try E2ERunner.expectEqual(
                kindCmp,
                .orderedDescending,
                "Expected descending kindDescription order between '\(lhs.kindDescription)' and '\(rhs.kindDescription)'"
            )
        }
    }
    try E2ERunner.expect(
        byKindAsc.map(\.kindDescription) != byKindDesc.map(\.kindDescription),
        "Descending kind sort must reverse distinct kind groups"
    )

    let searched = try service.listDirectory(at: dir, searchQuery: "LOG")
    try E2ERunner.expectEqual(searched.map(\.name), ["alpha.log"])
}

runner.register(
    id: "f5-package-favorites-and-metadata",
    tier: 1,
    feature: "F-5",
    name: "FileBrowserService detects .app packages, generates quickFavorites(), and matches inspectMetadata()"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f5-fav")
    defer { sandbox.cleanup() }

    _ = try sandbox.createDirectory("Desktop")
    _ = try sandbox.createDirectory("Documents")
    _ = try sandbox.createDirectory("Downloads")
    _ = try sandbox.createDirectory("Applications")
    _ = try sandbox.createDirectory("Library/Caches")
    let appURL = try sandbox.createMockAppBundle(
        atRelativePath: "Applications/Sample.app",
        bundleID: "com.example.sample",
        name: "Sample"
    )

    let service = FileBrowserService(
        safetyGuard: SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil),
        homeDirectory: sandbox.rootURL
    )

    let appEntries = try service.listDirectory(at: sandbox.url("Applications"))
    let appEntry = try E2ERunner.expectNotNil(appEntries.first { $0.name == "Sample.app" })
    try E2ERunner.expectEqual(appEntry.kind, .package)
    try E2ERunner.expect(appEntry.isPackage)

    let meta = try service.inspectMetadata(at: appURL)
    try E2ERunner.expectEqual(meta.kind, .package)
    try E2ERunner.expect(meta.isPackage)

    let favs = service.quickFavorites()
    let kinds = Set(favs.map(\.kind))
    for expectedKind in [
        FileBrowserFavoriteKind.home,
        .desktop,
        .documents,
        .downloads,
        .applications,
        .caches,
        .volume,
    ] {
        try E2ERunner.expect(kinds.contains(expectedKind), "Missing favorite kind \(expectedKind)")
    }
}

runner.register(
    id: "f5-preview-text-image-hex",
    tier: 1,
    feature: "F-5",
    name: "FileBrowserService.loadPreview & loadPreviewAsync return .text, .image, and .hexDump payloads accurately"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f5-prev")
    defer { sandbox.cleanup() }

    let textURL = try sandbox.createFile("Files/readme.md", utf8: "# Title\nHello MacSweep\n")
    let pngData = minimalValidPNGData()
    let pngURL = try sandbox.createFile("Files/icon.png", data: pngData)
    let binData = Data([0x00, 0xFF, 0x01, 0x02, 0x7F, 0x80, 0xFE, 0xAA])
    let binURL = try sandbox.createFile("Files/blob.bin", data: binData)

    let service = FileBrowserService(
        safetyGuard: SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil),
        homeDirectory: sandbox.rootURL
    )

    let textPayload = try service.loadPreview(at: textURL)
    if case let .text(str, encoding, isTruncated, totalBytes) = textPayload.content {
        try E2ERunner.expectEqual(str, "# Title\nHello MacSweep\n")
        try E2ERunner.expectEqual(encoding, "UTF-8")
        try E2ERunner.expect(!isTruncated)
        try E2ERunner.expectEqual(totalBytes, Int64("# Title\nHello MacSweep\n".utf8.count))
    } else {
        throw E2EAssertionFailure("Expected .text preview, got \(textPayload.content)")
    }

    let imagePayload = try await service.loadPreviewAsync(at: pngURL)
    if case let .image(data, uti, byteCount) = imagePayload.content {
        try E2ERunner.expectEqual(data, pngData)
        try E2ERunner.expectEqual(byteCount, pngData.count)
        try E2ERunner.expectNotNil(uti)
    } else {
        throw E2EAssertionFailure("Expected .image preview, got \(imagePayload.content)")
    }

    let hexPayload = try service.loadPreview(at: binURL)
    if case let .hexDump(dump, byteCount, isTruncated, totalBytes) = hexPayload.content {
        try E2ERunner.expectEqual(byteCount, binData.count)
        try E2ERunner.expect(!isTruncated)
        try E2ERunner.expectEqual(totalBytes, Int64(binData.count))
        try E2ERunner.expectContains(dump.lowercased(), "ff")
    } else {
        throw E2EAssertionFailure("Expected .hexDump preview, got \(hexPayload.content)")
    }
}

runner.register(
    id: "f5-daily-ops-and-cleanup-history",
    tier: 1,
    feature: "F-5",
    name: "FileBrowserService + FileOperationsEngine + RemovalEngine (.trash & .permanent) + CleanupHistoryStore end-to-end"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f5-ops")
    defer { sandbox.cleanup() }

    let work = try sandbox.createDirectory("Work")
    _ = try sandbox.createFile("Work/draft.txt", utf8: "daily-ops-content")
    let mockTrash = try sandbox.createDirectory("MockTrash")
    let historyStore = CleanupHistoryStore(fileURL: sandbox.url("State/history.json"))

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let service = FileBrowserService(safetyGuard: sg, homeDirectory: sandbox.rootURL)

    let createdDir = try await service.fileOperationsEngine.createDirectory(named: "Archive", in: work)
    let entries = try service.listDirectory(at: work)
    let draftEntry = try E2ERunner.expectNotNil(entries.first { $0.name == "draft.txt" })

    let renamed = try await service.fileOperationsEngine.renameItem(
        at: draftEntry.url,
        toNewName: "final.txt",
        expectedSourceCanonicalParent: draftEntry.expectedCanonicalParent
    )
    let moved = try await service.fileOperationsEngine.moveItem(
        from: renamed,
        to: createdDir,
        expectedSourceCanonicalParent: draftEntry.expectedCanonicalParent
    )
    let movedEntries = try service.listDirectory(at: createdDir)
    let movedEntry = try E2ERunner.expectNotNil(movedEntries.first { $0.url == moved.standardizedFileURL })

    let removal = RemovalEngine(
        safetyGuard: sg,
        historyStore: historyStore,
        localTrashHandler: { itemURL in
            try FileManager.default.moveItem(at: itemURL, to: mockTrash.appendingPathComponent(itemURL.lastPathComponent))
        }
    )

    let trashReport = removal.remove(
        targets: [RemovalTarget(
            url: movedEntry.url,
            estimatedSize: movedEntry.sizeBytes,
            expectedCanonicalParent: movedEntry.expectedCanonicalParent
        )],
        mode: .trash,
        actionTitle: "Browser Trash",
        allowElevation: false
    )
    try E2ERunner.expect(trashReport.isFullSuccess, "Trash removal failed: \(trashReport.failures)")
    try E2ERunner.expect(!RemovalEngine.entryExists(moved))
    try E2ERunner.expect(RemovalEngine.entryExists(mockTrash.appendingPathComponent("final.txt")))

    let permFile = try sandbox.createFile("Work/perm.txt", utf8: "permanent-delete")
    let permEntries = try service.listDirectory(at: work)
    let permEntry = try E2ERunner.expectNotNil(permEntries.first { $0.url == permFile.standardizedFileURL })
    let permReport = removal.remove(
        targets: [RemovalTarget(
            url: permEntry.url,
            estimatedSize: permEntry.sizeBytes,
            expectedCanonicalParent: permEntry.expectedCanonicalParent
        )],
        mode: .permanent,
        actionTitle: "Browser Permanent",
        allowElevation: false
    )
    try E2ERunner.expect(permReport.isFullSuccess)
    try E2ERunner.expect(!RemovalEngine.entryExists(permFile))

    let records = historyStore.load()
    try E2ERunner.expectEqual(records.count, 2)
    try E2ERunner.expectEqual(records.first?.actionTitle, "Browser Permanent")
    try E2ERunner.expectEqual(records.last?.actionTitle, "Browser Trash")
}

runner.register(
    id: "f5-symlink-listing-and-preview-blocks",
    tier: 2,
    feature: "F-5",
    name: "FileBrowserService flags valid/broken symlinks without escaping listing and returns .unavailable(.symbolicLink) on preview"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f5-sym")
    defer { sandbox.cleanup() }

    let dir = try sandbox.createDirectory("Dir")
    let targetDir = try sandbox.createDirectory("External")
    let targetFile = try sandbox.createFile("External/secret.txt", utf8: "external-secret")
    let validLink = try sandbox.createSymlink(atRelativePath: "Dir/good.link", targetURL: targetDir)
    let brokenLink = try sandbox.createSymlink(atRelativePath: "Dir/bad.link", targetPath: sandbox.url("Missing/none.txt").path)
    let fileLink = try sandbox.createSymlink(atRelativePath: "Dir/file.link", targetURL: targetFile)

    let service = FileBrowserService(
        safetyGuard: SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil),
        homeDirectory: sandbox.rootURL
    )
    let entries = try service.listDirectory(at: dir)
    try E2ERunner.expectEqual(entries.count, 3)

    let goodEntry = try E2ERunner.expectNotNil(entries.first { $0.name == "good.link" })
    try E2ERunner.expectEqual(goodEntry.kind, .symbolicLink)
    try E2ERunner.expect(goodEntry.isSymbolicLink)
    try E2ERunner.expect(!goodEntry.isSymlinkBroken)

    let badEntry = try E2ERunner.expectNotNil(entries.first { $0.name == "bad.link" })
    try E2ERunner.expect(badEntry.isSymbolicLink)
    try E2ERunner.expect(badEntry.isSymlinkBroken)

    for link in [validLink, brokenLink, fileLink] {
        let preview = try service.loadPreview(at: link)
        try E2ERunner.expectEqual(preview.content, .unavailable(reason: .symbolicLink))
    }
}

runner.register(
    id: "f5-empty-dir-empty-file-and-dir-preview",
    tier: 2,
    feature: "F-5",
    name: "FileBrowserService returns [] for empty directory and .unavailable(.emptyFile / .directory) for 0-byte/folder/package previews"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f5-empty")
    defer { sandbox.cleanup() }

    let emptyDir = try sandbox.createDirectory("Empty")
    let emptyFile = try sandbox.createExactSizeFile("Zero.txt", byteCount: 0)
    let appBundle = try sandbox.createMockAppBundle(
        atRelativePath: "App.app",
        bundleID: "com.example.empty",
        name: "App"
    )

    let service = FileBrowserService(
        safetyGuard: SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil),
        homeDirectory: sandbox.rootURL
    )

    let list = try service.listDirectory(at: emptyDir)
    try E2ERunner.expect(list.isEmpty, "Empty directory must return []")

    try E2ERunner.expectEqual(try service.loadPreview(at: emptyFile).content, .unavailable(reason: .emptyFile))
    try E2ERunner.expectEqual(try service.loadPreview(at: emptyDir).content, .unavailable(reason: .directory))
    try E2ERunner.expectEqual(try service.loadPreview(at: appBundle).content, .unavailable(reason: .directory))
}

runner.register(
    id: "f5-directory-error-boundaries",
    tier: 2,
    feature: "F-5",
    name: "FileBrowserService.listDirectory throws .notFound, .notADirectory, .invalidPath, and .tccOrPermissionDenied cleanly"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f5-direrr")
    defer { sandbox.cleanup() }

    let regFile = try sandbox.createFile("plain.txt", utf8: "not-a-dir")
    _ = try sandbox.createDirectory("Sub")

    let service = FileBrowserService(
        safetyGuard: SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil),
        homeDirectory: sandbox.rootURL
    )

    let missingErr = try E2ERunner.expectThrows("Missing directory must throw") {
        _ = try service.listDirectory(at: sandbox.url("NoSuchDir"))
    }
    if case .notFound = missingErr as? FileBrowserError {} else {
        throw E2EAssertionFailure("Expected .notFound, got \(missingErr)")
    }

    let notDirErr = try E2ERunner.expectThrows("Regular file must throw .notADirectory") {
        _ = try service.listDirectory(at: regFile)
    }
    if case .notADirectory = notDirErr as? FileBrowserError {} else {
        throw E2EAssertionFailure("Expected .notADirectory, got \(notDirErr)")
    }

    let invalidURLs: [URL] = [
        try E2ERunner.expectNotNil(URL(string: "https://example.com/a")),
        try E2ERunner.expectNotNil(URL(string: "file:///tmp/bad%00dir")),
        URL(fileURLWithPath: sandbox.rootURL.path + "/Sub/../Sub"),
    ]
    for u in invalidURLs {
        let err = try E2ERunner.expectThrows("Invalid URL \(u) must throw .invalidPath") {
            _ = try service.listDirectory(at: u)
        }
        if case .invalidPath = err as? FileBrowserError {} else {
            throw E2EAssertionFailure("Expected .invalidPath for \(u), got \(err)")
        }
    }

    if Darwin.geteuid() != 0 {
        _ = try sandbox.createDirectory("Parent")
        let lockedDir = try sandbox.createDirectory("Parent/Locked000", permissions: 0o000)
        let permErr = try E2ERunner.expectThrows("0o000 directory must throw .tccOrPermissionDenied") {
            _ = try service.listDirectory(at: lockedDir)
        }
        if case .tccOrPermissionDenied = permErr as? FileBrowserError {} else {
            throw E2EAssertionFailure("Expected .tccOrPermissionDenied, got \(permErr)")
        }
    }
}

runner.register(
    id: "f5-locked-entries-fifo-and-oversized-image",
    tier: 2,
    feature: "F-5",
    name: "FileBrowserService marks locked entries, blocks uchg/protected mutation, handles 0000/FIFO non-blocking, and rejects oversized image"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f5-locked")
    defer { sandbox.cleanup() }

    let dir = try sandbox.createDirectory("Room")
    let protSub = try sandbox.createDirectory("Room/ProtectedSub")
    let locked = try sandbox.createFile("Room/immutable.txt", utf8: "locked")
    try sandbox.setUserImmutable(locked, locked: true)
    let unreadable = try sandbox.createFile("Room/secret000.txt", utf8: "cant-read", permissions: 0o000)
    let fifo = try sandbox.createFIFO(atRelativePath: "Room/named.fifo")
    let bigPNG = try sandbox.createFile("Room/large.png", data: minimalValidPNGData())

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil, protectedPaths: [protSub.path])
    let service = FileBrowserService(safetyGuard: sg, homeDirectory: sandbox.rootURL)

    let entries = try service.listDirectory(at: dir)
    let protEntry = try E2ERunner.expectNotNil(entries.first { $0.name == "ProtectedSub" })
    try E2ERunner.expect(protEntry.isProtected)
    try E2ERunner.expect(protEntry.isMutationLocked)
    try E2ERunner.expectNotNil(protEntry.protectionReason)

    let uchgEntry = try E2ERunner.expectNotNil(entries.first { $0.name == "immutable.txt" })
    try E2ERunner.expect(uchgEntry.isUserImmutable)
    try E2ERunner.expect(uchgEntry.isMutationLocked)

    try await E2ERunner.expectThrowsAsync("Protected entry must be blocked from rename") {
        _ = try await service.fileOperationsEngine.renameItem(
            at: protEntry.url,
            toNewName: "NewName",
            expectedSourceCanonicalParent: protEntry.expectedCanonicalParent
        )
    }
    try await E2ERunner.expectThrowsAsync("uchg entry must be blocked from rename") {
        _ = try await service.fileOperationsEngine.renameItem(
            at: uchgEntry.url,
            toNewName: "Unlocked.txt",
            expectedSourceCanonicalParent: uchgEntry.expectedCanonicalParent
        )
    }

    if Darwin.geteuid() != 0 {
        let unreadPreview = try service.loadPreview(at: unreadable)
        try E2ERunner.expectEqual(unreadPreview.content, .unavailable(reason: .permissionDenied))
    }

    let t0 = Date()
    let fifoPreview = try service.loadPreview(at: fifo)
    let elapsed = Date().timeIntervalSince(t0)
    try E2ERunner.expect(elapsed < 1.0, "loadPreview on FIFO must not block (took \(elapsed)s)")
    try E2ERunner.expectEqual(fifoPreview.content, .unavailable(reason: .specialFile))

    let imgPreview = try service.loadPreview(at: bigPNG, maxImageBytes: 32)
    try E2ERunner.expectEqual(imgPreview.content, .unavailable(reason: .imageTooLarge(actualBytes: 69, maxBytes: 32)))
}

runner.register(
    id: "f5-utf8-truncation-bidi-and-invalid-rename",
    tier: 2,
    feature: "F-5",
    name: "FileBrowserService trims truncated UTF-8 scalars, sanitizes bidi displayNames, and rejects invalid rename names"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f5-bidi")
    defer { sandbox.cleanup() }

    let dir = try sandbox.createDirectory("EdgeText")
    let utf8File = try sandbox.createFile("EdgeText/multi.txt", utf8: "AAAA中文测试") // 4 + 4*3 = 16 bytes
    let bidiName = "invoice\u{202E}gpj.exe"
    let bidiFile = try sandbox.createFile("EdgeText/\(bidiName)", utf8: "test")
    let ctrlName = "ctrl\tname\nline\rret.txt"
    let ctrlFile = try sandbox.createFile("EdgeText/\(ctrlName)", utf8: "ctrl")

    let service = FileBrowserService(
        safetyGuard: SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil),
        homeDirectory: sandbox.rootURL
    )

    // maxTextBytes = 6 slices "AAAA" + first 2 bytes of 3-byte "中"; trailing incomplete scalar must be trimmed cleanly
    let preview = try service.loadPreview(at: utf8File, maxTextBytes: 6)
    if case let .text(text, _, isTruncated, totalBytes) = preview.content {
        try E2ERunner.expectEqual(text, "AAAA")
        try E2ERunner.expect(isTruncated)
        try E2ERunner.expectEqual(totalBytes, 16)
    } else {
        throw E2EAssertionFailure("Expected truncated .text preview, got \(preview.content)")
    }

    let entries = try service.listDirectory(at: dir)
    let bidiEntry = try E2ERunner.expectNotNil(entries.first { $0.url == bidiFile.standardizedFileURL })
    try E2ERunner.expectEqual(bidiEntry.displayName, "invoice\\u{202E}gpj.exe")
    let ctrlEntry = try E2ERunner.expectNotNil(entries.first { $0.url == ctrlFile.standardizedFileURL })
    try E2ERunner.expectEqual(ctrlEntry.displayName, "ctrl\\tname\\nline\\rret.txt")

    for badName in ["", ".", "..", "sub/file", "bad\0name"] {
        try await E2ERunner.expectThrowsAsync("renameItem must reject '\(badName.debugDescription)'") {
            _ = try await service.fileOperationsEngine.renameItem(
                at: bidiEntry.url,
                toNewName: badName,
                expectedSourceCanonicalParent: bidiEntry.expectedCanonicalParent
            )
        }
    }
}

await runner.runAndExit()

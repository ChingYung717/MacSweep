import Foundation

// MARK: - Feature F6: Junk & Cache Cleaner Models

public enum JunkCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case userCaches
    case logs
    case browserCaches
    case developerCaches
    case trash

    public static var appCaches: JunkCategory { .userCaches }
    public static var logsAndCrashReports: JunkCategory { .logs }
}

public struct JunkEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let category: JunkCategory
    public let subgroup: String?
    public let bytes: UInt64
    public let isDirectory: Bool
    public var isSelected: Bool
    public let requiresAdmin: Bool
    public var isProtected: Bool
    public let isUserImmutable: Bool
    public let expectedCanonicalParent: String
    public let isRunningAppBlocked: Bool
    public let runningAppName: String?
    public let browserBundleID: String?
    public let safetyReason: String?
    public let isRecommendedSafe: Bool

    public var displayName: String {
        SafeFileReader.sanitizeForDisplay(name)
    }

    public init(
        url: URL,
        name: String? = nil,
        category: JunkCategory,
        subgroup: String? = nil,
        bytes: UInt64,
        isDirectory: Bool,
        isSelected: Bool,
        requiresAdmin: Bool = false,
        isProtected: Bool = false,
        isUserImmutable: Bool = false,
        expectedCanonicalParent: String? = nil,
        isRunningAppBlocked: Bool = false,
        runningAppName: String? = nil,
        browserBundleID: String? = nil,
        safetyReason: String? = nil,
        isRecommendedSafe: Bool? = nil
    ) {
        let std = url.standardizedFileURL
        self.id = std.path
        self.url = std
        self.name = name ?? std.lastPathComponent
        self.category = category
        self.subgroup = subgroup
        self.bytes = bytes
        self.isDirectory = isDirectory
        self.isProtected = isProtected
        self.isUserImmutable = isUserImmutable
        self.expectedCanonicalParent = expectedCanonicalParent
            ?? PrivilegedExecutor.canonicalParentPath(forTargetURL: std)
        self.isRunningAppBlocked = isRunningAppBlocked
        self.runningAppName = runningAppName
        self.browserBundleID = browserBundleID
        self.safetyReason = safetyReason
        self.requiresAdmin = requiresAdmin
        self.isSelected = (isProtected || isRunningAppBlocked) ? false : isSelected
        self.isRecommendedSafe = isRecommendedSafe ?? (!isProtected && !isRunningAppBlocked && !requiresAdmin && safetyReason == nil)
    }
}

public struct JunkCategoryItem: Identifiable, Hashable, Sendable {
    public var id: String { category.rawValue }
    public let category: JunkCategory
    public let title: String
    public let description: String
    public var entries: [JunkEntry]
    public var totalBytes: UInt64
    public let safetyNote: String
    public let needsFullDiskAccess: Bool
    public let blockedDescriptions: [String]

    public var selectedBytes: UInt64 {
        entries
            .filter { $0.isSelected && !$0.isProtected && !$0.isRunningAppBlocked }
            .reduce(into: UInt64(0)) { $0 &+= $1.bytes }
    }

    public var selectedCount: Int {
        entries.count { $0.isSelected && !$0.isProtected && !$0.isRunningAppBlocked }
    }

    public var requiresAdmin: Bool {
        entries.contains(where: \.requiresAdmin)
    }

    public mutating func recalculateTotalBytes() {
        totalBytes = entries
            .filter { !$0.isProtected }
            .reduce(into: UInt64(0)) { $0 &+= $1.bytes }
    }

    public init(
        category: JunkCategory,
        title: String,
        description: String,
        entries: [JunkEntry],
        totalBytes: UInt64? = nil,
        safetyNote: String,
        needsFullDiskAccess: Bool = false,
        blockedDescriptions: [String] = []
    ) {
        self.category = category
        self.title = title
        self.description = description
        self.entries = entries
        self.totalBytes = totalBytes ?? entries.filter { !$0.isProtected }.reduce(into: UInt64(0)) { $0 &+= $1.bytes }
        self.safetyNote = safetyNote
        self.needsFullDiskAccess = needsFullDiskAccess
        self.blockedDescriptions = blockedDescriptions
    }
}

public struct JunkScanProgress: Sendable, Equatable {
    public let currentCategory: JunkCategory
    public let currentPath: String
    public let scannedEntries: Int
    public let totalBytesFound: UInt64

    public init(
        currentCategory: JunkCategory,
        currentPath: String,
        scannedEntries: Int,
        totalBytesFound: UInt64
    ) {
        self.currentCategory = currentCategory
        self.currentPath = currentPath
        self.scannedEntries = scannedEntries
        self.totalBytesFound = totalBytesFound
    }
}

public struct JunkScanResult: Sendable, Equatable {
    public let categories: [JunkCategoryItem]
    public let totalBytes: UInt64
    public let needsFullDiskAccess: Bool
    public let blockedLocations: [String]
    public let elapsedSeconds: TimeInterval

    public init(
        categories: [JunkCategoryItem],
        totalBytes: UInt64,
        needsFullDiskAccess: Bool,
        blockedLocations: [String],
        elapsedSeconds: TimeInterval
    ) {
        self.categories = categories
        self.totalBytes = totalBytes
        self.needsFullDiskAccess = needsFullDiskAccess
        self.blockedLocations = blockedLocations
        self.elapsedSeconds = elapsedSeconds
    }
}

// MARK: - Feature F7: Large Files Finder Models

public enum LargeFileCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case video
    case diskImageAndArchive
    case installer
    case audio
    case document
    case other
}

public enum LargeFileSizeThreshold: UInt64, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case mb50 = 50_000_000
    case mb100 = 100_000_000
    case mb500 = 500_000_000
    case gb1 = 1_000_000_000

    public var id: UInt64 { rawValue }
}

public struct LargeFileScanOptions: Sendable, Equatable, Hashable {
    public var minBytes: UInt64
    public var olderThanDays: Int?
    public var ageBasis: DiskAgeDateBasis
    public var categories: Set<LargeFileCategory>
    public var includePackages: Bool
    public var maxResults: Int

    public init(
        minBytes: UInt64 = LargeFileSizeThreshold.mb50.rawValue,
        olderThanDays: Int? = nil,
        ageBasis: DiskAgeDateBasis = .modificationDate,
        categories: Set<LargeFileCategory> = [],
        includePackages: Bool = false,
        maxResults: Int = 500
    ) {
        self.minBytes = minBytes
        self.olderThanDays = olderThanDays
        self.ageBasis = ageBasis
        self.categories = categories
        self.includePackages = includePackages
        self.maxResults = max(1, maxResults)
    }
}

public struct LargeFileItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let bytes: UInt64
    public let modificationDate: Date?
    public let accessDate: Date?
    public let category: LargeFileCategory
    public let expectedCanonicalParent: String
    public let isPackage: Bool
    public let isUserImmutable: Bool
    public let requiresAdmin: Bool
    public var isProtected: Bool
    public var isSelected: Bool
    public let relativePathFromRoot: String

    public var displayName: String {
        SafeFileReader.sanitizeForDisplay(name)
    }

    public init(
        url: URL,
        name: String? = nil,
        bytes: UInt64,
        modificationDate: Date?,
        accessDate: Date?,
        category: LargeFileCategory,
        expectedCanonicalParent: String? = nil,
        isPackage: Bool = false,
        isUserImmutable: Bool = false,
        requiresAdmin: Bool = false,
        isProtected: Bool = false,
        isSelected: Bool = false,
        relativePathFromRoot: String = ""
    ) {
        let std = url.standardizedFileURL
        self.id = std.path
        self.url = std
        self.name = name ?? std.lastPathComponent
        self.bytes = bytes
        self.modificationDate = modificationDate
        self.accessDate = accessDate
        self.category = category
        self.expectedCanonicalParent = expectedCanonicalParent
            ?? PrivilegedExecutor.canonicalParentPath(forTargetURL: std)
        self.isPackage = isPackage
        self.isUserImmutable = isUserImmutable
        self.requiresAdmin = requiresAdmin
        self.isProtected = isProtected
        self.isSelected = isProtected ? false : isSelected
        self.relativePathFromRoot = relativePathFromRoot
    }
}

// MARK: - Feature F8: Duplicate File Finder Models

public struct DuplicateScanOptions: Sendable, Equatable, Hashable {
    public var minBytes: UInt64
    public var includeZeroByteFiles: Bool
    public var includeHiddenFiles: Bool
    public var partialHashChunkBytes: Int
    public var streamBufferSize: Int
    public var maxGroups: Int

    public init(
        minBytes: UInt64 = 1_048_576,
        includeZeroByteFiles: Bool = false,
        includeHiddenFiles: Bool = false,
        partialHashChunkBytes: Int = 16_384,
        streamBufferSize: Int = 131_072,
        maxGroups: Int = 500
    ) {
        self.minBytes = minBytes
        self.includeZeroByteFiles = includeZeroByteFiles
        self.includeHiddenFiles = includeHiddenFiles
        self.partialHashChunkBytes = max(1024, partialHashChunkBytes)
        self.streamBufferSize = max(4096, streamBufferSize)
        self.maxGroups = max(1, maxGroups)
    }
}

public enum DuplicateSelectionPreset: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case keepOldest
    case keepNewest
    case keepShortestPath
    case preferNonDownloads
    case clearAll

    public var id: String { rawValue }
}

public struct DuplicateFileEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let modificationDate: Date?
    public let expectedCanonicalParent: String
    public let isUserImmutable: Bool
    public let requiresAdmin: Bool
    public var isProtected: Bool
    public var isSelected: Bool
    public let relativePathFromRoot: String

    public var displayName: String {
        SafeFileReader.sanitizeForDisplay(name)
    }

    public init(
        url: URL,
        name: String? = nil,
        modificationDate: Date?,
        expectedCanonicalParent: String? = nil,
        isUserImmutable: Bool = false,
        requiresAdmin: Bool = false,
        isProtected: Bool = false,
        isSelected: Bool = false,
        relativePathFromRoot: String = ""
    ) {
        let std = url.standardizedFileURL
        self.id = std.path
        self.url = std
        self.name = name ?? std.lastPathComponent
        self.modificationDate = modificationDate
        self.expectedCanonicalParent = expectedCanonicalParent
            ?? PrivilegedExecutor.canonicalParentPath(forTargetURL: std)
        self.isUserImmutable = isUserImmutable
        self.requiresAdmin = requiresAdmin
        self.isProtected = isProtected
        self.isSelected = isProtected ? false : isSelected
        self.relativePathFromRoot = relativePathFromRoot
    }
}

public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let sha256Hex: String
    public let fileSize: UInt64
    public var files: [DuplicateFileEntry]
    public var reclaimableBytes: UInt64

    public var sha256: String { sha256Hex }

    public var selectedCount: Int {
        files.count { $0.isSelected && !$0.isProtected }
    }

    public var selectedReclaimableBytes: UInt64 {
        UInt64(selectedCount) &* fileSize
    }

    public var allCopiesSelected: Bool {
        files.count >= 2 && files.allSatisfy(\.isSelected)
    }

    public init(
        sha256Hex: String,
        fileSize: UInt64,
        files: [DuplicateFileEntry]
    ) {
        self.id = "\(sha256Hex)-\(fileSize)"
        self.sha256Hex = sha256Hex
        self.fileSize = fileSize
        self.files = files
        self.reclaimableBytes = fileSize &* UInt64(max(0, files.count - 1))
    }

    public mutating func recalculateReclaimableBytes() {
        reclaimableBytes = fileSize &* UInt64(max(0, files.count - 1))
    }

    public func applyingPreset(_ preset: DuplicateSelectionPreset) -> DuplicateGroup {
        var updated = self
        guard !updated.files.isEmpty else { return updated }

        if preset == .clearAll {
            for idx in updated.files.indices {
                updated.files[idx].isSelected = false
            }
            return updated
        }

        let keeperIndex = updated.preferredKeeperIndex(for: preset)
        for idx in updated.files.indices {
            if idx == keeperIndex || updated.files[idx].isProtected {
                updated.files[idx].isSelected = false
            } else {
                updated.files[idx].isSelected = true
            }
        }
        return updated
    }

    public func settingSelection(
        _ selected: Bool,
        forEntryID id: String,
        enforceKeepOne: Bool = true
    ) -> DuplicateGroup {
        var updated = self
        guard let targetIdx = updated.files.firstIndex(where: { $0.id == id }) else {
            return updated
        }
        if updated.files[targetIdx].isProtected {
            updated.files[targetIdx].isSelected = false
            return updated
        }
        if selected && enforceKeepOne {
            let otherUnchecked = updated.files.indices.contains { idx in
                idx != targetIdx && !updated.files[idx].isSelected
            }
            guard otherUnchecked else { return updated }
        }
        updated.files[targetIdx].isSelected = selected
        return updated
    }

    private func preferredKeeperIndex(for preset: DuplicateSelectionPreset) -> Int {
        if let protectedIdx = files.firstIndex(where: \.isProtected) {
            return protectedIdx
        }

        let isInDownloads: (DuplicateFileEntry) -> Bool = { entry in
            entry.url.pathComponents.contains { $0.lowercased() == "downloads" }
        }

        switch preset {
        case .keepOldest:
            return files.indices.min { lhs, rhs in
                let lDate = files[lhs].modificationDate ?? .distantFuture
                let rDate = files[rhs].modificationDate ?? .distantFuture
                if lDate != rDate { return lDate < rDate }
                let lInDL = isInDownloads(files[lhs])
                let rInDL = isInDownloads(files[rhs])
                if lInDL != rInDL { return !lInDL && rInDL }
                if files[lhs].url.path.count != files[rhs].url.path.count {
                    return files[lhs].url.path.count < files[rhs].url.path.count
                }
                return files[lhs].url.path < files[rhs].url.path
            } ?? 0

        case .keepNewest:
            return files.indices.min { lhs, rhs in
                let lDate = files[lhs].modificationDate ?? .distantPast
                let rDate = files[rhs].modificationDate ?? .distantPast
                if lDate != rDate { return lDate > rDate }
                let lInDL = isInDownloads(files[lhs])
                let rInDL = isInDownloads(files[rhs])
                if lInDL != rInDL { return !lInDL && rInDL }
                if files[lhs].url.path.count != files[rhs].url.path.count {
                    return files[lhs].url.path.count < files[rhs].url.path.count
                }
                return files[lhs].url.path < files[rhs].url.path
            } ?? 0

        case .keepShortestPath:
            return files.indices.min { lhs, rhs in
                let lDepth = files[lhs].url.pathComponents.count
                let rDepth = files[rhs].url.pathComponents.count
                if lDepth != rDepth { return lDepth < rDepth }
                if files[lhs].url.path.count != files[rhs].url.path.count {
                    return files[lhs].url.path.count < files[rhs].url.path.count
                }
                return files[lhs].url.path < files[rhs].url.path
            } ?? 0

        case .preferNonDownloads:
            return files.indices.min { lhs, rhs in
                let lInDL = isInDownloads(files[lhs])
                let rInDL = isInDownloads(files[rhs])
                if lInDL != rInDL { return !lInDL && rInDL }
                let lDate = files[lhs].modificationDate ?? .distantFuture
                let rDate = files[rhs].modificationDate ?? .distantFuture
                if lDate != rDate { return lDate < rDate }
                if files[lhs].url.path.count != files[rhs].url.path.count {
                    return files[lhs].url.path.count < files[rhs].url.path.count
                }
                return files[lhs].url.path < files[rhs].url.path
            } ?? 0

        case .clearAll:
            return 0
        }
    }
}

public enum ResourceScanStage: String, Sendable, Equatable, Hashable {
    case largeFiles
    case duplicatesSizeGrouping
    case duplicatesPartialHash
    case duplicatesFullHash
}

public struct ResourceScanProgress: Sendable, Equatable {
    public let stage: ResourceScanStage
    public let currentPath: String
    public let scannedFiles: Int
    public let candidateFiles: Int
    public let hashedFiles: Int
    public let totalCandidateFiles: Int
    public let elapsedSeconds: TimeInterval
    public let skippedSymlinks: Int
    public let skippedDataless: Int
    public let skippedCrossVolume: Int
    public let deduplicatedHardlinks: Int

    public init(
        stage: ResourceScanStage,
        currentPath: String,
        scannedFiles: Int,
        candidateFiles: Int,
        hashedFiles: Int,
        totalCandidateFiles: Int,
        elapsedSeconds: TimeInterval,
        skippedSymlinks: Int = 0,
        skippedDataless: Int = 0,
        skippedCrossVolume: Int = 0,
        deduplicatedHardlinks: Int = 0
    ) {
        self.stage = stage
        self.currentPath = currentPath
        self.scannedFiles = scannedFiles
        self.candidateFiles = candidateFiles
        self.hashedFiles = hashedFiles
        self.totalCandidateFiles = totalCandidateFiles
        self.elapsedSeconds = elapsedSeconds
        self.skippedSymlinks = skippedSymlinks
        self.skippedDataless = skippedDataless
        self.skippedCrossVolume = skippedCrossVolume
        self.deduplicatedHardlinks = deduplicatedHardlinks
    }
}

// MARK: - Feature F9: Memory / RAM Monitor & Release Models

public enum MemoryPressureLevel: String, CaseIterable, Codable, Sendable, Hashable {
    case normal
    case warning
    case critical
}

public struct MemorySnapshot: Sendable, Equatable, Hashable {
    public let capturedAt: Date
    public let totalBytes: UInt64
    public let activeBytes: UInt64
    public let inactiveBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    public let cachedFilesBytes: UInt64
    public let appMemoryBytes: UInt64
    public let freeBytes: UInt64
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64
    public let pageSizeBytes: UInt64
    public let pressureLevel: MemoryPressureLevel

    public var usedBytes: UInt64 {
        min(totalBytes, appMemoryBytes &+ wiredBytes &+ compressedBytes)
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedBytes) / Double(totalBytes)))
    }

    public init(
        capturedAt: Date = Date(),
        totalBytes: UInt64,
        activeBytes: UInt64,
        inactiveBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        cachedFilesBytes: UInt64,
        appMemoryBytes: UInt64,
        freeBytes: UInt64,
        swapUsedBytes: UInt64,
        swapTotalBytes: UInt64,
        pageSizeBytes: UInt64,
        pressureLevel: MemoryPressureLevel
    ) {
        self.capturedAt = capturedAt
        self.totalBytes = totalBytes
        self.activeBytes = activeBytes
        self.inactiveBytes = inactiveBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedFilesBytes = cachedFilesBytes
        self.appMemoryBytes = appMemoryBytes
        self.freeBytes = freeBytes
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.pageSizeBytes = pageSizeBytes
        self.pressureLevel = pressureLevel
    }
}

public struct MemoryReleaseResult: Sendable, Equatable, Hashable {
    public let before: MemorySnapshot
    public let after: MemorySnapshot
    public let reclaimedEstimateBytes: UInt64
    public let methodUsed: String
    public let usedElevation: Bool
    public let note: String

    public init(
        before: MemorySnapshot,
        after: MemorySnapshot,
        reclaimedEstimateBytes: UInt64,
        methodUsed: String,
        usedElevation: Bool,
        note: String
    ) {
        self.before = before
        self.after = after
        self.reclaimedEstimateBytes = reclaimedEstimateBytes
        self.methodUsed = methodUsed
        self.usedElevation = usedElevation
        self.note = note
    }
}

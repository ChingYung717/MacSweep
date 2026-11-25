import Foundation

public struct DiskTreeNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymlink: Bool
    public let bytes: UInt64
    public let fileCount: Int
    public let folderCount: Int
    public let modificationDate: Date?
    public let accessDate: Date?
    public let children: [DiskTreeNode]
    public let isTruncated: Bool
    public let truncatedChildCount: Int
    public let isAccessible: Bool
    public let isProtected: Bool
    public let isUserImmutable: Bool
    public let isHidden: Bool
    public let expectedCanonicalParent: String

    public init(
        url: URL,
        name: String? = nil,
        isDirectory: Bool,
        isPackage: Bool = false,
        isSymlink: Bool = false,
        bytes: UInt64,
        fileCount: Int,
        folderCount: Int,
        modificationDate: Date? = nil,
        accessDate: Date? = nil,
        children: [DiskTreeNode] = [],
        isTruncated: Bool = false,
        truncatedChildCount: Int = 0,
        isAccessible: Bool = true,
        isProtected: Bool = false,
        isUserImmutable: Bool = false,
        isHidden: Bool = false,
        expectedCanonicalParent: String? = nil
    ) {
        let stdURL = url.standardizedFileURL
        self.id = stdURL.path
        self.url = stdURL
        self.name = name ?? (stdURL.path == "/" ? "/" : stdURL.lastPathComponent)
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymlink = isSymlink
        self.bytes = bytes
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.modificationDate = modificationDate
        self.accessDate = accessDate
        self.children = children
        self.isTruncated = isTruncated
        self.truncatedChildCount = max(0, truncatedChildCount)
        self.isAccessible = isAccessible
        self.isProtected = isProtected
        self.isUserImmutable = isUserImmutable
        self.isHidden = isHidden
        self.expectedCanonicalParent = expectedCanonicalParent
            ?? PrivilegedExecutor.canonicalParentPath(forTargetURL: stdURL)
    }

    public var hasTruncatedDescendant: Bool {
        isTruncated || children.contains(where: \.hasTruncatedDescendant)
    }

    public var unlistedChildrenBytes: UInt64 {
        let childSum = children.reduce(into: UInt64(0)) { $0 &+= $1.bytes }
        return bytes > childSum ? (bytes - childSum) : 0
    }

    public var displayName: String {
        SafeFileReader.sanitizeForDisplay(name)
    }

    public func updatingProtection(using safetyGuard: SafetyGuard) -> DiskTreeNode {
        let protected = !safetyGuard.validateForRemoval(url).isAllowed
        let updatedChildren = children.map { $0.updatingProtection(using: safetyGuard) }
        return DiskTreeNode(
            url: url,
            name: name,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymlink: isSymlink,
            bytes: bytes,
            fileCount: fileCount,
            folderCount: folderCount,
            modificationDate: modificationDate,
            accessDate: accessDate,
            children: updatedChildren,
            isTruncated: isTruncated,
            truncatedChildCount: truncatedChildCount,
            isAccessible: isAccessible,
            isProtected: protected,
            isUserImmutable: isUserImmutable,
            isHidden: isHidden,
            expectedCanonicalParent: expectedCanonicalParent
        )
    }
}

public struct DiskScanProgress: Sendable, Equatable {
    public let scannedFiles: Int
    public let scannedFolders: Int
    public let totalBytes: UInt64
    public let currentPath: String
    public let elapsedSeconds: TimeInterval
    public let skippedSymlinks: Int
    public let skippedDataless: Int
    public let skippedCrossVolume: Int
    public let deduplicatedHardlinks: Int

    public init(
        scannedFiles: Int,
        scannedFolders: Int,
        totalBytes: UInt64,
        currentPath: String,
        elapsedSeconds: TimeInterval,
        skippedSymlinks: Int = 0,
        skippedDataless: Int = 0,
        skippedCrossVolume: Int = 0,
        deduplicatedHardlinks: Int = 0
    ) {
        self.scannedFiles = scannedFiles
        self.scannedFolders = scannedFolders
        self.totalBytes = totalBytes
        self.currentPath = currentPath
        self.elapsedSeconds = elapsedSeconds
        self.skippedSymlinks = skippedSymlinks
        self.skippedDataless = skippedDataless
        self.skippedCrossVolume = skippedCrossVolume
        self.deduplicatedHardlinks = deduplicatedHardlinks
    }
}

public struct VolumeStorageInfo: Identifiable, Sendable, Equatable, Hashable {
    public let id: String
    public let url: URL
    public let name: String
    public let totalBytes: UInt64
    public let availableBytes: UInt64
    public let usedBytes: UInt64
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isReadOnly: Bool
    public let fileSystemType: String?

    public init(
        url: URL,
        name: String,
        totalBytes: UInt64,
        availableBytes: UInt64,
        usedBytes: UInt64,
        isInternal: Bool,
        isRemovable: Bool,
        isReadOnly: Bool,
        fileSystemType: String?
    ) {
        let stdURL = url.standardizedFileURL
        self.id = stdURL.path
        self.url = stdURL
        self.name = name
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.usedBytes = usedBytes
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isReadOnly = isReadOnly
        self.fileSystemType = fileSystemType
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedBytes) / Double(totalBytes)))
    }
}

public enum DiskSizeThresholdPreset: UInt64, CaseIterable, Codable, Sendable, Hashable {
    case all = 0
    case mb50 = 50_000_000
    case mb100 = 100_000_000
    case mb500 = 500_000_000
    case gb1 = 1_000_000_000
}

public enum DiskAgePreset: Int, CaseIterable, Codable, Sendable, Hashable {
    case all = 0
    case days30 = 30
    case days90 = 90
    case days180 = 180
    case days365 = 365
}

public enum DiskAgeDateBasis: String, CaseIterable, Codable, Sendable, Hashable {
    case modificationDate
    case accessDate
    case latestOfModificationAndAccess
}

public enum DiskTreeFilterScope: String, CaseIterable, Codable, Sendable, Hashable {
    case filesOnly
    case filesAndPackages
    case allItems
}

public struct DiskEntryFilter: Sendable, Equatable, Hashable {
    public var minBytes: UInt64
    public var olderThanDays: Int?
    public var ageBasis: DiskAgeDateBasis
    public var scope: DiskTreeFilterScope
    public var excludeProtected: Bool
    public var includeHiddenFiles: Bool
    public var searchText: String
    public var maxResults: Int

    public init(
        minBytes: UInt64 = 0,
        olderThanDays: Int? = nil,
        ageBasis: DiskAgeDateBasis = .modificationDate,
        scope: DiskTreeFilterScope = .filesAndPackages,
        excludeProtected: Bool = false,
        includeHiddenFiles: Bool = true,
        searchText: String = "",
        maxResults: Int = 500
    ) {
        self.minBytes = minBytes
        self.olderThanDays = olderThanDays
        self.ageBasis = ageBasis
        self.scope = scope
        self.excludeProtected = excludeProtected
        self.includeHiddenFiles = includeHiddenFiles
        self.searchText = searchText
        self.maxResults = max(1, maxResults)
    }
}

public struct DiskFilteredItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let bytes: UInt64
    public let modificationDate: Date?
    public let accessDate: Date?
    public let expectedCanonicalParent: String
    public let isProtected: Bool
    public let isUserImmutable: Bool
    public let isHidden: Bool
    public let relativePathFromRoot: String

    public init(
        url: URL,
        name: String? = nil,
        isDirectory: Bool,
        isPackage: Bool = false,
        bytes: UInt64,
        modificationDate: Date? = nil,
        accessDate: Date? = nil,
        expectedCanonicalParent: String? = nil,
        isProtected: Bool = false,
        isUserImmutable: Bool = false,
        isHidden: Bool = false,
        relativePathFromRoot: String
    ) {
        let stdURL = url.standardizedFileURL
        self.id = stdURL.path
        self.url = stdURL
        self.name = name ?? stdURL.lastPathComponent
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.bytes = bytes
        self.modificationDate = modificationDate
        self.accessDate = accessDate
        self.expectedCanonicalParent = expectedCanonicalParent
            ?? PrivilegedExecutor.canonicalParentPath(forTargetURL: stdURL)
        self.isProtected = isProtected
        self.isUserImmutable = isUserImmutable
        self.isHidden = isHidden
        self.relativePathFromRoot = relativePathFromRoot
    }

    public var displayName: String {
        SafeFileReader.sanitizeForDisplay(name)
    }
}

public enum DiskScanError: Error, LocalizedError, Sendable, Equatable {
    case invalidPath(path: String)
    case notFound(path: String)
    case permissionDenied(path: String)
    case posixError(code: Int32, path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPath(path):
            return "Invalid filesystem path: '\(path)'"
        case let .notFound(path):
            return "Path does not exist: '\(path)'"
        case let .permissionDenied(path):
            return "Permission denied accessing: '\(path)'"
        case let .posixError(code, path, detail):
            return "POSIX error \(code) at '\(path)': \(detail)"
        }
    }
}

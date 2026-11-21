import Foundation

public enum AppSizeBucket: Int, CaseIterable, Sendable, Hashable {
    case over1GB = 0
    case mb100To1GB = 1
    case mb10To100 = 2
    case kb100To10MB = 3
    case under100KB = 4
    case calculating = 5

    public static func bucket(for size: Int64?) -> AppSizeBucket {
        guard let size else { return .calculating }
        if size >= 1_000_000_000 { return .over1GB }
        if size >= 100_000_000 { return .mb100To1GB }
        if size >= 10_000_000 { return .mb10To100 }
        if size >= 100_000 { return .kb100To10MB }
        return .under100KB
    }
}

public enum AppScanState: Sendable, Hashable {
    case idle
    case scanning
    case ready
}

public struct AppItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let localizedName: String
    public let bundleID: String
    public let version: String
    public let executableName: String?
    public let teamIdentifier: String?
    public let lastUsedDate: Date?
    public let modifiedDate: Date?
    public var bundleSize: Int64?
    public var serviceFiles: [ServiceFile]
    public var matchedPackageIDs: [String]
    public var isRunning: Bool
    public var isProtected: Bool
    public let isSystemProtected: Bool
    public let isAppleAppStoreApp: Bool
    public let requiresAdmin: Bool
    public var isChecked: Bool
    public var scanState: AppScanState
    /// Another installed copy uses the same bundle ID (e.g. a renamed duplicate), so its
    /// service files are shared and must not be pre-selected for removal.
    public var sharesBundleIDWithOtherApp: Bool = false
    /// Prevents redundant `pkgutil` re-enrichment on repeated selection of apps without receipts.
    public var hasEnrichedPackages: Bool = false

    public init(
        url: URL,
        name: String,
        localizedName: String,
        bundleID: String,
        version: String,
        executableName: String? = nil,
        teamIdentifier: String? = nil,
        lastUsedDate: Date? = nil,
        modifiedDate: Date? = nil,
        bundleSize: Int64? = nil,
        serviceFiles: [ServiceFile] = [],
        matchedPackageIDs: [String] = [],
        isRunning: Bool = false,
        isProtected: Bool = false,
        isSystemProtected: Bool = false,
        isAppleAppStoreApp: Bool = false,
        requiresAdmin: Bool = false,
        isChecked: Bool = false,
        scanState: AppScanState = .idle
    ) {
        self.id = url.path
        self.url = url
        self.name = name
        self.localizedName = localizedName
        self.bundleID = bundleID
        self.version = version
        self.executableName = executableName
        self.teamIdentifier = teamIdentifier
        self.lastUsedDate = lastUsedDate
        self.modifiedDate = modifiedDate
        self.bundleSize = bundleSize
        self.serviceFiles = serviceFiles
        self.matchedPackageIDs = matchedPackageIDs
        self.isRunning = isRunning
        self.isProtected = isProtected
        self.isSystemProtected = isSystemProtected
        self.isAppleAppStoreApp = isAppleAppStoreApp
        self.requiresAdmin = requiresAdmin
        self.isChecked = isChecked
        self.scanState = scanState
    }

    public var serviceFilesSize: Int64 {
        serviceFiles.reduce(0) { $0 + ($1.size ?? 0) }
    }

    public var totalSize: Int64? {
        guard let bundleSize else { return nil }
        return bundleSize + serviceFilesSize
    }

    public var displayDate: Date? {
        lastUsedDate ?? modifiedDate
    }

    public var sizeBucket: AppSizeBucket {
        AppSizeBucket.bucket(for: totalSize)
    }

    public var canUninstall: Bool {
        !isSystemProtected && !isProtected
    }
}

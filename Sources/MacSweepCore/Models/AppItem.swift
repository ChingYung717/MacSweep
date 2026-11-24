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

public enum AppVerificationStatus: String, Sendable, Hashable {
    case appleSystem
    case appStore
    case notarized
    case developerSigned
    case adHocOrUnsigned
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
    public let developerName: String?
    public var verificationStatus: AppVerificationStatus
    public let architectures: [String]
    public let minimumSystemVersion: String?
    public let applicationGroups: [String]
    public let embeddedBundleIDs: [String]
    public let embeddedAppNames: [String]
    public let privilegedHelperLabels: [String]
    public let expectedCanonicalParent: String
    public let lastUsedDate: Date?
    public let modifiedDate: Date?
    public var bundleSize: Int64?
    public var bundleFileCount: Int?
    public var bundleFolderCount: Int?
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
    /// Prevents redundant Gatekeeper notarization assessment on repeated selection.
    public var hasAssessedNotarization: Bool = false

    public init(
        url: URL,
        name: String,
        localizedName: String,
        bundleID: String,
        version: String,
        executableName: String? = nil,
        teamIdentifier: String? = nil,
        developerName: String? = nil,
        verificationStatus: AppVerificationStatus = .adHocOrUnsigned,
        architectures: [String] = [],
        minimumSystemVersion: String? = nil,
        applicationGroups: [String] = [],
        embeddedBundleIDs: [String] = [],
        embeddedAppNames: [String] = [],
        privilegedHelperLabels: [String] = [],
        expectedCanonicalParent: String? = nil,
        lastUsedDate: Date? = nil,
        modifiedDate: Date? = nil,
        bundleSize: Int64? = nil,
        bundleFileCount: Int? = nil,
        bundleFolderCount: Int? = nil,
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
        self.developerName = developerName
        self.verificationStatus = verificationStatus
        self.architectures = architectures
        self.minimumSystemVersion = minimumSystemVersion
        self.applicationGroups = applicationGroups
        self.embeddedBundleIDs = embeddedBundleIDs
        self.embeddedAppNames = embeddedAppNames
        self.privilegedHelperLabels = privilegedHelperLabels
        self.expectedCanonicalParent = expectedCanonicalParent
            ?? PrivilegedExecutor.canonicalParentPath(forTargetURL: url)
        self.lastUsedDate = lastUsedDate
        self.modifiedDate = modifiedDate
        self.bundleSize = bundleSize
        self.bundleFileCount = bundleFileCount
        self.bundleFolderCount = bundleFolderCount
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

    /// Total files across associated service files (excluding internal `.app` bundle files to match App Cleaner).
    public var associatedFileCount: Int {
        serviceFiles.reduce(0) { acc, sf in
            if let fc = sf.fileCount {
                return acc + fc
            }
            return acc + (sf.isDirectory ? 0 : 1)
        }
    }

    /// Total folders across associated service files (including each top-level service directory).
    public var associatedFolderCount: Int {
        serviceFiles.reduce(0) { acc, sf in
            if let dc = sf.folderCount {
                return acc + dc + (sf.isDirectory ? 1 : 0)
            }
            return acc + (sf.isDirectory ? 1 : 0)
        }
    }

    /// Total items (app bundle + all discovered service files & nested items).
    public var totalAssociatedItemCount: Int {
        1 + associatedFileCount + associatedFolderCount
    }

    public var architectureSummary: String? {
        let lower = Set(architectures.map { $0.lowercased() })
        let hasArm = lower.contains("arm64")
        let hasX86 = lower.contains("x86_64")
        if hasArm && hasX86 { return "Universal (Apple Silicon + Intel)" }
        if hasArm { return "Apple Silicon (arm64)" }
        if hasX86 { return "Intel (x86_64)" }
        return architectures.isEmpty ? nil : architectures.joined(separator: ", ")
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

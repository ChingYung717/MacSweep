import Foundation

public enum FileBrowserSort: String, CaseIterable, Codable, Sendable, Hashable {
    case name
    case size
    case modificationDate
    case kind
}

public enum FileBrowserFavoriteKind: String, CaseIterable, Codable, Sendable, Hashable {
    case home
    case desktop
    case documents
    case downloads
    case applications
    case caches
    case volume
}

public struct FileBrowserFavorite: Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: FileBrowserFavoriteKind
    public let title: String
    public let url: URL
    public let isAccessible: Bool

    public init(
        kind: FileBrowserFavoriteKind,
        title: String,
        url: URL,
        isAccessible: Bool
    ) {
        let stdURL = url.standardizedFileURL
        self.id = "\(kind.rawValue):\(stdURL.path)"
        self.kind = kind
        self.title = title
        self.url = stdURL
        self.isAccessible = isAccessible
    }
}

public typealias FileBrowserItem = FileBrowserEntry

public struct FileBrowserEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let name: String
    public let kind: FileItemKind
    public let sizeBytes: Int64
    public let modificationDate: Date?
    public let createdDate: Date?
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymbolicLink: Bool
    public let isSymlinkBroken: Bool
    public let isHidden: Bool
    public let isDataless: Bool
    public let isUserImmutable: Bool
    public let isSIPRestricted: Bool
    public let isProtected: Bool
    public let protectionReason: String?
    public let requiresAdmin: Bool
    public let utiIdentifier: String?
    public let kindDescription: String
    public let expectedCanonicalParent: String

    public init(
        url: URL,
        name: String? = nil,
        kind: FileItemKind,
        sizeBytes: Int64,
        modificationDate: Date?,
        createdDate: Date?,
        isDirectory: Bool,
        isPackage: Bool,
        isSymbolicLink: Bool,
        isSymlinkBroken: Bool,
        isHidden: Bool,
        isDataless: Bool,
        isUserImmutable: Bool,
        isSIPRestricted: Bool,
        isProtected: Bool,
        protectionReason: String?,
        requiresAdmin: Bool,
        utiIdentifier: String?,
        kindDescription: String,
        expectedCanonicalParent: String? = nil
    ) {
        let stdURL = url.standardizedFileURL
        self.id = stdURL.path
        self.url = stdURL
        self.name = name ?? stdURL.lastPathComponent
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modificationDate = modificationDate
        self.createdDate = createdDate
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.isSymlinkBroken = isSymlinkBroken
        self.isHidden = isHidden
        self.isDataless = isDataless
        self.isUserImmutable = isUserImmutable
        self.isSIPRestricted = isSIPRestricted
        self.isProtected = isProtected
        self.protectionReason = protectionReason
        self.requiresAdmin = requiresAdmin
        self.utiIdentifier = utiIdentifier
        self.kindDescription = kindDescription
        self.expectedCanonicalParent = expectedCanonicalParent
            ?? PrivilegedExecutor.canonicalParentPath(forTargetURL: stdURL)
    }

    public var isMutationLocked: Bool {
        isProtected || isSIPRestricted || isUserImmutable
    }

    public var displayName: String {
        SafeFileReader.sanitizeForDisplay(name)
    }

    public func updatingProtection(using safetyGuard: SafetyGuard) -> FileBrowserEntry {
        let res = safetyGuard.validateForRemoval(url)
        let prot: Bool
        let reason: String?
        switch res {
        case .allowed:
            prot = false
            reason = nil
        case let .blocked(r):
            prot = true
            reason = r
        }
        return FileBrowserEntry(
            url: url,
            name: name,
            kind: kind,
            sizeBytes: sizeBytes,
            modificationDate: modificationDate,
            createdDate: createdDate,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: isSymbolicLink,
            isSymlinkBroken: isSymlinkBroken,
            isHidden: isHidden,
            isDataless: isDataless,
            isUserImmutable: isUserImmutable,
            isSIPRestricted: isSIPRestricted,
            isProtected: prot,
            protectionReason: reason,
            requiresAdmin: requiresAdmin,
            utiIdentifier: utiIdentifier,
            kindDescription: kindDescription,
            expectedCanonicalParent: expectedCanonicalParent
        )
    }
}

public enum FilePreviewUnavailableReason: Sendable, Equatable, Hashable {
    case directory
    case symbolicLink
    case specialFile
    case datalessCloudFile
    case emptyFile
    case imageTooLarge(actualBytes: Int64?, maxBytes: Int)
    case permissionDenied
    case notFound
    case unreadable(errno: Int32)
}

public enum FilePreviewContent: Sendable, Equatable {
    case text(String, encodingDescription: String, isTruncated: Bool, totalBytes: Int64?)
    case hexDump(String, byteCount: Int, isTruncated: Bool, totalBytes: Int64?)
    case image(Data, utiIdentifier: String?, byteCount: Int)
    case unavailable(reason: FilePreviewUnavailableReason)
}

public struct FilePreviewPayload: Sendable, Equatable {
    public let metadata: FileMetadataInfo
    public let content: FilePreviewContent
    public let isProtected: Bool
    public let protectionReason: String?

    public init(
        metadata: FileMetadataInfo,
        content: FilePreviewContent,
        isProtected: Bool,
        protectionReason: String?
    ) {
        self.metadata = metadata
        self.content = content
        self.isProtected = isProtected
        self.protectionReason = protectionReason
    }
}

public enum FileBrowserError: Error, LocalizedError, Sendable, Equatable {
    case invalidPath(path: String)
    case notFound(path: String)
    case notADirectory(path: String)
    case tccOrPermissionDenied(path: String, needsFullDiskAccess: Bool)
    case posixError(code: Int32, path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPath(path):
            return "Invalid directory path: '\(path)'"
        case let .notFound(path):
            return "Directory does not exist: '\(path)'"
        case let .notADirectory(path):
            return "Path is not a directory: '\(path)'"
        case let .tccOrPermissionDenied(path, needsFullDiskAccess):
            if needsFullDiskAccess {
                return "Permission denied reading '\(path)'. Full Disk Access may be required."
            }
            return "Permission denied reading '\(path)'."
        case let .posixError(code, path, detail):
            return "POSIX error \(code) at '\(path)': \(detail)"
        }
    }
}

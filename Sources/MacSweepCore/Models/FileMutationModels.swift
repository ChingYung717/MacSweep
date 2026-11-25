import Foundation
import UniformTypeIdentifiers

public typealias FileMutationValidationResult = RemovalValidationResult

public enum FileItemKind: String, Sendable, Equatable, Hashable, Codable {
    case regularFile
    case directory
    case package
    case symbolicLink
    case special
}

public struct FileMetadataInfo: Sendable, Equatable, Hashable {
    public let url: URL
    public let name: String
    public let kind: FileItemKind
    public let sizeBytes: Int64
    public let allocatedSizeBytes: Int64?
    public let createdDate: Date?
    public let modifiedDate: Date?
    public let accessedDate: Date?
    public let posixPermissions: UInt16
    public let ownerUID: UInt32
    public let groupGID: UInt32
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymbolicLink: Bool
    public let isSymlinkBroken: Bool
    public let symlinkTarget: String?
    public let resolvedTargetPath: String?
    public let isUserImmutable: Bool
    public let isSIPRestricted: Bool
    public let isHidden: Bool
    public let isDataless: Bool
    public let utiIdentifier: String?
    public let kindDescription: String
    public let expectedCanonicalParent: String

    public var isSymlink: Bool { isSymbolicLink }
    public var posixPermissionsOctal: String { String(format: "%04o", posixPermissions) }

    public init(
        url: URL,
        name: String,
        kind: FileItemKind,
        sizeBytes: Int64,
        allocatedSizeBytes: Int64?,
        createdDate: Date?,
        modifiedDate: Date?,
        accessedDate: Date?,
        posixPermissions: UInt16,
        ownerUID: UInt32,
        groupGID: UInt32,
        isDirectory: Bool,
        isPackage: Bool,
        isSymbolicLink: Bool,
        isSymlinkBroken: Bool,
        symlinkTarget: String?,
        resolvedTargetPath: String?,
        isUserImmutable: Bool,
        isSIPRestricted: Bool,
        isHidden: Bool,
        isDataless: Bool,
        utiIdentifier: String?,
        kindDescription: String,
        expectedCanonicalParent: String
    ) {
        self.url = url
        self.name = name
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.allocatedSizeBytes = allocatedSizeBytes
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.accessedDate = accessedDate
        self.posixPermissions = posixPermissions
        self.ownerUID = ownerUID
        self.groupGID = groupGID
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymbolicLink = isSymbolicLink
        self.isSymlinkBroken = isSymlinkBroken
        self.symlinkTarget = symlinkTarget
        self.resolvedTargetPath = resolvedTargetPath
        self.isUserImmutable = isUserImmutable
        self.isSIPRestricted = isSIPRestricted
        self.isHidden = isHidden
        self.isDataless = isDataless
        self.utiIdentifier = utiIdentifier
        self.kindDescription = kindDescription
        self.expectedCanonicalParent = expectedCanonicalParent
    }
}

public enum FileMutationKind: String, Sendable, Equatable, Hashable, Codable {
    case move
    case rename
    case createDirectory
}

public struct FileMutationResult: Sendable, Equatable, Hashable {
    public let kind: FileMutationKind
    public let sourceURL: URL?
    public let destinationURL: URL
    public let resultingCanonicalParent: String
    public let timestamp: Date

    public init(
        kind: FileMutationKind,
        sourceURL: URL?,
        destinationURL: URL,
        resultingCanonicalParent: String,
        timestamp: Date = Date()
    ) {
        self.kind = kind
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.resultingCanonicalParent = resultingCanonicalParent
        self.timestamp = timestamp
    }
}

public enum FileOperationError: Error, LocalizedError, Sendable, Equatable {
    case invalidName(name: String, reason: String)
    case blockedBySafetyGuard(path: String, reason: String)
    case toctouMismatch(path: String, expectedParent: String, actualParent: String)
    case sourceNotFound(path: String)
    case destinationParentNotFound(path: String)
    case destinationNotADirectory(path: String)
    case destinationAlreadyExists(path: String)
    case cannotMoveDirectoryIntoItself(source: String, destination: String)
    case userImmutable(path: String)
    case permissionDenied(path: String, detail: String)
    case crossVolumeMoveFailed(source: String, destination: String, detail: String)
    case posixError(code: Int32, path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidName(name, reason):
            return "Invalid item name '\(name)': \(reason)"
        case let .blockedBySafetyGuard(path, reason):
            return "Operation blocked by SafetyGuard for '\(path)': \(reason)"
        case let .toctouMismatch(path, expectedParent, actualParent):
            return "Parent directory changed for '\(path)' (expected '\(expectedParent)', got '\(actualParent)')"
        case let .sourceNotFound(path):
            return "Source item does not exist: '\(path)'"
        case let .destinationParentNotFound(path):
            return "Destination parent directory does not exist: '\(path)'"
        case let .destinationNotADirectory(path):
            return "Destination parent is not a directory: '\(path)'"
        case let .destinationAlreadyExists(path):
            return "An item already exists at destination: '\(path)'"
        case let .cannotMoveDirectoryIntoItself(source, destination):
            return "Cannot move directory '\(source)' into itself or descendant '\(destination)'"
        case let .userImmutable(path):
            return "Item is locked with user immutable flag (uchg): '\(path)'"
        case let .permissionDenied(path, detail):
            return "Permission denied for '\(path)': \(detail)"
        case let .crossVolumeMoveFailed(source, destination, detail):
            return "Cross-volume move failed from '\(source)' to '\(destination)': \(detail)"
        case let .posixError(code, path, detail):
            return "POSIX error \(code) at '\(path)': \(detail)"
        }
    }
}

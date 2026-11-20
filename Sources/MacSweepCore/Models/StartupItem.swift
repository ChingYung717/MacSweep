import Foundation

public enum StartupScope: String, CaseIterable, Codable, Sendable, Hashable {
    case userAgent
    case systemAgent
    case systemDaemon
    case appLoginItem
}

public struct StartupItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let plistURL: URL
    public let programPath: String?
    public let programArguments: [String]
    public let scope: StartupScope
    public var isEnabled: Bool
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public let isOrphanedBinary: Bool
    public let associatedAppPath: String?
    public let associatedAppName: String?
    public let requiresAdmin: Bool
    public let canToggle: Bool
    public let canRemove: Bool
    public let fileSize: Int64

    public init(
        label: String,
        plistURL: URL,
        programPath: String?,
        programArguments: [String] = [],
        scope: StartupScope,
        isEnabled: Bool,
        runAtLoad: Bool = false,
        keepAlive: Bool = false,
        isOrphanedBinary: Bool = false,
        associatedAppPath: String? = nil,
        associatedAppName: String? = nil,
        requiresAdmin: Bool = false,
        canToggle: Bool = true,
        canRemove: Bool = true,
        fileSize: Int64 = 0
    ) {
        self.id = "\(scope.rawValue):\(plistURL.path)"
        self.label = label
        self.plistURL = plistURL
        self.programPath = programPath
        self.programArguments = programArguments
        self.scope = scope
        self.isEnabled = isEnabled
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.isOrphanedBinary = isOrphanedBinary
        self.associatedAppPath = associatedAppPath
        self.associatedAppName = associatedAppName
        self.requiresAdmin = requiresAdmin
        self.canToggle = canToggle
        self.canRemove = canRemove
        self.fileSize = fileSize
    }
}

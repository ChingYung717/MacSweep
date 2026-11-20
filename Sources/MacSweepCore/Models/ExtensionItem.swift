import Foundation

public enum ExtensionCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case browserChrome
    case browserEdge
    case browserBrave
    case browserArc
    case browserFirefox
    case browserSafari
    case appExtension
    case preferencePane
    case quickLook
    case spotlight
    case screenSaver
    case internetPlugin
    case audioPlugin

    public var isBrowser: Bool {
        switch self {
        case .browserChrome, .browserEdge, .browserBrave, .browserArc, .browserFirefox, .browserSafari:
            return true
        default:
            return false
        }
    }

    public var isChromium: Bool {
        switch self {
        case .browserChrome, .browserEdge, .browserBrave, .browserArc:
            return true
        default:
            return false
        }
    }
}

public struct ExtensionItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let identifier: String
    public let version: String
    public let category: ExtensionCategory
    public let path: URL
    public let profileName: String?
    public let hostAppPath: URL?
    public let browserBundleID: String?
    public var size: Int64
    public var isEnabled: Bool
    public let canToggle: Bool
    public let canRemove: Bool
    public let requiresAdmin: Bool
    public let requiresReboot: Bool
    public var isChecked: Bool

    public init(
        name: String,
        identifier: String,
        version: String = "",
        category: ExtensionCategory,
        path: URL,
        profileName: String? = nil,
        hostAppPath: URL? = nil,
        browserBundleID: String? = nil,
        size: Int64 = 0,
        isEnabled: Bool = true,
        canToggle: Bool = false,
        canRemove: Bool = true,
        requiresAdmin: Bool = false,
        requiresReboot: Bool = false,
        isChecked: Bool = false
    ) {
        self.id = "\(category.rawValue):\(identifier):\(path.path)"
        self.name = name
        self.identifier = identifier
        self.version = version
        self.category = category
        self.path = path
        self.profileName = profileName
        self.hostAppPath = hostAppPath
        self.browserBundleID = browserBundleID
        self.size = size
        self.isEnabled = isEnabled
        self.canToggle = canToggle
        self.canRemove = canRemove
        self.requiresAdmin = requiresAdmin
        self.requiresReboot = requiresReboot
        self.isChecked = isChecked
    }
}

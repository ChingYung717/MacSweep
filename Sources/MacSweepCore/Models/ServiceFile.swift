import Foundation

public enum ServiceFileCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case application
    case caches
    case preferences
    case applicationSupport
    case containers
    case groupContainers
    case logs
    case savedState
    case launchAgents
    case launchDaemons
    case webData
    case plugins
    case receipts
    case other

    public var sortOrder: Int {
        switch self {
        case .application: return 0
        case .applicationSupport: return 1
        case .containers: return 2
        case .groupContainers: return 3
        case .caches: return 4
        case .preferences: return 5
        case .launchAgents: return 6
        case .launchDaemons: return 7
        case .savedState: return 8
        case .webData: return 9
        case .logs: return 10
        case .plugins: return 11
        case .receipts: return 12
        case .other: return 13
        }
    }
}

public struct ServiceFile: Identifiable, Hashable, Sendable {
    public let id: String
    public let url: URL
    public let category: ServiceFileCategory
    public var size: Int64?
    public var isSelected: Bool
    public let requiresAdmin: Bool
    public let requiresReboot: Bool
    public let isSystemScope: Bool
    public let confidence: LeftoverConfidence?
    public let matchReason: String
    /// Canonical POSIX parent directory captured at scan / discovery time for TOCTOU verification.
    public let expectedCanonicalParent: String

    public init(
        url: URL,
        category: ServiceFileCategory,
        size: Int64? = nil,
        isSelected: Bool = true,
        requiresAdmin: Bool = false,
        requiresReboot: Bool = false,
        isSystemScope: Bool = false,
        confidence: LeftoverConfidence? = nil,
        matchReason: String = "",
        expectedCanonicalParent: String? = nil
    ) {
        self.id = url.path
        self.url = url
        self.category = category
        self.size = size
        self.isSelected = isSelected
        self.requiresAdmin = requiresAdmin
        self.requiresReboot = requiresReboot
        self.isSystemScope = isSystemScope
        self.confidence = confidence
        self.matchReason = matchReason
        self.expectedCanonicalParent = expectedCanonicalParent
            ?? PrivilegedExecutor.canonicalParentPath(forTargetURL: url)
    }

    public var displayName: String {
        url.lastPathComponent
    }
}

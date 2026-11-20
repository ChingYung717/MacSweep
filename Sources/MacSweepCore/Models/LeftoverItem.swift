import Foundation

public enum LeftoverConfidence: String, Codable, Sendable, Hashable, Comparable {
    case high
    case medium

    public static func < (lhs: LeftoverConfidence, rhs: LeftoverConfidence) -> Bool {
        if lhs == rhs { return false }
        return lhs == .high
    }
}

public struct LeftoverGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let groupName: String
    public let suspectedBundleID: String?
    public let confidence: LeftoverConfidence
    public var files: [ServiceFile]
    public var isChecked: Bool

    public init(
        id: String,
        groupName: String,
        suspectedBundleID: String?,
        confidence: LeftoverConfidence,
        files: [ServiceFile],
        isChecked: Bool? = nil
    ) {
        self.id = id
        self.groupName = groupName
        self.suspectedBundleID = suspectedBundleID
        self.confidence = confidence
        self.files = files
        self.isChecked = isChecked ?? (confidence == .high)
    }

    public var totalSize: Int64 {
        files.reduce(0) { $0 + ($1.size ?? 0) }
    }

    public var selectedSize: Int64 {
        files.filter(\.isSelected).reduce(0) { $0 + ($1.size ?? 0) }
    }

    public var requiresAdmin: Bool {
        files.contains(where: { $0.isSelected && $0.requiresAdmin })
    }
}

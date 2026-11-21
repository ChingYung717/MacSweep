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

    public var hasSystemScopeFiles: Bool {
        files.contains(where: \.isSystemScope)
    }

    public var hasUserScopeFiles: Bool {
        files.contains(where: { !$0.isSystemScope })
    }

    public var systemScopeFileCount: Int {
        files.filter(\.isSystemScope).count
    }

    /// Group-level toggle obeying F5:
    /// - Turning OFF unchecks every file in the group.
    /// - Turning ON checks ONLY user-scope (`!isSystemScope`) files; `/Library` system-scope entries
    ///   must always be opted into individually at the file row level.
    public mutating func applyGroupToggle(_ newChecked: Bool) {
        if !newChecked {
            for idx in files.indices {
                files[idx].isSelected = false
            }
            isChecked = false
            return
        }
        for idx in files.indices where !files[idx].isSystemScope {
            files[idx].isSelected = true
        }
        isChecked = files.contains(where: \.isSelected)
    }

    /// Selects ONLY per-file high-confidence, user-scope entries (never selects `/Library` system-scope files [F5]).
    public mutating func selectHighConfidenceOnly() {
        for idx in files.indices {
            let file = files[idx]
            files[idx].isSelected = !file.isSystemScope && file.confidence == .high
        }
        isChecked = files.contains(where: \.isSelected)
    }
}

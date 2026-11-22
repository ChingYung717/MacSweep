import Foundation

public struct CleanupRecord: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public let date: Date
    public let actionTitle: String
    public let mode: RemovalMode
    public let itemCount: Int
    public let freedBytes: Int64
    public let removedPaths: [String]

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        actionTitle: String,
        mode: RemovalMode,
        itemCount: Int,
        freedBytes: Int64,
        removedPaths: [String]
    ) {
        self.id = id
        self.date = date
        self.actionTitle = actionTitle
        self.mode = mode
        self.itemCount = itemCount
        self.freedBytes = freedBytes
        self.removedPaths = removedPaths
    }
}

public final class CleanupHistoryStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.fileURL = base.appendingPathComponent("MacSweep/history.json")
        }
    }

    public func load() -> [CleanupRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CleanupRecord].self, from: data)) ?? []
    }

    public func append(_ record: CleanupRecord) {
        var existing = load()
        existing.insert(record, at: 0)
        if existing.count > 100 {
            existing = Array(existing.prefix(100))
        }
        save(existing)
    }

    public func clear() {
        save([])
    }

    private func save(_ records: [CleanupRecord]) {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(records) {
            try? data.write(to: fileURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }
}

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

public final class CleanupHistoryStore: @unchecked Sendable {
    public static let maxBytes: Int = 4 * 1024 * 1024

    private let fileURL: URL
    private let lock = NSLock()
    private var hasWriteBlock: Bool = false

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.fileURL = base.appendingPathComponent("MacSweep/history.json")
        }
    }

    public var isWriteBlockedDueToLoadError: Bool {
        lock.withLock { hasWriteBlock }
    }

    public func load() -> [CleanupRecord] {
        lock.withLock {
            let (records, canOverwrite) = loadDetailedUnlocked()
            if !canOverwrite {
                hasWriteBlock = true
            }
            return records
        }
    }

    @discardableResult
    public func append(_ record: CleanupRecord) -> Bool {
        lock.withLock {
            guard !hasWriteBlock else { return false }
            var (existing, canOverwrite) = loadDetailedUnlocked()
            guard canOverwrite else {
                hasWriteBlock = true
                return false
            }
            existing.insert(record, at: 0)
            if existing.count > 100 {
                existing = Array(existing.prefix(100))
            }
            return saveUnlocked(existing)
        }
    }

    @discardableResult
    public func clear() -> Bool {
        lock.withLock {
            guard !hasWriteBlock else { return false }
            let (_, canOverwrite) = loadDetailedUnlocked()
            guard canOverwrite else {
                hasWriteBlock = true
                return false
            }
            return saveUnlocked([])
        }
    }

    private func loadDetailedUnlocked() -> (records: [CleanupRecord], canOverwrite: Bool) {
        switch SafeFileReader.readBoundedRegularFileDetailed(at: fileURL, maxBytes: Self.maxBytes) {
        case .notFound:
            return ([], true)
        case let .success(data):
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([CleanupRecord].self, from: data) {
                return (decoded, true)
            }
            return ([], false)
        case .oversized, .notRegularFile, .readError:
            return ([], false)
        }
    }

    @discardableResult
    private func saveUnlocked(_ records: [CleanupRecord]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return false }
        return SafeFileReader.writePrivateAtomically(data, to: fileURL)
    }
}

import Foundation

public enum ThemeMode: String, CaseIterable, Codable, Sendable, Hashable {
    case deepOcean
    case system
}

public enum AppLanguage: String, CaseIterable, Codable, Sendable, Hashable {
    case system
    case zhHans
    case en
}

public enum RemovalMode: String, CaseIterable, Codable, Sendable, Hashable {
    case trash
    case permanent
}

public struct SweepPreferences: Codable, Sendable, Equatable {
    public var themeMode: ThemeMode
    public var language: AppLanguage
    public var defaultRemovalMode: RemovalMode
    public var showSystemApps: Bool
    public var includeUtilitiesFolder: Bool
    public var protectedBundleIDs: [String]
    public var protectedPaths: [String]
    public var ignoredLeftoverIDs: [String]

    public init(
        themeMode: ThemeMode = .deepOcean,
        language: AppLanguage = .system,
        defaultRemovalMode: RemovalMode = .trash,
        showSystemApps: Bool = false,
        includeUtilitiesFolder: Bool = false,
        protectedBundleIDs: [String] = [],
        protectedPaths: [String] = [],
        ignoredLeftoverIDs: [String] = []
    ) {
        self.themeMode = themeMode
        self.language = language
        self.defaultRemovalMode = defaultRemovalMode
        self.showSystemApps = showSystemApps
        self.includeUtilitiesFolder = includeUtilitiesFolder
        self.protectedBundleIDs = protectedBundleIDs
        self.protectedPaths = protectedPaths
        self.ignoredLeftoverIDs = ignoredLeftoverIDs
    }
}

public final class PreferencesStore: @unchecked Sendable {
    public static let maxBytes: Int = 1 * 1024 * 1024

    private let fileURL: URL
    private let lock = NSLock()
    private var hasWriteBlock: Bool = false

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.fileURL = base.appendingPathComponent("MacSweep/preferences.json")
        }
    }

    public var isWriteBlockedDueToLoadError: Bool {
        lock.withLock { hasWriteBlock }
    }

    public func load() -> SweepPreferences {
        lock.withLock {
            let (prefs, canOverwrite) = loadDetailedUnlocked()
            if !canOverwrite {
                hasWriteBlock = true
            }
            return prefs
        }
    }

    @discardableResult
    public func save(_ prefs: SweepPreferences) -> Bool {
        lock.withLock {
            guard !hasWriteBlock else { return false }
            let (_, canOverwrite) = loadDetailedUnlocked()
            guard canOverwrite else {
                hasWriteBlock = true
                return false
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(prefs) else { return false }
            return SafeFileReader.writePrivateAtomically(data, to: fileURL)
        }
    }

    private func loadDetailedUnlocked() -> (prefs: SweepPreferences, canOverwrite: Bool) {
        switch SafeFileReader.readBoundedRegularFileDetailed(at: fileURL, maxBytes: Self.maxBytes) {
        case .notFound:
            return (SweepPreferences(), true)
        case let .success(data):
            if let prefs = try? JSONDecoder().decode(SweepPreferences.self, from: data) {
                return (prefs, true)
            }
            return (SweepPreferences(), false)
        case .oversized, .notRegularFile, .readError:
            return (SweepPreferences(), false)
        }
    }
}

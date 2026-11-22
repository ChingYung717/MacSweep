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

public final class PreferencesStore: Sendable {
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.fileURL = base.appendingPathComponent("MacSweep/preferences.json")
        }
    }

    public func load() -> SweepPreferences {
        guard let data = try? Data(contentsOf: fileURL),
              let prefs = try? JSONDecoder().decode(SweepPreferences.self, from: data) else {
            return SweepPreferences()
        }
        return prefs
    }

    public func save(_ prefs: SweepPreferences) {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(prefs) {
            try? data.write(to: fileURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }
}

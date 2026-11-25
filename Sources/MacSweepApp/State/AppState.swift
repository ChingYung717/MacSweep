import AppKit
import Combine
import Foundation
import MacSweepCore

/// Lightweight view-local reactive storage compatible with CommandLineTools (avoids SwiftUIMacros.@State).
@MainActor
final class LocalState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) {
        self.value = value
    }
}

public enum SettingsSheetTab: String, CaseIterable, Identifiable {
    case general
    case permissions
    case protection
    case history
    public var id: String { rawValue }
}

public struct DemoLaunchOptions: Sendable, Equatable {
    public var isDemoMode: Bool
    public var initialTab: MainTab?
    public var languageOverride: AppLanguage?
    public var themeOverride: ThemeMode?
    public var exportScreenshotsPath: String?
    public var parseError: String?

    public init(
        isDemoMode: Bool = false,
        initialTab: MainTab? = nil,
        languageOverride: AppLanguage? = nil,
        themeOverride: ThemeMode? = nil,
        exportScreenshotsPath: String? = nil,
        parseError: String? = nil
    ) {
        self.isDemoMode = isDemoMode
        self.initialTab = initialTab
        self.languageOverride = languageOverride
        self.themeOverride = themeOverride
        self.exportScreenshotsPath = exportScreenshotsPath
        self.parseError = parseError
    }

    public static func fromProcessInfo(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DemoLaunchOptions {
        var isDemoMode = (environment["MACSWEEP_DEMO_MODE"] == "1")
        var initialTab: MainTab?
        var languageOverride: AppLanguage?
        var themeOverride: ThemeMode?
        var exportPath: String?
        var parseError: String?

        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "--demo-mode" {
                isDemoMode = true
            } else if arg == "--export-screenshots" {
                if i + 1 >= arguments.count || arguments[i + 1].isEmpty || arguments[i + 1].hasPrefix("--") {
                    parseError = "Missing value for --export-screenshots"
                    break
                }
                exportPath = arguments[i + 1]
                i += 1
            } else if arg.hasPrefix("--export-screenshots=") {
                let val = String(arg.dropFirst("--export-screenshots=".count))
                if val.isEmpty {
                    parseError = "Missing value for --export-screenshots"
                    break
                }
                exportPath = val
            } else if arg == "--demo-tab" {
                if i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") {
                    initialTab = parseTab(arguments[i + 1])
                    if initialTab == nil && parseError == nil {
                        parseError = "Unknown --demo-tab value '\(arguments[i + 1])'"
                    }
                    i += 1
                } else if parseError == nil {
                    parseError = "Missing value for --demo-tab"
                }
            } else if arg.hasPrefix("--demo-tab=") {
                let val = String(arg.dropFirst("--demo-tab=".count))
                initialTab = parseTab(val)
                if initialTab == nil && parseError == nil {
                    parseError = "Unknown --demo-tab value '\(val)'"
                }
            } else if arg == "--demo-lang" {
                if i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") {
                    languageOverride = parseLang(arguments[i + 1])
                    if languageOverride == nil {
                        fputs("Warning: unknown --demo-lang value '\(arguments[i + 1])'\n", stderr)
                    }
                    i += 1
                } else {
                    fputs("Warning: missing value for --demo-lang\n", stderr)
                }
            } else if arg.hasPrefix("--demo-lang=") {
                let val = String(arg.dropFirst("--demo-lang=".count))
                languageOverride = parseLang(val)
                if languageOverride == nil {
                    fputs("Warning: unknown --demo-lang value '\(val)'\n", stderr)
                }
            } else if arg == "--demo-theme" {
                if i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") {
                    themeOverride = parseTheme(arguments[i + 1])
                    if themeOverride == nil {
                        fputs("Warning: unknown --demo-theme value '\(arguments[i + 1])'\n", stderr)
                    }
                    i += 1
                } else {
                    fputs("Warning: missing value for --demo-theme\n", stderr)
                }
            } else if arg.hasPrefix("--demo-theme=") {
                let val = String(arg.dropFirst("--demo-theme=".count))
                themeOverride = parseTheme(val)
                if themeOverride == nil {
                    fputs("Warning: unknown --demo-theme value '\(val)'\n", stderr)
                }
            }
            i += 1
        }

        if exportPath != nil && !isDemoMode && parseError == nil {
            parseError = "--export-screenshots requires --demo-mode or MACSWEEP_DEMO_MODE=1"
        }

        return DemoLaunchOptions(
            isDemoMode: isDemoMode,
            initialTab: initialTab,
            languageOverride: languageOverride,
            themeOverride: themeOverride,
            exportScreenshotsPath: exportPath,
            parseError: parseError
        )
    }

    private static func parseTab(_ raw: String) -> MainTab? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "applications", "apps": return .applications
        case "startup": return .startup
        case "extensions": return .extensions
        case "leftovers": return .leftovers
        case "filemanager", "file-manager", "files": return .fileManager
        case "junkcleaner", "junk-cleaner", "junk": return .junkCleaner
        case "resourcerelease", "resource-release", "resources": return .resourceRelease
        default: return nil
        }
    }

    private static func parseLang(_ raw: String) -> AppLanguage? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "en", "english": return .en
        case "zh", "zh-hans", "zh_hans", "zh-cn", "zhhans": return .zhHans
        case "system": return .system
        default: return nil
        }
    }

    private static func parseTheme(_ raw: String) -> ThemeMode? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "deepocean", "deep-ocean", "dark": return .deepOcean
        case "system", "light": return .system
        default: return nil
        }
    }
}

public enum ProtectedPathAddResult: Equatable {
    case added(String)
    case invalid
    case duplicate
    case saveFailed
}

public enum MainTab: String, CaseIterable, Identifiable, Sendable {
    case applications
    case startup
    case extensions
    case leftovers
    case fileManager
    case junkCleaner
    case resourceRelease

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .applications: return "app.badge"
        case .startup: return "paperplane.fill"
        case .extensions: return "puzzlepiece.extension.fill"
        case .leftovers: return "doc.text.magnifyingglass"
        case .fileManager: return "folder.fill"
        case .junkCleaner: return "wand.and.stars"
        case .resourceRelease: return "memorychip"
        }
    }
}

public enum AppSortOrder: String, CaseIterable, Identifiable {
    case size
    case name
    case lastUsed
    case modified

    public var id: String { rawValue }
}

public enum AppActionMode: String, CaseIterable, Identifiable {
    case uninstall
    case reset

    public var id: String { rawValue }
}

public struct PendingConfirmation: Identifiable {
    public let id = UUID()
    public let title: String
    public let isReset: Bool
    public let targets: [RemovalTarget]
    public let packageIDsToForget: [String]
    public let runningAppBundleIDs: [String]
    public let runningAppNames: [String]
    public let targetAppBundleIDs: [String]
    public let targetAppURLs: [URL]
    public let browserBundleIDsToRequireClosed: [String]
    public let hasAppleAppStoreApp: Bool
    public let hasChromiumExtension: Bool
    public let sourceTab: MainTab
    public let affectedAppIDs: [String]
    public let affectedStartupIDs: [String]
    public let affectedExtensionIDs: [String]
    public let affectedLeftoverIDs: [String]
    /// Preference domains eligible for `cfprefsd` cache flush after a successful reset (only flushed if
    /// their preference `.plist` was actually removed).
    public var resetBundleIDs: [String] = []
    /// Whether the reset target is a cryptographically verified Mac App Store Apple app (`defaults delete com.apple.*` allowed).
    public var resetAllowApple: Bool = false
    /// Whether any target carries the user-immutable (`chflags uchg`) lock flag and will be unlocked upon confirmation.
    public var hasUserLockedItems: Bool = false
    /// Optional override for pre-selected removal mode in `ConfirmationSheet` (e.g. Trash vs Permanent from File Browser).
    public var preferredRemovalModeOverride: RemovalMode? = nil
    /// When `true` (e.g., all targets are already inside `~/.Trash`), `.trash` mode is disallowed and only `.permanent` is permitted.
    public var forcePermanentMode: Bool = false
    /// `true` whenever one or more targets already reside inside `~/.Trash` (those items must be permanently emptied even when other targets in the same batch move to Trash).
    public var hasTrashItems: Bool = false

    public init(
        title: String,
        isReset: Bool,
        targets: [RemovalTarget],
        packageIDsToForget: [String],
        runningAppBundleIDs: [String],
        runningAppNames: [String],
        targetAppBundleIDs: [String],
        targetAppURLs: [URL],
        browserBundleIDsToRequireClosed: [String],
        hasAppleAppStoreApp: Bool,
        hasChromiumExtension: Bool,
        sourceTab: MainTab,
        affectedAppIDs: [String],
        affectedStartupIDs: [String],
        affectedExtensionIDs: [String],
        affectedLeftoverIDs: [String],
        resetBundleIDs: [String] = [],
        resetAllowApple: Bool = false,
        hasUserLockedItems: Bool = false,
        preferredRemovalModeOverride: RemovalMode? = nil,
        forcePermanentMode: Bool = false,
        hasTrashItems: Bool = false
    ) {
        self.title = title
        self.isReset = isReset
        self.targets = targets
        self.packageIDsToForget = packageIDsToForget
        self.runningAppBundleIDs = runningAppBundleIDs
        self.runningAppNames = runningAppNames
        self.targetAppBundleIDs = targetAppBundleIDs
        self.targetAppURLs = targetAppURLs
        self.browserBundleIDsToRequireClosed = browserBundleIDsToRequireClosed
        self.hasAppleAppStoreApp = hasAppleAppStoreApp
        self.hasChromiumExtension = hasChromiumExtension
        self.sourceTab = sourceTab
        self.affectedAppIDs = affectedAppIDs
        self.affectedStartupIDs = affectedStartupIDs
        self.affectedExtensionIDs = affectedExtensionIDs
        self.affectedLeftoverIDs = affectedLeftoverIDs
        self.resetBundleIDs = resetBundleIDs
        self.resetAllowApple = resetAllowApple
        self.hasUserLockedItems = hasUserLockedItems
        self.preferredRemovalModeOverride = preferredRemovalModeOverride
        self.forcePermanentMode = forcePermanentMode
        self.hasTrashItems = hasTrashItems
    }
}

public struct OperationBanner: Identifiable, Equatable {
    public let id = UUID()
    public let isError: Bool
    public let message: String
    public let showAppManagementLink: Bool
    public let showFDALink: Bool
    /// Apps that did not quit gracefully; the banner offers an explicit (user-confirmed) Force Quit.
    public var forceQuitBundleIDs: [String] = []
    public var forceQuitBundleURLs: [URL] = []
}

@MainActor
public final class AppState: ObservableObject {
    // Demo Mode
    public let isDemoMode: Bool
    private let demoCatalog: DemoFixtureCatalog?
    private var demoRunningBundleIDs: Set<String> = []

    // Navigation & Sheets
    @Published public var activeTab: MainTab = .applications
    @Published public var showSettingsSheet: Bool = false
    @Published public var settingsTab: SettingsSheetTab = .general
    @Published public var pendingConfirmation: PendingConfirmation?
    @Published public var banner: OperationBanner?

    // Preferences & Permissions
    @Published public var preferences: SweepPreferences
    @Published public var cleanupHistory: [CleanupRecord] = []
    @Published public var hasFullDiskAccess: Bool = false
    @Published public var isExpertMode: Bool = true

    // Shared Core Engines
    private let prefsStore: PreferencesStore?
    private let historyStore: CleanupHistoryStore?
    let sizer = DirectorySizer()
    private var libraryIndex: LibraryIndex?
    private var cachedThirdPartyPackages: [String]?
    private var ambiguousNames: Set<String> = []
    private var allInstalledBundleIDs: Set<String> = []
    private var allInstalledAppPaths: Set<String> = []
    private var allInstalledGroupOwners: [String: Set<String>] = [:]
    private var systemInventoryBundleIDs: Set<String> = []
    private var systemInventoryPathsByID: [String: Set<String>] = [:]
    private var systemInventoryGroupOwners: [String: Set<String>] = [:]

    private nonisolated static func mergeGroupOwners(
        _ lhs: [String: Set<String>],
        _ rhs: [String: Set<String>]
    ) -> [String: Set<String>] {
        var merged = lhs
        for (groupID, paths) in rhs {
            merged[groupID, default: []].formUnion(paths)
        }
        return merged
    }

    private nonisolated static func normalizedPathKey(_ path: String) -> String {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        if p.count > 1 && p.hasSuffix("/") {
            return String(p.dropLast())
        }
        return p
    }

    private nonisolated static func isSameOrDescendant(_ candidateNorm: String, ofNormalizedBase baseNorm: String) -> Bool {
        if baseNorm == "/" { return true }
        return candidateNorm == baseNorm || candidateNorm.hasPrefix(baseNorm + "/")
    }

    private nonisolated static func matchesAnyRemoved(_ path: String, removedNormalized: Set<String>) -> Bool {
        let norm = normalizedPathKey(path)
        return removedNormalized.contains(where: { isSameOrDescendant(norm, ofNormalizedBase: $0) })
    }

    // Tab 1: Applications
    @Published public var apps: [AppItem] = []
    @Published public var isScanningApps: Bool = false
    @Published public var isCalculatingSizes: Bool = false
    @Published public var appSearchText: String = ""
    @Published public var appSortOrder: AppSortOrder = .size
    @Published public var selectedAppID: String?
    @Published public var droppedApp: AppItem?
    @Published public var appActionMode: AppActionMode = .uninstall
    @Published public var includeAppBundleInRemoval: Bool = true
    @Published public var isPerformingRemoval: Bool = false

    // Tab 2: Startup
    @Published public var startupItems: [StartupItem] = []
    @Published public var isScanningStartup: Bool = false
    @Published public var startupSearchText: String = ""
    @Published public var togglingStartupIDs: Set<String> = []
    @Published public var selectedStartupID: String?

    // Tab 3: Extensions
    @Published public var extensionItems: [ExtensionItem] = []
    @Published public var isScanningExtensions: Bool = false
    @Published public var extensionsNeedFDAForBrowsers: Bool = false
    @Published public var blockedBrowserNames: [String] = []
    @Published public var extensionSearchText: String = ""
    @Published public var togglingExtensionIDs: Set<String> = []
    @Published public var selectedExtensionID: String?

    // Tab 4: Leftovers
    @Published public var leftoverGroups: [LeftoverGroup] = []
    @Published public var isScanningLeftovers: Bool = false
    @Published public var leftoverSearchText: String = ""
    @Published public var selectedLeftoverGroupID: String?

    // Tab 5: File Manager
    public let fileManagerStore = FileManagerStore()

    // Tabs 6 & 7: Junk Cleaner & Resource Release
    public let cleanupCenterStore = CleanupCenterStore()

    private var scanGeneration: Int = 0
    private var sizeTask: Task<Void, Never>?

    public var l10n: L10n {
        L10n(language: preferences.language)
    }

    public var homeDirectoryURL: URL {
        isDemoMode ? DemoFixtureCatalog.homeDirectoryURL : FileManager.default.homeDirectoryForCurrentUser
    }

    public var safetyGuard: SafetyGuard {
        SafetyGuard(
            homeDirectory: homeDirectoryURL,
            selfBundlePath: isDemoMode ? "/Applications/MacSweep.app" : Bundle.main.bundlePath,
            protectedPaths: preferences.protectedPaths,
            protectedBundleIDs: preferences.protectedBundleIDs
        )
    }

    public init(launchOptions: DemoLaunchOptions = .fromProcessInfo()) {
        self.isDemoMode = launchOptions.isDemoMode
        IconCache.shared.isDemoMode = launchOptions.isDemoMode

        if launchOptions.isDemoMode {
            self.prefsStore = nil
            self.historyStore = nil
            let catalog = DemoFixtureCatalog.default
            self.demoCatalog = catalog
            self.demoRunningBundleIDs = catalog.runningBundleIDs
            var prefs = catalog.defaultPreferences
            if let lang = launchOptions.languageOverride {
                prefs.language = lang
            }
            if let theme = launchOptions.themeOverride {
                prefs.themeMode = theme
            }
            self.preferences = prefs
            self.cleanupHistory = catalog.cleanupHistory
            self.hasFullDiskAccess = true
            self.activeTab = launchOptions.initialTab ?? .applications
            self.fileManagerStore.attach(to: self)
            self.cleanupCenterStore.attach(to: self)
            self.loadDemoData(from: catalog)
        } else {
            self.demoCatalog = nil
            let ps = PreferencesStore()
            let hs = CleanupHistoryStore()
            self.prefsStore = ps
            self.historyStore = hs
            let loaded = ps.load()
            self.preferences = loaded
            self.cleanupHistory = hs.load()
            self.hasFullDiskAccess = PermissionChecker.checkFullDiskAccess().hasFullDiskAccess
            self.fileManagerStore.attach(to: self)
            self.cleanupCenterStore.attach(to: self)
            let realHome = FileManager.default.homeDirectoryForCurrentUser
            self.fileManagerStore.configureInitialDirectory(realHome)
            self.cleanupCenterStore.configureInitialDirectory(realHome)
        }
    }

    private func loadDemoData(from catalog: DemoFixtureCatalog) {
        apps = catalog.applications
        selectedAppID = catalog.defaultSelectedAppID
        isScanningApps = false
        isCalculatingSizes = false
        droppedApp = nil

        startupItems = catalog.startupItems
        selectedStartupID = catalog.defaultSelectedStartupID
        isScanningStartup = false

        extensionItems = catalog.extensionItems
        selectedExtensionID = catalog.defaultSelectedExtensionID
        extensionsNeedFDAForBrowsers = catalog.extensionScanResult.needsFullDiskAccessForBrowsers
        blockedBrowserNames = catalog.extensionScanResult.blockedBrowserNames
        isScanningExtensions = false

        leftoverGroups = catalog.leftoverGroups
        selectedLeftoverGroupID = catalog.defaultSelectedLeftoverGroupID
        isScanningLeftovers = false

        refreshAppProtectionFlags()
        fileManagerStore.loadDemoCatalog(catalog)
        cleanupCenterStore.loadDemoCatalog(catalog)
    }

    // MARK: - Demo Helpers

    func demoPlistPreview(for item: StartupItem) -> String? {
        demoCatalog?.plistPreview(for: item.plistURL)
    }

    func demoPathExists(_ path: String) -> Bool {
        if let resolved = fileManagerStore.demoPathState(path) {
            return resolved
        }
        return demoCatalog?.pathExists(path) ?? false
    }

    func demoDirectoryChildren(for url: URL) -> [(url: URL, name: String, isDirectory: Bool, isSymbolicLink: Bool, size: Int64?)] {
        demoCatalog?.directoryChildren(for: url) ?? []
    }

    func isDemoBrowserRunning(bundleID: String) -> Bool {
        demoRunningBundleIDs.contains(bundleID.lowercased())
    }

    func openDemoOrRealTrash() {
        if isDemoMode {
            banner = OperationBanner(
                isError: false,
                message: l10n.t("演示模式：已打开废纸篓（~/.Trash）", "Demo mode: Open Trash (/Users/alex/.Trash)"),
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }
        NSWorkspace.shared.open(homeDirectoryURL.appendingPathComponent(".Trash"))
    }

    // MARK: - Persistence & Permissions

    @discardableResult
    public func savePreferences() -> Bool {
        if isDemoMode {
            refreshAppProtectionFlags()
            fileManagerStore.refreshProtectionFlags(using: safetyGuard)
            cleanupCenterStore.refreshProtectionFlags(using: safetyGuard)
            return true
        }
        let saved = prefsStore?.save(preferences) ?? false
        refreshAppProtectionFlags()
        fileManagerStore.refreshProtectionFlags(using: safetyGuard)
        cleanupCenterStore.refreshProtectionFlags(using: safetyGuard)
        return saved
    }

    func refreshPermissionStatus() {
        if isDemoMode {
            hasFullDiskAccess = true
            return
        }
        hasFullDiskAccess = PermissionChecker.checkFullDiskAccess().hasFullDiskAccess
    }

    func openSystemSettings(_ url: URL) {
        if isDemoMode {
            banner = OperationBanner(
                isError: false,
                message: l10n.t("演示模式：已模拟打开系统设置", "Demo mode: System Settings action simulated"),
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ url: URL) {
        if isDemoMode {
            banner = OperationBanner(
                isError: false,
                message: l10n.t("演示模式：在 Finder 中显示 \(url.path)", "Demo mode: Reveal in Finder (\(url.path))"),
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealSelfAppInFinder() {
        if isDemoMode {
            revealInFinder(URL(fileURLWithPath: "/Applications/MacSweep.app"))
            return
        }
        let bundleURL = Bundle.main.bundleURL
        let targetURL = bundleURL.pathExtension.lowercased() == "app"
            ? bundleURL
            : (Bundle.main.executableURL ?? bundleURL)
        NSWorkspace.shared.activateFileViewerSelecting([targetURL])
    }

    func clearHistory() {
        if isDemoMode {
            cleanupHistory = []
            return
        }
        historyStore?.clear()
        cleanupHistory = []
    }

    // MARK: - Applications Scanning

    func loadInitialDataIfNeeded() async {
        if isDemoMode { return }
        refreshPermissionStatus()
        if apps.isEmpty && !isScanningApps {
            await scanApplications()
        }
    }

    func scanApplications() async {
        if isDemoMode {
            if let catalog = demoCatalog {
                apps = catalog.applications
                refreshAppProtectionFlags()
                if let sel = selectedAppID, !apps.contains(where: { $0.id == sel }) {
                    selectedAppID = catalog.defaultSelectedAppID
                }
            }
            isScanningApps = false
            isCalculatingSizes = false
            return
        }
        scanGeneration += 1
        let gen = scanGeneration
        sizeTask?.cancel()
        isScanningApps = true
        isCalculatingSizes = true
        droppedApp = nil

        let guardCopy = safetyGuard
        let includeUtil = preferences.includeUtilitiesFolder
        let showSys = preferences.showSystemApps

        let (scannedApps, index, thirdPartyPkgs, ambiguous, installedIDs, installedPaths, fullInventory, sysGroupOwners, allGroupOwners) = await Task.detached(priority: .userInitiated) {
            let index = LibraryIndex.build(safetyGuard: guardCopy)
            let scanner = AppScanner(
                includeUtilities: includeUtil,
                showSystemApps: showSys,
                safetyGuard: guardCopy
            )
            let matcher = ServiceFileMatcher(safetyGuard: guardCopy)
            var found = scanner.scanApplications()
            let fullInventory = AppScanner.allInstalledBundleIdentities()
            let ambiguous = ServiceFileMatcher.ambiguousNameCandidates(across: found)
            let scannedIDs = Set(found.map { $0.bundleID.lowercased() }.filter { !$0.hasPrefix("unknown.") })
            let installedIDs = scannedIDs.union(fullInventory.bundleIDs)
            let installedPaths = Set(found.map { $0.url.standardizedFileURL.path })
                .union(fullInventory.bundlePathsByID.values.flatMap { $0 })
            let scannedPathKeys = Set(found.map { Self.normalizedPathKey($0.url.path) })
            let scannedGroupOwners = ServiceFileMatcher.applicationGroupOwners(across: found)
            let sysGroupOwners = AppScanner.supplementalApplicationGroupOwners(
                from: fullInventory.bundlePathsByID,
                excludingNormalizedPaths: scannedPathKeys
            )
            let allGroupOwners = Self.mergeGroupOwners(scannedGroupOwners, sysGroupOwners)

            var bundleIDCounts: [String: Int] = [:]
            for app in found { bundleIDCounts[app.bundleID.lowercased(), default: 0] += 1 }
            for i in found.indices {
                let lowerID = found[i].bundleID.lowercased()
                let appPathNorm = Self.normalizedPathKey(found[i].url.path)
                let hasOtherSystemCopy = (fullInventory.bundlePathsByID[lowerID] ?? []).contains {
                    Self.normalizedPathKey($0) != appPathNorm
                }
                let otherGroups = ServiceFileMatcher.otherInstalledApplicationGroups(
                    for: found[i],
                    groupOwners: allGroupOwners
                )
                var matched = matcher.matchInMemory(
                    app: found[i],
                    index: index,
                    ambiguousNames: ambiguous,
                    allInstalledBundleIDs: installedIDs,
                    otherInstalledAppGroups: otherGroups
                )
                if (bundleIDCounts[lowerID] ?? 0) > 1 || hasOtherSystemCopy {
                    found[i].sharesBundleIDWithOtherApp = true
                    found[i].isRunning = !AppScanner.runningProcesses(
                        matchingBundleIDs: [],
                        bundleURLs: [found[i].url]
                    ).isEmpty
                    for j in matched.indices { matched[j].isSelected = false }
                }
                found[i].serviceFiles = matched
                found[i].scanState = .ready
            }
            let pkgs = ServiceFileMatcher.listThirdPartyPackages()
            return (found, index, pkgs, ambiguous, installedIDs, installedPaths, fullInventory, sysGroupOwners, allGroupOwners)
        }.value

        guard gen == scanGeneration else { return }
        self.libraryIndex = index
        self.cachedThirdPartyPackages = thirdPartyPkgs
        self.ambiguousNames = ambiguous
        self.systemInventoryBundleIDs = fullInventory.bundleIDs
        self.systemInventoryPathsByID = fullInventory.bundlePathsByID
        self.systemInventoryGroupOwners = sysGroupOwners
        self.allInstalledBundleIDs = installedIDs
        self.allInstalledAppPaths = installedPaths
        self.allInstalledGroupOwners = allGroupOwners
        self.apps = scannedApps
        self.isScanningApps = false

        if let sel = selectedAppID, !apps.contains(where: { $0.id == sel }) {
            selectedAppID = nil
        }

        startBackgroundSizeCalculation(generation: gen)
    }

    private func startBackgroundSizeCalculation(generation: Int) {
        sizeTask?.cancel()
        let currentApps = self.apps
        let sizerRef = self.sizer

        sizeTask = Task.detached(priority: .utility) { [weak self] in
            let batchSize = 8
            for start in stride(from: 0, to: currentApps.count, by: batchSize) {
                if Task.isCancelled { return }
                let end = min(start + batchSize, currentApps.count)
                let slice = Array(currentApps[start..<end])

                var urlsToSize: [URL] = []
                for app in slice {
                    urlsToSize.append(app.url)
                    for sf in app.serviceFiles {
                        urlsToSize.append(sf.url)
                    }
                }
                let sizedMap = await sizerRef.measurements(of: urlsToSize, maxConcurrency: 6)
                if Task.isCancelled { return }

                await MainActor.run { [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    for app in slice {
                        guard let idx = self.apps.firstIndex(where: { $0.id == app.id }) else { continue }
                        let bundleKey = self.apps[idx].url.standardizedFileURL.path
                        if let bundleMeas = sizedMap[bundleKey] {
                            self.apps[idx].bundleSize = bundleMeas.bytes
                            self.apps[idx].bundleFileCount = bundleMeas.fileCount
                            self.apps[idx].bundleFolderCount = bundleMeas.folderCount
                        } else {
                            self.apps[idx].bundleSize = 0
                        }
                        for sfIdx in self.apps[idx].serviceFiles.indices {
                            let sfKey = self.apps[idx].serviceFiles[sfIdx].url.standardizedFileURL.path
                            if let meas = sizedMap[sfKey] {
                                self.apps[idx].serviceFiles[sfIdx].size = meas.bytes
                                self.apps[idx].serviceFiles[sfIdx].fileCount = meas.fileCount
                                self.apps[idx].serviceFiles[sfIdx].folderCount = meas.folderCount
                            }
                        }
                    }
                }
            }

            await MainActor.run { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.isCalculatingSizes = false
            }
        }
    }

    /// Lazy pkgutil enrichment (idempotent via `hasEnrichedPackages` and guarded by `scanGeneration`).
    func selectApp(id: String?) {
        droppedApp = nil
        selectedAppID = id
        appActionMode = .uninstall
        includeAppBundleInRemoval = true
        guard let id else { return }
        enrichSelectedAppWithPackages(appID: id)
    }

    private func enrichSelectedAppWithPackages(appID: String) {
        guard !isDemoMode else { return }
        guard let idx = apps.firstIndex(where: { $0.id == appID }) else { return }
        let targetApp = apps[idx]
        guard !targetApp.hasEnrichedPackages,
              let index = libraryIndex,
              let allPkgs = cachedThirdPartyPackages else {
            return
        }
        let gen = scanGeneration
        let guardCopy = safetyGuard
        let sizerRef = sizer
        let ambiguous = ambiguousNames
        let installedIDs = allInstalledBundleIDs
        let otherPaths = allInstalledAppPaths.subtracting([targetApp.url.standardizedFileURL.path])
        let otherGroups = ServiceFileMatcher.otherInstalledApplicationGroups(
            for: targetApp,
            groupOwners: allInstalledGroupOwners
        )
        let shared = targetApp.sharesBundleIDWithOtherApp

        Task.detached(priority: .userInitiated) { [weak self] in
            let matcher = ServiceFileMatcher(safetyGuard: guardCopy)
            let result = matcher.matchWithPackages(
                app: targetApp,
                index: index,
                allPackageIDs: allPkgs,
                ambiguousNames: ambiguous,
                allInstalledBundleIDs: installedIDs,
                otherInstalledAppPaths: otherPaths,
                otherInstalledAppGroups: otherGroups
            )
            // Keep only entries still present on disk so deleted files can never resurrect.
            let liveFiles = result.files.filter { RemovalEngine.entryExists($0.url) }
            let allURLs = [targetApp.url] + liveFiles.map(\.url)
            let measMap = await sizerRef.measurements(of: allURLs, maxConcurrency: 6)

            var sizedFiles = liveFiles
            for i in sizedFiles.indices {
                let key = sizedFiles[i].url.standardizedFileURL.path
                if let meas = measMap[key] {
                    sizedFiles[i].size = meas.bytes
                    sizedFiles[i].fileCount = meas.fileCount
                    sizedFiles[i].folderCount = meas.folderCount
                } else {
                    sizedFiles[i].size = 0
                }
                if shared { sizedFiles[i].isSelected = false }
            }
            let bundleMeas = measMap[targetApp.url.standardizedFileURL.path]
            let bundleSize = bundleMeas?.bytes ?? targetApp.bundleSize ?? 0
            let bundleFileCount = bundleMeas?.fileCount ?? targetApp.bundleFileCount
            let bundleFolderCount = bundleMeas?.folderCount ?? targetApp.bundleFolderCount
            let assessedStatus = targetApp.hasAssessedNotarization
                ? nil
                : AppScanner.assessGatekeeperStatus(at: targetApp.url)
            let pkgIDs = shared ? [] : result.matchedPackageIDs
            let safeMatchIDs = AppScanner.safeProcessMatchBundleID(for: targetApp).map { [$0] } ?? []
            let isRunningNow = !AppScanner.runningProcesses(
                matchingBundleIDs: safeMatchIDs,
                bundleURLs: [targetApp.url]
            ).isEmpty

            let immutableSized = sizedFiles
            await MainActor.run { [weak self] in
                guard let self, self.scanGeneration == gen,
                      let liveIdx = self.apps.firstIndex(where: { $0.id == appID }) else {
                    return
                }
                let existingSelection = Dictionary(
                    uniqueKeysWithValues: self.apps[liveIdx].serviceFiles.map { ($0.id, $0.isSelected) }
                )
                var merged = immutableSized
                for i in merged.indices {
                    if let prev = existingSelection[merged[i].id] {
                        merged[i].isSelected = prev
                    }
                }
                self.apps[liveIdx].bundleSize = bundleSize
                self.apps[liveIdx].bundleFileCount = bundleFileCount
                self.apps[liveIdx].bundleFolderCount = bundleFolderCount
                if let assessedStatus {
                    self.apps[liveIdx].verificationStatus = assessedStatus
                }
                self.apps[liveIdx].hasAssessedNotarization = true
                self.apps[liveIdx].serviceFiles = merged
                self.apps[liveIdx].matchedPackageIDs = pkgIDs
                self.apps[liveIdx].hasEnrichedPackages = true
                self.apps[liveIdx].isRunning = isRunningNow
            }
        }
    }

    /// Handles Drag & Drop of any `.app` bundle (even outside `/Applications`) or Dock drop.
    public func inspectDroppedApp(at url: URL) {
        guard url.isFileURL,
              !url.path.contains("\0"),
              url.pathExtension.lowercased() == "app" else { return }
        if safetyGuard.isSelfApp(bundleID: nil, url: url) {
            banner = OperationBanner(
                isError: true,
                message: l10n.t("MacSweep 受自我保护，无法卸载或重置自身。", "MacSweep is self-protected and cannot uninstall or reset itself."),
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }
        activeTab = .applications

        let stdPath = url.standardizedFileURL.path
        let stdPathNorm = Self.normalizedPathKey(stdPath)
        if let existing = apps.first(where: { Self.normalizedPathKey($0.url.path) == stdPathNorm }) {
            selectApp(id: existing.id)
            return
        }
        if isDemoMode {
            banner = OperationBanner(
                isError: false,
                message: l10n.t("演示模式：仅展示预置脱敏应用。", "Demo mode: showing curated demo applications only."),
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }

        let guardCopy = safetyGuard
        let existingIndex = libraryIndex
        let existingPkgs = cachedThirdPartyPackages
        let sizerRef = sizer
        let knownApps = apps
        let knownSysGroupOwners = systemInventoryGroupOwners
        let includeUtil = preferences.includeUtilitiesFolder
        let showSys = preferences.showSystemApps

        Task.detached(priority: .userInitiated) { [weak self] in
            let scanner = AppScanner(
                includeUtilities: includeUtil,
                showSystemApps: showSys,
                safetyGuard: guardCopy
            )
            guard var inspected = scanner.inspectApp(at: url) else { return }
            let installedApps = knownApps.isEmpty ? scanner.scanApplications() : knownApps
            let fullInventory = AppScanner.allInstalledBundleIdentities()
            let index = existingIndex ?? LibraryIndex.build(safetyGuard: guardCopy)
            let pkgs = existingPkgs ?? ServiceFileMatcher.listThirdPartyPackages()
            let allApps = installedApps + [inspected]
            let ambiguous = ServiceFileMatcher.ambiguousNameCandidates(across: allApps)
            let installedIDs = Set(allApps.map { $0.bundleID.lowercased() }.filter { !$0.hasPrefix("unknown.") })
                .union(fullInventory.bundleIDs)
            let otherPaths = Set(
                (installedApps.map { $0.url.standardizedFileURL.path }
                    + fullInventory.bundlePathsByID.values.flatMap { $0 })
                    .filter { Self.normalizedPathKey($0) != stdPathNorm }
            )
            let installedPathKeys = Set(installedApps.map { Self.normalizedPathKey($0.url.path) })
            let installedGroupOwners = ServiceFileMatcher.applicationGroupOwners(across: installedApps)
            let supplementalOwners = knownApps.isEmpty
                ? AppScanner.supplementalApplicationGroupOwners(
                    from: fullInventory.bundlePathsByID,
                    excludingNormalizedPaths: installedPathKeys
                )
                : knownSysGroupOwners
            let combinedGroupOwners = Self.mergeGroupOwners(installedGroupOwners, supplementalOwners)
            let otherGroups = ServiceFileMatcher.otherInstalledApplicationGroups(
                for: inspected,
                groupOwners: combinedGroupOwners
            )
            let lowerInspectedID = inspected.bundleID.lowercased()
            let sharedWithScanned = installedApps.contains {
                $0.bundleID.lowercased() == lowerInspectedID
                    && Self.normalizedPathKey($0.url.path) != stdPathNorm
            }
            let sharedWithSystemOrUtilities = (fullInventory.bundlePathsByID[lowerInspectedID] ?? []).contains {
                Self.normalizedPathKey($0) != stdPathNorm
            }
            let shared = sharedWithScanned || sharedWithSystemOrUtilities
            let matcher = ServiceFileMatcher(safetyGuard: guardCopy)
            let matched = matcher.matchWithPackages(
                app: inspected,
                index: index,
                allPackageIDs: pkgs,
                ambiguousNames: ambiguous,
                allInstalledBundleIDs: installedIDs,
                otherInstalledAppPaths: otherPaths,
                otherInstalledAppGroups: otherGroups
            )

            let urls = [inspected.url] + matched.files.map(\.url)
            let measMap = await sizerRef.measurements(of: urls, maxConcurrency: 6)

            if let bundleMeas = measMap[inspected.url.standardizedFileURL.path] {
                inspected.bundleSize = bundleMeas.bytes
                inspected.bundleFileCount = bundleMeas.fileCount
                inspected.bundleFolderCount = bundleMeas.folderCount
            } else {
                inspected.bundleSize = 0
            }
            if let assessedStatus = AppScanner.assessGatekeeperStatus(at: inspected.url) {
                inspected.verificationStatus = assessedStatus
            }
            inspected.hasAssessedNotarization = true
            inspected.sharesBundleIDWithOtherApp = shared
            inspected.hasEnrichedPackages = true
            let safeMatchIDs = AppScanner.safeProcessMatchBundleID(for: inspected).map { [$0] } ?? []
            inspected.isRunning = !AppScanner.runningProcesses(
                matchingBundleIDs: safeMatchIDs,
                bundleURLs: [inspected.url]
            ).isEmpty
            inspected.serviceFiles = matched.files.map { sf in
                var copy = sf
                if let meas = measMap[sf.url.standardizedFileURL.path] {
                    copy.size = meas.bytes
                    copy.fileCount = meas.fileCount
                    copy.folderCount = meas.folderCount
                } else {
                    copy.size = 0
                }
                if shared { copy.isSelected = false }
                return copy
            }
            inspected.matchedPackageIDs = shared ? [] : matched.matchedPackageIDs
            inspected.scanState = .ready

            let finalInspected = inspected
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.selectedAppID = nil
                self.droppedApp = finalInspected
                self.appActionMode = .uninstall
                self.includeAppBundleInRemoval = true
            }
        }
    }

    // MARK: - App Selection, Mode & Protection Helpers

    var activeDetailApp: AppItem? {
        if let droppedApp { return droppedApp }
        if let selectedAppID, let found = apps.first(where: { $0.id == selectedAppID }) {
            return found
        }
        // If exactly 1 app is checked and no explicit row selected, show its full detail tree.
        if checkedApps.count == 1 {
            return checkedApps.first
        }
        return nil
    }

    var checkedApps: [AppItem] {
        apps.filter { $0.isChecked && $0.canUninstall }
    }

    var filteredAndSortedApps: [AppItem] {
        let query = appSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered: [AppItem]
        if query.isEmpty {
            filtered = apps
        } else {
            filtered = apps.filter {
                $0.localizedName.lowercased().contains(query)
                    || $0.name.lowercased().contains(query)
                    || $0.bundleID.lowercased().contains(query)
            }
        }

        return filtered.sorted { lhs, rhs in
            switch appSortOrder {
            case .size:
                let ls = lhs.totalSize ?? -1
                let rs = rhs.totalSize ?? -1
                if ls != rs { return ls > rs }
                return lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
            case .name:
                return lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
            case .lastUsed:
                let ld = lhs.lastUsedDate ?? .distantPast
                let rd = rhs.lastUsedDate ?? .distantPast
                if ld != rd { return ld > rd }
                return lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
            case .modified:
                let ld = lhs.modifiedDate ?? .distantPast
                let rd = rhs.modifiedDate ?? .distantPast
                if ld != rd { return ld > rd }
                return lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
            }
        }
    }

    func toggleAppChecked(_ appID: String) {
        guard let idx = apps.firstIndex(where: { $0.id == appID }), apps[idx].canUninstall else { return }
        apps[idx].isChecked.toggle()
        if apps[idx].isChecked {
            enrichSelectedAppWithPackages(appID: appID)
        }
    }

    func setAppActionMode(_ mode: AppActionMode) {
        appActionMode = mode
        includeAppBundleInRemoval = (mode == .uninstall)
    }

    func toggleServiceFile(appID: String, fileID: String) {
        if var dropped = droppedApp, dropped.id == appID {
            guard dropped.canUninstall else { return }
            if let sfIdx = dropped.serviceFiles.firstIndex(where: { $0.id == fileID }) {
                dropped.serviceFiles[sfIdx].isSelected.toggle()
                droppedApp = dropped
            }
            return
        }
        guard let appIdx = apps.firstIndex(where: { $0.id == appID }),
              apps[appIdx].canUninstall,
              let sfIdx = apps[appIdx].serviceFiles.firstIndex(where: { $0.id == fileID }) else {
            return
        }
        apps[appIdx].serviceFiles[sfIdx].isSelected.toggle()
    }

    func toggleServiceCategory(appID: String, category: ServiceFileCategory, selected: Bool) {
        if var dropped = droppedApp, dropped.id == appID {
            guard dropped.canUninstall else { return }
            for i in dropped.serviceFiles.indices where dropped.serviceFiles[i].category == category {
                dropped.serviceFiles[i].isSelected = selected
            }
            droppedApp = dropped
            return
        }
        guard let appIdx = apps.firstIndex(where: { $0.id == appID }), apps[appIdx].canUninstall else { return }
        for i in apps[appIdx].serviceFiles.indices where apps[appIdx].serviceFiles[i].category == category {
            apps[appIdx].serviceFiles[i].isSelected = selected
        }
    }

    func toggleProtection(for app: AppItem) {
        let lowerID = app.bundleID.lowercased()
        if preferences.protectedBundleIDs.contains(where: { $0.lowercased() == lowerID }) {
            preferences.protectedBundleIDs.removeAll { $0.lowercased() == lowerID }
        } else {
            preferences.protectedBundleIDs.append(app.bundleID)
        }
        savePreferences()
    }

    @discardableResult
    func addProtectedPath(_ rawPath: String) -> ProtectedPathAddResult {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return .invalid }

        let expanded: String
        if isDemoMode {
            if trimmed == "~" {
                expanded = DemoFixtureCatalog.homeDirectoryPath
            } else if trimmed.hasPrefix("~/") {
                expanded = DemoFixtureCatalog.homeDirectoryPath + String(trimmed.dropFirst(1))
            } else {
                expanded = trimmed
            }
        } else {
            expanded = (trimmed as NSString).expandingTildeInPath
        }
        guard expanded.hasPrefix("/"), !expanded.contains("\0") else { return .invalid }

        let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard normalized != "/" else { return .invalid }
        let key = Self.normalizedPathKey(normalized)
        if preferences.protectedPaths.contains(where: { Self.normalizedPathKey($0) == key }) {
            return .duplicate
        }

        preferences.protectedPaths.append(normalized)
        if !savePreferences() {
            return .saveFailed
        }
        return .added(normalized)
    }

    @discardableResult
    func addProtectedPaths(urls: [URL]) -> Bool {
        var changed = false
        for url in urls where url.isFileURL {
            let normalized = url.standardizedFileURL.path
            guard !normalized.isEmpty, normalized != "/", !normalized.contains("\0") else { continue }
            let key = Self.normalizedPathKey(normalized)
            if !preferences.protectedPaths.contains(where: { Self.normalizedPathKey($0) == key }) {
                preferences.protectedPaths.append(normalized)
                changed = true
            }
        }
        if changed {
            return savePreferences()
        }
        return true
    }

    @discardableResult
    func removeProtectedPath(_ path: String) -> Bool {
        let key = Self.normalizedPathKey(path)
        preferences.protectedPaths.removeAll { Self.normalizedPathKey($0) == key }
        return savePreferences()
    }

    private func isURLProtectedByGuardOrDemo(_ url: URL) -> Bool {
        if !safetyGuard.validateForRemoval(url).isAllowed {
            return true
        }
        if isDemoMode, let bid = fileManagerStore.demoBundleID(for: url),
           safetyGuard.matchesProtectedBundleID(bid) {
            return true
        }
        return false
    }

    private func refreshAppProtectionFlags() {
        let guardCopy = safetyGuard
        for i in apps.indices {
            let isProt = guardCopy.isUserProtected(bundleID: apps[i].bundleID, url: apps[i].url)
            apps[i].isProtected = isProt
            if isProt { apps[i].isChecked = false }
        }
        if var dropped = droppedApp {
            dropped.isProtected = guardCopy.isUserProtected(bundleID: dropped.bundleID, url: dropped.url)
            droppedApp = dropped
        }
        for gIdx in leftoverGroups.indices {
            for fIdx in leftoverGroups[gIdx].files.indices {
                if isURLProtectedByGuardOrDemo(leftoverGroups[gIdx].files[fIdx].url) {
                    leftoverGroups[gIdx].files[fIdx].isSelected = false
                }
            }
            leftoverGroups[gIdx].isChecked = leftoverGroups[gIdx].files.contains(where: \.isSelected)
        }
    }

    func quitApp(_ app: AppItem) async {
        if isDemoMode {
            demoRunningBundleIDs.remove(app.bundleID.lowercased())
            if let idx = apps.firstIndex(where: { $0.id == app.id }) {
                apps[idx].isRunning = false
            }
            if var dropped = droppedApp, dropped.id == app.id {
                dropped.isRunning = false
                droppedApp = dropped
            }
            banner = OperationBanner(
                isError: false,
                message: l10n.t("演示模式：已退出 \(app.localizedName)", "Demo mode: Quit \(app.localizedName)"),
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }
        let safeIDs = AppScanner.safeProcessMatchBundleID(for: app).map { [$0] } ?? []
        _ = await RemovalEngine.terminateRunningApps(
            bundleIDs: safeIDs,
            bundleURLs: [app.url],
            forceAfterTimeout: false
        )
        let stillRunning = !AppScanner.runningProcesses(
            matchingBundleIDs: safeIDs,
            bundleURLs: [app.url]
        ).isEmpty
        if let idx = apps.firstIndex(where: { $0.id == app.id }) {
            apps[idx].isRunning = stillRunning
        }
        if var dropped = droppedApp, dropped.id == app.id {
            dropped.isRunning = stillRunning
            droppedApp = dropped
        }
    }

    // MARK: - Removal Preparation & Execution

    func prepareRemovalForCurrentApps() {
        var targets: [RemovalTarget] = []
        var seenPaths = Set<String>()
        var pkgIDs: [String] = []
        var targetBundleIDs: [String] = []
        var targetAppURLs: [URL] = []
        var hasAppleStore = false
        var affectedIDs: [String] = []

        func appendTarget(_ target: RemovalTarget) {
            let key = target.url.standardizedFileURL.path
            if seenPaths.insert(key).inserted {
                targets.append(target)
            }
        }

        // Batch mode only when 2+ apps are checked (or 1 checked app with no distinct single detail).
        let batch = checkedApps
        if batch.count >= 2 && droppedApp == nil {
            for app in batch {
                affectedIDs.append(app.id)
                if let safeID = AppScanner.safeProcessMatchBundleID(for: app) {
                    targetBundleIDs.append(safeID)
                }
                targetAppURLs.append(app.url)
                if app.isAppleAppStoreApp { hasAppleStore = true }
                appendTarget(RemovalTarget(
                    url: app.url,
                    estimatedSize: app.bundleSize ?? 0,
                    requiresAdmin: app.requiresAdmin,
                    expectedCanonicalParent: app.expectedCanonicalParent
                ))
                for sf in app.serviceFiles where sf.isSelected {
                    appendTarget(RemovalTarget(
                        url: sf.url,
                        estimatedSize: sf.size ?? 0,
                        requiresAdmin: sf.requiresAdmin,
                        expectedCanonicalParent: sf.expectedCanonicalParent
                    ))
                }
                pkgIDs.append(contentsOf: app.matchedPackageIDs)
            }
            guard !targets.isEmpty else { return }
            let guardCopy = safetyGuard
            let hasLocked = isDemoMode ? false : targets.contains { guardCopy.isUserImmutable($0.url) }
            let runningIDs: [String]
            let runningNames: [String]
            if isDemoMode {
                let runningBatch = batch.filter { $0.isRunning || demoRunningBundleIDs.contains($0.bundleID.lowercased()) }
                runningIDs = Array(Set(runningBatch.map(\.bundleID)))
                runningNames = Array(Set(runningBatch.map(\.localizedName)))
            } else {
                let running = AppScanner.runningProcesses(matchingBundleIDs: targetBundleIDs, bundleURLs: targetAppURLs)
                runningIDs = Array(Set(running.map(\.bundleID).filter { !$0.isEmpty }))
                runningNames = Array(Set(running.map(\.name)))
            }
            let title = l10n.isChinese
                ? "批量卸载 \(batch.count) 个应用"
                : (batch.count == 1 ? "Uninstall 1 app" : "Uninstall \(batch.count) apps")
            pendingConfirmation = PendingConfirmation(
                title: title,
                isReset: false,
                targets: targets,
                packageIDsToForget: Array(Set(pkgIDs)),
                runningAppBundleIDs: runningIDs,
                runningAppNames: runningNames,
                targetAppBundleIDs: targetBundleIDs,
                targetAppURLs: targetAppURLs,
                browserBundleIDsToRequireClosed: [],
                hasAppleAppStoreApp: hasAppleStore,
                hasChromiumExtension: false,
                sourceTab: .applications,
                affectedAppIDs: affectedIDs,
                affectedStartupIDs: [],
                affectedExtensionIDs: [],
                affectedLeftoverIDs: [],
                hasUserLockedItems: hasLocked
            )
            return
        }

        guard let app = activeDetailApp, app.canUninstall else { return }
        let isReset = (appActionMode == .reset)
        affectedIDs = [app.id]
        targetBundleIDs = AppScanner.safeProcessMatchBundleID(for: app).map { [$0] } ?? []
        targetAppURLs = [app.url]
        if app.isAppleAppStoreApp && !isReset { hasAppleStore = true }

        if !isReset && includeAppBundleInRemoval {
            appendTarget(RemovalTarget(
                url: app.url,
                estimatedSize: app.bundleSize ?? 0,
                requiresAdmin: app.requiresAdmin,
                expectedCanonicalParent: app.expectedCanonicalParent
            ))
            pkgIDs = app.matchedPackageIDs
        }

        for sf in app.serviceFiles where sf.isSelected {
            appendTarget(RemovalTarget(
                url: sf.url,
                estimatedSize: sf.size ?? 0,
                requiresAdmin: sf.requiresAdmin,
                expectedCanonicalParent: sf.expectedCanonicalParent
            ))
        }

        guard !targets.isEmpty else { return }
        let guardCopy = safetyGuard
        let hasLocked = isDemoMode ? false : targets.contains { guardCopy.isUserImmutable($0.url) }
        let runningIDs: [String]
        let runningNames: [String]
        if isDemoMode {
            let isAppRunning = app.isRunning || demoRunningBundleIDs.contains(app.bundleID.lowercased())
            runningIDs = isAppRunning ? [app.bundleID] : []
            runningNames = isAppRunning ? [app.localizedName] : []
        } else {
            let running = AppScanner.runningProcesses(matchingBundleIDs: targetBundleIDs, bundleURLs: targetAppURLs)
            runningIDs = Array(Set(running.map(\.bundleID).filter { !$0.isEmpty }))
            runningNames = Array(Set(running.map(\.name)))
        }
        let title = isReset
            ? (l10n.isChinese ? "重置 \(app.localizedName)" : "Reset \(app.localizedName)")
            : (l10n.isChinese ? "卸载 \(app.localizedName)" : "Uninstall \(app.localizedName)")

        pendingConfirmation = PendingConfirmation(
            title: title,
            isReset: isReset,
            targets: targets,
            packageIDsToForget: pkgIDs,
            runningAppBundleIDs: runningIDs,
            runningAppNames: runningNames,
            targetAppBundleIDs: targetBundleIDs,
            targetAppURLs: targetAppURLs,
            browserBundleIDsToRequireClosed: [],
            hasAppleAppStoreApp: hasAppleStore,
            hasChromiumExtension: false,
            sourceTab: .applications,
            affectedAppIDs: affectedIDs,
            affectedStartupIDs: [],
            affectedExtensionIDs: [],
            affectedLeftoverIDs: [],
            resetBundleIDs: isReset ? [app.bundleID] : [],
            resetAllowApple: isReset && app.isAppleAppStoreApp,
            hasUserLockedItems: hasLocked
        )
    }

    public func executePendingConfirmation(mode: RemovalMode) async {
        guard let conf = pendingConfirmation else { return }
        pendingConfirmation = nil
        isPerformingRemoval = true

        let trashDir = URL(fileURLWithPath: safetyGuard.homeDirectoryPath).appendingPathComponent(".Trash")

        if isDemoMode {
            let allowedTargets = conf.targets.filter { !isURLProtectedByGuardOrDemo($0.url) }
            guard !allowedTargets.isEmpty else {
                isPerformingRemoval = false
                banner = OperationBanner(
                    isError: true,
                    message: l10n.fileOperationBlockedTitle,
                    showAppManagementLink: false,
                    showFDALink: false
                )
                return
            }
            let trashTargets = allowedTargets.filter { RemovalEngine.isInsideDirectory($0.url, directory: trashDir) }
            let nonTrashTargets = allowedTargets.filter { !RemovalEngine.isInsideDirectory($0.url, directory: trashDir) }
            let removedPaths = allowedTargets.map { $0.url.standardizedFileURL.path }
            let freedBytes = allowedTargets.reduce(Int64(0)) { $0 + max(0, $1.estimatedSize) }

            if mode == .trash && !trashTargets.isEmpty && !nonTrashTargets.isEmpty {
                let nonTrashPaths = nonTrashTargets.map { $0.url.standardizedFileURL.path }
                let nonTrashBytes = nonTrashTargets.reduce(Int64(0)) { $0 + max(0, $1.estimatedSize) }
                let trashPaths = trashTargets.map { $0.url.standardizedFileURL.path }
                let trashBytes = trashTargets.reduce(Int64(0)) { $0 + max(0, $1.estimatedSize) }
                let trashTitle = l10n.isChinese ? "\(conf.title)（清空废纸篓）" : "\(conf.title) (Empty Trash)"
                cleanupHistory.insert(CleanupRecord(
                    actionTitle: trashTitle,
                    mode: .permanent,
                    itemCount: trashPaths.count,
                    freedBytes: trashBytes,
                    removedPaths: trashPaths
                ), at: 0)
                cleanupHistory.insert(CleanupRecord(
                    actionTitle: conf.title,
                    mode: .trash,
                    itemCount: nonTrashPaths.count,
                    freedBytes: nonTrashBytes,
                    removedPaths: nonTrashPaths
                ), at: 0)
            } else {
                let effectiveMode: RemovalMode = (conf.forcePermanentMode || nonTrashTargets.isEmpty) ? .permanent : mode
                let record = CleanupRecord(
                    actionTitle: conf.title,
                    mode: effectiveMode,
                    itemCount: removedPaths.count,
                    freedBytes: freedBytes,
                    removedPaths: removedPaths
                )
                cleanupHistory.insert(record, at: 0)
            }
            if cleanupHistory.count > 100 {
                cleanupHistory = Array(cleanupHistory.prefix(100))
            }
            applyIncrementalRemoval(removedPaths: Set(removedPaths), forgottenPackageIDs: conf.packageIDsToForget)
            isPerformingRemoval = false
            let freed = ByteFormatter.format(freedBytes)
            let msg = l10n.isChinese
                ? "演示模式：已移除 \(removedPaths.count) 个项目，释放 \(freed)"
                : "Demo mode: removed \(removedPaths.count) items, freed \(freed)"
            banner = OperationBanner(
                isError: false,
                message: msg,
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }

        // 0. TOCTOU guard for browsers (Chromium & Firefox extensions or browser caches): abort if browser launched while sheet was open.
        if !conf.browserBundleIDsToRequireClosed.isEmpty {
            let liveBrowsers = AppScanner.runningProcesses(
                matchingBundleIDs: conf.browserBundleIDsToRequireClosed,
                bundleURLs: []
            )
            if !liveBrowsers.isEmpty {
                isPerformingRemoval = false
                let names = liveBrowsers.map(\.name).joined(separator: ", ")
                let msg = conf.sourceTab == .junkCleaner
                    ? l10n.t(
                        "检测到浏览器（\(names)）正在运行，已中止清理浏览器缓存，请先退出浏览器后再试。",
                        "Browser (\(names)) is currently running. Cache cleanup aborted — quit the browser first and retry."
                    )
                    : l10n.t(
                        "检测到浏览器（\(names)）正在运行，已中止移除扩展，请先退出浏览器后再试。",
                        "Browser (\(names)) is currently running. Extension removal aborted — quit the browser first and retry."
                    )
                banner = OperationBanner(
                    isError: true,
                    message: msg,
                    showAppManagementLink: false,
                    showFDALink: false
                )
                return
            }
        }

        // 1. TOCTOU re-check & graceful quit for target apps AND embedded Helpers/MenuBar processes.
        //    Never copy unvetted `liveProcesses.map(\.bundleID)` into `bundleIDs`, so a dropped/spoofed
        //    bundle cannot cause an unrelated app sharing its forged CFBundleIdentifier to be terminated.
        if !conf.targetAppBundleIDs.isEmpty || !conf.targetAppURLs.isEmpty {
            let liveProcesses = AppScanner.runningProcesses(
                matchingBundleIDs: conf.targetAppBundleIDs,
                bundleURLs: conf.targetAppURLs
            )
            if !liveProcesses.isEmpty {
                let stillRunning = await RemovalEngine.terminateRunningApps(
                    bundleIDs: conf.targetAppBundleIDs,
                    bundleURLs: conf.targetAppURLs,
                    forceAfterTimeout: false
                )
                if !stillRunning.isEmpty {
                    isPerformingRemoval = false
                    banner = OperationBanner(
                        isError: true,
                        message: l10n.t(
                            "应用未能正常退出（可能有未保存的文档），已取消操作，未删除任何文件。请先手动退出，或确认后强制退出再重试。",
                            "The app did not quit (it may have unsaved documents). Nothing was removed. Quit it manually, or force quit and retry."
                        ),
                        showAppManagementLink: false,
                        showFDALink: false,
                        forceQuitBundleIDs: conf.targetAppBundleIDs,
                        forceQuitBundleURLs: conf.targetAppURLs
                    )
                    return
                }
            }
        }

        let guardCopy = safetyGuard
        let histStore = historyStore ?? CleanupHistoryStore()

        // 2. Unload launchd services whose plists are about to be removed (F2).
        //    Only pass plists whose canonical parent still matches scan time (TOCTOU guard).
        let verifiedLaunchURLs = conf.targets.compactMap { target -> URL? in
            PrivilegedExecutor.canonicalParentPath(forTargetURL: target.url) == target.expectedCanonicalParent
                ? target.url
                : nil
        }
        let launchTargets = StartupController.launchTargets(for: verifiedLaunchURLs)
        var targetsToRemove = conf.targets
        var stillLoadedPlists = Set<String>()
        var unloadErrorMessage: String?

        if !launchTargets.isEmpty {
            let unload = await Task.detached(priority: .userInitiated) {
                StartupController(privilegedExecutor: PrivilegedExecutor(safetyGuard: guardCopy))
                    .unloadBeforeRemoval(launchTargets)
            }.value
            if unload.cancelledByUser {
                isPerformingRemoval = false
                banner = OperationBanner(
                    isError: false,
                    message: l10n.t("已取消管理员授权，未删除任何文件。", "Administrator authorization cancelled. Nothing was removed."),
                    showAppManagementLink: false,
                    showFDALink: false
                )
                return
            }
            stillLoadedPlists = unload.stillLoadedPlists
            unloadErrorMessage = unload.errorMessage
            targetsToRemove.removeAll { stillLoadedPlists.contains($0.url.standardizedFileURL.path) }
        }

        // F1 + F2 interaction: NEVER forget pkg receipts if any launchd service failed to unload and stayed on disk.
        let safePkgIDs = stillLoadedPlists.isEmpty ? conf.packageIDsToForget : []
        let removalTargets = targetsToRemove
        let trashTitle = l10n.isChinese ? "\(conf.title)（清空废纸篓）" : "\(conf.title) (Empty Trash)"
        let report = await Task.detached(priority: .userInitiated) {
            let engine = RemovalEngine(safetyGuard: guardCopy, historyStore: histStore)
            let trashTargets = removalTargets.filter { RemovalEngine.isInsideDirectory($0.url, directory: trashDir) }
            let nonTrashTargets = removalTargets.filter { !RemovalEngine.isInsideDirectory($0.url, directory: trashDir) }

            if mode == .trash && !trashTargets.isEmpty && !nonTrashTargets.isEmpty {
                let nonTrashReport = engine.remove(
                    targets: nonTrashTargets,
                    mode: .trash,
                    actionTitle: conf.title,
                    packageIDsToForget: []
                )
                if nonTrashReport.cancelledByUser {
                    return nonTrashReport
                }
                let trashReport = engine.remove(
                    targets: trashTargets,
                    mode: .permanent,
                    actionTitle: trashTitle,
                    packageIDsToForget: []
                )
                return RemovalReport(
                    succeededURLs: nonTrashReport.succeededURLs + trashReport.succeededURLs,
                    failures: nonTrashReport.failures + trashReport.failures,
                    warnings: nonTrashReport.warnings + trashReport.warnings,
                    freedBytes: nonTrashReport.freedBytes + trashReport.freedBytes,
                    needsAppManagementPermission: nonTrashReport.needsAppManagementPermission || trashReport.needsAppManagementPermission,
                    usedFinderFallbackToAdmin: nonTrashReport.usedFinderFallbackToAdmin || trashReport.usedFinderFallbackToAdmin,
                    cancelledByUser: nonTrashReport.cancelledByUser || trashReport.cancelledByUser
                )
            }

            let effectiveMode: RemovalMode = (nonTrashTargets.isEmpty && !trashTargets.isEmpty) ? .permanent : mode
            return engine.remove(
                targets: removalTargets,
                mode: effectiveMode,
                actionTitle: conf.title,
                packageIDsToForget: safePkgIDs
            )
        }.value

        isPerformingRemoval = false
        cleanupHistory = histStore.load()

        // Always sync UI for any paths that were actually removed (even if user cancelled partway).
        let removedSet = Set(report.succeededURLs.map { $0.standardizedFileURL.path })
        if !removedSet.isEmpty {
            let forgottenPkgs = (mode == .permanent && report.isFullSuccess) ? safePkgIDs : []
            applyIncrementalRemoval(removedPaths: removedSet, forgottenPackageIDs: forgottenPkgs)
        }

        if report.cancelledByUser {
            banner = OperationBanner(
                isError: false,
                message: removedSet.isEmpty
                    ? l10n.t("已取消管理员授权，未删除任何文件。", "Administrator authorization cancelled. Nothing was removed.")
                    : l10n.t("已取消管理员授权，受保护项未删除。", "Administrator authorization cancelled; protected items were not removed."),
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }

        // 3. Reset: ONLY flush `cfprefsd` for domains whose preference `.plist` was ACTUALLY removed!
        if conf.isReset && !report.succeededURLs.isEmpty {
            let removedPrefDomains = Self.preferenceDomainsRemoved(
                in: report.succeededURLs,
                candidateDomains: conf.resetBundleIDs,
                allowApple: conf.resetAllowApple
            )
            if !removedPrefDomains.isEmpty {
                await Task.detached(priority: .utility) {
                    for domain in removedPrefDomains {
                        _ = ProcessRunner.run(executable: "/usr/bin/defaults", arguments: ["delete", domain])
                    }
                }.value
            }
        }

        // Feedback banner
        let failureCount = report.failures.count + stillLoadedPlists.count
        if failureCount == 0 {
            let freed = ByteFormatter.format(report.freedBytes)
            let warningSuffix = report.warnings.isEmpty ? "" : "（\(report.warnings.joined(separator: "；"))）"
            let msg = l10n.isChinese
                ? "已完成：移除了 \(report.succeededURLs.count) 个项目，释放 \(freed)\(warningSuffix)"
                : "Completed: removed \(report.succeededURLs.count) items, freed \(freed)\(warningSuffix)"
            banner = OperationBanner(
                isError: !report.warnings.isEmpty,
                message: msg,
                showAppManagementLink: false,
                showFDALink: false
            )
        } else {
            let firstErr = report.failures.first?.reason
                ?? unloadErrorMessage
                ?? l10n.t("后台服务仍在运行，已保留其配置文件", "Launch service still loaded; its plist was kept")
            let msg = l10n.isChinese
                ? "部分项目移除失败（成功 \(report.succeededURLs.count) 项，失败 \(failureCount) 项）：\(firstErr)"
                : "Partial failure (\(report.succeededURLs.count) removed, \(failureCount) failed): \(firstErr)"
            banner = OperationBanner(
                isError: true,
                message: msg,
                showAppManagementLink: report.needsAppManagementPermission,
                showFDALink: !hasFullDiskAccess
                    && !report.needsAppManagementPermission
                    && report.failures.contains(where: \.isPermissionDenied)
            )
        }
    }

    /// Returns only candidate bundle IDs (excluding synthetic `unknown.*`, leading `-`, `com.apple.*`
    /// unless `allowApple == true`, and global domains) that had a matching preference `.plist` actually
    /// removed under a `/Preferences/` directory.
    static func preferenceDomainsRemoved(
        in removedURLs: [URL],
        candidateDomains: [String],
        allowApple: Bool = false
    ) -> [String] {
        let forbiddenGlobalDomains: Set<String> = [
            "nsglobaldomain",
            "apple global domain",
            ".globalpreferences",
            "com.apple",
        ]
        let removedPrefFilenames = removedURLs.compactMap { url -> String? in
            let p = url.standardizedFileURL.path
            guard p.contains("/Preferences/"), url.pathExtension.lowercased() == "plist" else { return nil }
            return url.lastPathComponent.lowercased()
        }
        guard !removedPrefFilenames.isEmpty else { return [] }

        return candidateDomains.filter { domain in
            guard !domain.contains("\0"), !domain.contains("\n"), !domain.contains("\r") else { return false }
            let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            guard !lower.isEmpty,
                  !lower.hasPrefix("-"),
                  !lower.contains("\0"),
                  !lower.contains(where: { $0.isWhitespace }),
                  !lower.hasPrefix("unknown."),
                  !forbiddenGlobalDomains.contains(lower),
                  (allowApple || !lower.hasPrefix("com.apple.")),
                  ServiceFileMatcher.isMatchableBundleID(lower, allowApple: allowApple) else { return false }
            return removedPrefFilenames.contains { file in
                file == "\(lower).plist" || file.hasPrefix("\(lower).")
            }
        }
    }

    /// Explicit, user-initiated force quit offered by the banner after a graceful quit timed out.
    func forceQuitApps(bundleIDs: [String], bundleURLs: [URL] = []) async {
        if isDemoMode {
            for bid in bundleIDs {
                demoRunningBundleIDs.remove(bid.lowercased())
            }
            for i in apps.indices where bundleIDs.contains(where: { $0.lowercased() == apps[i].bundleID.lowercased() }) {
                apps[i].isRunning = false
            }
            banner = OperationBanner(
                isError: false,
                message: l10n.t("演示模式：已强制退出。", "Demo mode: Force quit done."),
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }
        let still = await RemovalEngine.terminateRunningApps(
            bundleIDs: bundleIDs,
            bundleURLs: bundleURLs,
            forceAfterTimeout: true,
            timeoutSeconds: 0.5
        )
        for i in apps.indices {
            let safeIDs = AppScanner.safeProcessMatchBundleID(for: apps[i]).map { [$0] } ?? []
            apps[i].isRunning = !AppScanner.runningProcesses(
                matchingBundleIDs: safeIDs,
                bundleURLs: [apps[i].url]
            ).isEmpty
        }
        if var dropped = droppedApp {
            let safeIDs = AppScanner.safeProcessMatchBundleID(for: dropped).map { [$0] } ?? []
            dropped.isRunning = !AppScanner.runningProcesses(
                matchingBundleIDs: safeIDs,
                bundleURLs: [dropped.url]
            ).isEmpty
            droppedApp = dropped
        }
        banner = OperationBanner(
            isError: !still.isEmpty,
            message: still.isEmpty
                ? l10n.t("已强制退出，请重新执行移除。", "Force quit done. Please run the removal again.")
                : l10n.t("仍无法退出：\(still.joined(separator: ", "))", "Still running: \(still.joined(separator: ", "))"),
            showAppManagementLink: false,
            showFDALink: false
        )
    }

    /// Synchronizes ALL caches and ALL four tabs after any removal so deleted entries can never resurrect.
    /// Preserves `systemInventoryBundleIDs` and `systemInventoryPathsByID` (pruning only actually removed paths)
    /// so system/Utilities/CoreServices collision protection remains intact across incremental removals.
    private func applyIncrementalRemoval(removedPaths: Set<String>, forgottenPackageIDs: [String]) {
        guard !removedPaths.isEmpty else { return }
        let removedNorm = Set(removedPaths.map(Self.normalizedPathKey))

        // Prune cached index & packages
        if let idx = libraryIndex {
            libraryIndex = idx.removing(paths: removedPaths)
        }
        if !forgottenPackageIDs.isEmpty, var pkgs = cachedThirdPartyPackages {
            let forgottenSet = Set(forgottenPackageIDs.map { $0.lowercased() })
            pkgs.removeAll { forgottenSet.contains($0.lowercased()) }
            cachedThirdPartyPackages = pkgs
        }

        Task {
            for path in removedPaths {
                await sizer.invalidate(path: path)
            }
        }

        // Preserve system/Utilities/CoreServices inventory while pruning only paths actually removed.
        var updatedSysPaths: [String: Set<String>] = [:]
        var updatedSysIDs = Set<String>()
        for (bid, paths) in systemInventoryPathsByID {
            let remaining = paths.filter { !Self.matchesAnyRemoved($0, removedNormalized: removedNorm) }
            if !remaining.isEmpty {
                updatedSysPaths[bid] = remaining
                updatedSysIDs.insert(bid)
            }
        }
        systemInventoryPathsByID = updatedSysPaths
        systemInventoryBundleIDs = updatedSysIDs
        var updatedSysGroupOwners: [String: Set<String>] = [:]
        for (groupID, paths) in systemInventoryGroupOwners {
            let remaining = paths.filter { !Self.matchesAnyRemoved($0, removedNormalized: removedNorm) }
            if !remaining.isEmpty {
                updatedSysGroupOwners[groupID] = remaining
            }
        }
        systemInventoryGroupOwners = updatedSysGroupOwners

        // 1. Sync Applications tab & dropped app
        if var dropped = droppedApp {
            if Self.matchesAnyRemoved(dropped.url.path, removedNormalized: removedNorm) {
                droppedApp = nil
            } else {
                dropped.serviceFiles.removeAll { Self.matchesAnyRemoved($0.url.path, removedNormalized: removedNorm) }
                droppedApp = dropped
            }
        }
        apps.removeAll { Self.matchesAnyRemoved($0.url.path, removedNormalized: removedNorm) }
        var bundleCounts: [String: Int] = [:]
        for app in apps { bundleCounts[app.bundleID.lowercased(), default: 0] += 1 }
        for i in apps.indices {
            apps[i].serviceFiles.removeAll { Self.matchesAnyRemoved($0.url.path, removedNormalized: removedNorm) }
            let lowerID = apps[i].bundleID.lowercased()
            let appPathNorm = Self.normalizedPathKey(apps[i].url.path)
            let hasOtherSystemCopy = (systemInventoryPathsByID[lowerID] ?? []).contains {
                Self.normalizedPathKey($0) != appPathNorm
            }
            apps[i].sharesBundleIDWithOtherApp = (bundleCounts[lowerID] ?? 0) > 1 || hasOtherSystemCopy
        }
        let scannedIDs = Set(apps.map { $0.bundleID.lowercased() }.filter { !$0.hasPrefix("unknown.") })
        allInstalledBundleIDs = scannedIDs.union(systemInventoryBundleIDs)
        allInstalledAppPaths = Set(apps.map { $0.url.standardizedFileURL.path })
            .union(systemInventoryPathsByID.values.flatMap { $0 })
        allInstalledGroupOwners = Self.mergeGroupOwners(
            ServiceFileMatcher.applicationGroupOwners(across: apps),
            systemInventoryGroupOwners
        )
        if let sel = selectedAppID, !apps.contains(where: { $0.id == sel }) {
            selectedAppID = nil
        }

        // 2. Sync Startup tab (direct plist removal OR parent directory/app removal)
        startupItems.removeAll { item in
            if Self.matchesAnyRemoved(item.plistURL.path, removedNormalized: removedNorm) {
                return true
            }
            if item.scope == .appLoginItem,
               let assoc = item.associatedAppPath,
               Self.matchesAnyRemoved(assoc, removedNormalized: removedNorm) {
                return true
            }
            return false
        }
        if let selStartup = selectedStartupID, !startupItems.contains(where: { $0.id == selStartup }) {
            selectedStartupID = nil
        }

        // 3. Sync Extensions tab (direct removal OR parent directory/host app removal)
        extensionItems.removeAll { item in
            if Self.matchesAnyRemoved(item.path.path, removedNormalized: removedNorm) {
                return true
            }
            if let host = item.hostAppPath?.path,
               Self.matchesAnyRemoved(host, removedNormalized: removedNorm) {
                return true
            }
            return false
        }
        if let selExt = selectedExtensionID, !extensionItems.contains(where: { $0.id == selExt }) {
            selectedExtensionID = nil
        }

        // 4. Sync Leftovers tab
        for i in leftoverGroups.indices {
            leftoverGroups[i].files.removeAll { Self.matchesAnyRemoved($0.url.path, removedNormalized: removedNorm) }
            leftoverGroups[i].isChecked = leftoverGroups[i].files.contains(where: \.isSelected)
        }
        leftoverGroups.removeAll { $0.files.isEmpty }
        if let selLeftover = selectedLeftoverGroupID, !leftoverGroups.contains(where: { $0.id == selLeftover }) {
            selectedLeftoverGroupID = nil
        }

        // 5. Sync File Manager tab
        fileManagerStore.applyIncrementalRemoval(removedPaths: removedNorm)

        // 6. Sync Junk Cleaner & Resource Release tabs
        cleanupCenterStore.applyIncrementalRemoval(removedPaths: removedNorm)
    }

    // MARK: - Startup Programs

    func loadStartupIfNeeded() async {
        if isDemoMode { return }
        if startupItems.isEmpty && !isScanningStartup {
            await scanStartupItems()
        }
    }

    func scanStartupItems() async {
        if isDemoMode {
            if let catalog = demoCatalog {
                startupItems = catalog.startupItems
                selectedStartupID = catalog.defaultSelectedStartupID
            }
            isScanningStartup = false
            return
        }
        isScanningStartup = true
        let guardCopy = safetyGuard
        let found = await Task.detached(priority: .userInitiated) {
            StartupScanner(safetyGuard: guardCopy).scanAll()
        }.value
        startupItems = found
        isScanningStartup = false
    }

    func toggleStartupItem(_ item: StartupItem, enable: Bool) async {
        guard !togglingStartupIDs.contains(item.id) else { return }
        togglingStartupIDs.insert(item.id)
        defer { togglingStartupIDs.remove(item.id) }

        if isDemoMode {
            if let idx = startupItems.firstIndex(where: { $0.id == item.id }) {
                startupItems[idx].isEnabled = enable
            }
            banner = OperationBanner(
                isError: false,
                message: enable
                    ? l10n.t("演示模式：已启用启动项 \(item.label)", "Demo mode: Enabled startup item \(item.label)")
                    : l10n.t("演示模式：已禁用启动项 \(item.label)", "Demo mode: Disabled startup item \(item.label)"),
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }

        let guardCopy = safetyGuard
        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let ctrl = StartupController(privilegedExecutor: PrivilegedExecutor(safetyGuard: guardCopy))
                try ctrl.setEnabled(enable, for: item)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success:
            if let idx = startupItems.firstIndex(where: { $0.id == item.id }) {
                startupItems[idx].isEnabled = enable
            }
            banner = OperationBanner(
                isError: false,
                message: enable
                    ? l10n.t("已启用启动项：\(item.label)", "Enabled startup item: \(item.label)")
                    : l10n.t("已禁用启动项：\(item.label)", "Disabled startup item: \(item.label)"),
                showAppManagementLink: false,
                showFDALink: false
            )
        case let .failure(err):
            banner = OperationBanner(
                isError: true,
                message: err.localizedDescription,
                showAppManagementLink: false,
                showFDALink: false
            )
        }
    }

    public func prepareRemovalForStartupItem(_ item: StartupItem) {
        guard item.canRemove, !isPerformingRemoval else { return }
        let isProtected = isURLProtectedByGuardOrDemo(item.plistURL)
            || safetyGuard.matchesProtectedBundleID(item.label)
            || (item.associatedAppPath.map { isURLProtectedByGuardOrDemo(URL(fileURLWithPath: $0)) } ?? false)
        if isProtected {
            banner = OperationBanner(
                isError: true,
                message: l10n.fileOperationBlockedTitle,
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }
        let target = RemovalTarget(
            url: item.plistURL,
            estimatedSize: item.fileSize,
            requiresAdmin: item.requiresAdmin,
            expectedCanonicalParent: item.expectedCanonicalParent
        )
        pendingConfirmation = PendingConfirmation(
            title: l10n.isChinese ? "移除启动项 \(item.label)" : "Remove startup item \(item.label)",
            isReset: false,
            targets: [target],
            packageIDsToForget: [],
            runningAppBundleIDs: [],
            runningAppNames: [],
            targetAppBundleIDs: [],
            targetAppURLs: [],
            browserBundleIDsToRequireClosed: [],
            hasAppleAppStoreApp: false,
            hasChromiumExtension: false,
            sourceTab: .startup,
            affectedAppIDs: [],
            affectedStartupIDs: [item.id],
            affectedExtensionIDs: [],
            affectedLeftoverIDs: [],
            hasUserLockedItems: isDemoMode ? false : safetyGuard.isUserImmutable(item.plistURL)
        )
    }

    // MARK: - Leftovers

    func loadLeftoversIfNeeded() async {
        if isDemoMode { return }
        if leftoverGroups.isEmpty && !isScanningLeftovers {
            await scanLeftovers()
        }
    }

    /// Always rebuilds a fresh `LibraryIndex` from disk so manual refresh accurately reflects recent removals/changes.
    func scanLeftovers() async {
        if isDemoMode {
            if let catalog = demoCatalog {
                let ignoredLower = Set(preferences.ignoredLeftoverIDs.map { $0.lowercased() })
                leftoverGroups = catalog.leftoverGroups.filter { !ignoredLower.contains($0.id.lowercased()) }
                selectedLeftoverGroupID = leftoverGroups.first?.id
            }
            isScanningLeftovers = false
            return
        }
        isScanningLeftovers = true
        let guardCopy = safetyGuard
        let ignored = preferences.ignoredLeftoverIDs
        let sizerRef = sizer

        let (groups, freshIndex) = await Task.detached(priority: .userInitiated) {
            let idx = LibraryIndex.build(safetyGuard: guardCopy)
            let inventory = InstalledAppInventory.build(libraryIndex: idx)
            let scanner = LeftoverScanner(safetyGuard: guardCopy, ignoredLeftoverIDs: ignored)
            var found = scanner.scan(index: idx, inventory: inventory)

            let allURLs = found.flatMap { $0.files.map(\.url) }
            let sizeMap = await sizerRef.sizes(of: allURLs, maxConcurrency: 6)
            for gIdx in found.indices {
                for fIdx in found[gIdx].files.indices {
                    let key = found[gIdx].files[fIdx].url.standardizedFileURL.path
                    found[gIdx].files[fIdx].size = sizeMap[key] ?? 0
                }
            }
            found.sort { lhs, rhs in
                if lhs.confidence != rhs.confidence {
                    return lhs.confidence < rhs.confidence
                }
                if lhs.totalSize != rhs.totalSize {
                    return lhs.totalSize > rhs.totalSize
                }
                return lhs.groupName.localizedCaseInsensitiveCompare(rhs.groupName) == .orderedAscending
            }
            return (found, idx)
        }.value

        libraryIndex = freshIndex
        leftoverGroups = groups
        isScanningLeftovers = false
    }

    func toggleLeftoverGroupChecked(_ groupID: String) {
        guard let idx = leftoverGroups.firstIndex(where: { $0.id == groupID }) else { return }
        let targetState = !leftoverGroups[idx].isChecked
        leftoverGroups[idx].applyGroupToggle(targetState)
    }

    func toggleLeftoverFile(groupID: String, fileID: String) {
        guard let gIdx = leftoverGroups.firstIndex(where: { $0.id == groupID }),
              let fIdx = leftoverGroups[gIdx].files.firstIndex(where: { $0.id == fileID }) else {
            return
        }
        leftoverGroups[gIdx].files[fIdx].isSelected.toggle()
        leftoverGroups[gIdx].isChecked = leftoverGroups[gIdx].files.contains(where: \.isSelected)
    }

    /// Selects ONLY per-file high-confidence, user-scope entries (never selects `/Library` system-scope files [F5]).
    func selectHighConfidenceLeftoversOnly() {
        for idx in leftoverGroups.indices {
            leftoverGroups[idx].selectHighConfidenceOnly()
        }
    }

    func ignoreLeftoverGroup(_ group: LeftoverGroup) {
        if !preferences.ignoredLeftoverIDs.contains(where: { $0.lowercased() == group.id.lowercased() }) {
            preferences.ignoredLeftoverIDs.append(group.id)
            savePreferences()
        }
        leftoverGroups.removeAll { $0.id == group.id }
    }

    public func prepareRemovalForCheckedLeftovers() {
        var targets: [RemovalTarget] = []
        var seen = Set<String>()
        var groupIDs: [String] = []
        var hadSelectedFiles = false
        for group in leftoverGroups where group.isChecked {
            let selected = group.files.filter(\.isSelected)
            guard !selected.isEmpty else { continue }
            hadSelectedFiles = true
            var addedForGroup = false
            for file in selected {
                guard !isURLProtectedByGuardOrDemo(file.url) else { continue }
                let key = file.url.standardizedFileURL.path
                if seen.insert(key).inserted {
                    addedForGroup = true
                    targets.append(RemovalTarget(
                        url: file.url,
                        estimatedSize: file.size ?? 0,
                        requiresAdmin: file.requiresAdmin,
                        expectedCanonicalParent: file.expectedCanonicalParent
                    ))
                }
            }
            if addedForGroup {
                groupIDs.append(group.id)
            }
        }
        guard !targets.isEmpty else {
            if hadSelectedFiles {
                banner = OperationBanner(
                    isError: true,
                    message: l10n.fileOperationBlockedTitle,
                    showAppManagementLink: false,
                    showFDALink: false
                )
            }
            return
        }
        let guardCopy = safetyGuard
        let hasLocked = isDemoMode ? false : targets.contains { guardCopy.isUserImmutable($0.url) }
        pendingConfirmation = PendingConfirmation(
            title: l10n.isChinese
                ? "清理 \(groupIDs.count) 组残留文件"
                : (groupIDs.count == 1 ? "Clean 1 leftover group" : "Clean \(groupIDs.count) leftover groups"),
            isReset: false,
            targets: targets,
            packageIDsToForget: [],
            runningAppBundleIDs: [],
            runningAppNames: [],
            targetAppBundleIDs: [],
            targetAppURLs: [],
            browserBundleIDsToRequireClosed: [],
            hasAppleAppStoreApp: false,
            hasChromiumExtension: false,
            sourceTab: .leftovers,
            affectedAppIDs: [],
            affectedStartupIDs: [],
            affectedExtensionIDs: [],
            affectedLeftoverIDs: groupIDs,
            hasUserLockedItems: hasLocked
        )
    }

    // MARK: - Extensions

    func loadExtensionsIfNeeded() async {
        if isDemoMode { return }
        if extensionItems.isEmpty && !isScanningExtensions {
            await scanExtensions()
        }
    }

    func scanExtensions() async {
        if isDemoMode {
            if let catalog = demoCatalog {
                extensionItems = catalog.extensionItems
                extensionsNeedFDAForBrowsers = catalog.extensionScanResult.needsFullDiskAccessForBrowsers
                blockedBrowserNames = catalog.extensionScanResult.blockedBrowserNames
                selectedExtensionID = catalog.defaultSelectedExtensionID
            }
            isScanningExtensions = false
            return
        }
        isScanningExtensions = true
        let guardCopy = safetyGuard
        let sizerRef = sizer
        let result = await Task.detached(priority: .userInitiated) {
            await ExtensionScanner(safetyGuard: guardCopy).scanAllAsync(sizer: sizerRef)
        }.value
        extensionItems = result.items
        extensionsNeedFDAForBrowsers = result.needsFullDiskAccessForBrowsers
        blockedBrowserNames = result.blockedBrowserNames
        isScanningExtensions = false
    }

    func toggleExtensionItem(_ item: ExtensionItem, enable: Bool) async {
        guard item.canToggle, !togglingExtensionIDs.contains(item.id) else { return }
        togglingExtensionIDs.insert(item.id)
        defer { togglingExtensionIDs.remove(item.id) }

        if isDemoMode {
            if let idx = extensionItems.firstIndex(where: { $0.id == item.id }) {
                extensionItems[idx].isEnabled = enable
            }
            banner = OperationBanner(
                isError: false,
                message: enable
                    ? l10n.t("演示模式：已启用扩展 \(item.name)", "Demo mode: Enabled extension \(item.name)")
                    : l10n.t("演示模式：已禁用扩展 \(item.name)", "Demo mode: Disabled extension \(item.name)"),
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }

        let res: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                try ExtensionController.setPluginEnabled(enable, identifier: item.identifier)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        switch res {
        case .success:
            if let idx = extensionItems.firstIndex(where: { $0.id == item.id }) {
                extensionItems[idx].isEnabled = enable
            }
            banner = OperationBanner(
                isError: false,
                message: enable
                    ? l10n.t("已启用扩展：\(item.name)", "Enabled extension: \(item.name)")
                    : l10n.t("已禁用扩展：\(item.name)", "Disabled extension: \(item.name)"),
                showAppManagementLink: false,
                showFDALink: false
            )
        case let .failure(err):
            banner = OperationBanner(
                isError: true,
                message: err.localizedDescription,
                showAppManagementLink: false,
                showFDALink: false
            )
        }
    }

    func isBrowserRunning(for item: ExtensionItem) -> Bool {
        guard let bid = item.browserBundleID?.lowercased() else { return false }
        if isDemoMode {
            return demoRunningBundleIDs.contains(bid)
        }
        return AppScanner.runningBundleIDs().contains(bid)
    }

    func quitBrowser(for item: ExtensionItem) async {
        guard let bid = item.browserBundleID else { return }
        if isDemoMode {
            demoRunningBundleIDs.remove(bid.lowercased())
            objectWillChange.send()
            return
        }
        let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
        _ = await RemovalEngine.terminateRunningApps(
            bundleIDs: [bid],
            bundleURLs: browserURL.map { [$0] } ?? [],
            allowBundleIDOnlyWithoutAppURL: browserURL == nil,
            forceAfterTimeout: false
        )
        objectWillChange.send()
    }

    public func prepareRemovalForExtension(_ item: ExtensionItem) {
        guard item.canRemove, !isPerformingRemoval else { return }
        let isProtected = isURLProtectedByGuardOrDemo(item.path)
            || safetyGuard.matchesProtectedBundleID(item.identifier)
            || (item.hostAppPath.map { isURLProtectedByGuardOrDemo($0) } ?? false)
        if isProtected {
            banner = OperationBanner(
                isError: true,
                message: l10n.fileOperationBlockedTitle,
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }
        // Require browser quit for ALL removable browser extensions (Chromium AND Firefox).
        let requiredClosedBrowser: [String] = (item.category.isBrowser && item.browserBundleID != nil)
            ? [item.browserBundleID!]
            : []
        if !requiredClosedBrowser.isEmpty && isBrowserRunning(for: item) {
            banner = OperationBanner(
                isError: true,
                message: l10n.t("请先退出对应浏览器后再移除该扩展。", "Please quit the browser before removing this extension."),
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }
        let target = RemovalTarget(
            url: item.path,
            estimatedSize: item.size,
            requiresAdmin: item.requiresAdmin,
            expectedCanonicalParent: item.expectedCanonicalParent
        )
        pendingConfirmation = PendingConfirmation(
            title: l10n.isChinese ? "移除扩展 \(item.name)" : "Remove extension \(item.name)",
            isReset: false,
            targets: [target],
            packageIDsToForget: [],
            runningAppBundleIDs: [],
            runningAppNames: [],
            targetAppBundleIDs: [],
            targetAppURLs: [],
            browserBundleIDsToRequireClosed: requiredClosedBrowser,
            hasAppleAppStoreApp: false,
            hasChromiumExtension: item.category.isChromium,
            sourceTab: .extensions,
            affectedAppIDs: [],
            affectedStartupIDs: [],
            affectedExtensionIDs: [item.id],
            affectedLeftoverIDs: [],
            hasUserLockedItems: isDemoMode ? false : safetyGuard.isUserImmutable(item.path)
        )
    }

    // MARK: - File Manager Removal Preparation

    public func prepareRemovalForFileManagerItems(
        _ items: [(url: URL, size: Int64, requiresAdmin: Bool, expectedCanonicalParent: String)],
        title: String,
        preferredRemovalModeOverride: RemovalMode? = nil
    ) {
        guard !isPerformingRemoval else { return }
        let guardCopy = safetyGuard
        let trashDir = URL(fileURLWithPath: guardCopy.homeDirectoryPath).appendingPathComponent(".Trash")

        var targets: [RemovalTarget] = []
        var seen = Set<String>()
        var targetAppURLs: [URL] = []
        var trashTargetCount = 0

        for item in items {
            let stdURL = item.url.standardizedFileURL
            let isProtectedDemoApp: Bool
            if isDemoMode, let bundleID = fileManagerStore.demoBundleID(for: stdURL) {
                isProtectedDemoApp = guardCopy.matchesProtectedBundleID(bundleID)
            } else {
                isProtectedDemoApp = false
            }
            guard !isProtectedDemoApp, guardCopy.validateForRemoval(stdURL).isAllowed else { continue }
            guard seen.insert(stdURL.path).inserted else { continue }
            if RemovalEngine.isInsideDirectory(stdURL, directory: trashDir) {
                trashTargetCount += 1
            }
            if stdURL.pathExtension.lowercased() == "app" {
                targetAppURLs.append(stdURL)
            }
            targets.append(RemovalTarget(
                url: stdURL,
                estimatedSize: max(0, item.size),
                requiresAdmin: isDemoMode ? item.requiresAdmin : (item.requiresAdmin || guardCopy.requiresAdmin(for: stdURL)),
                expectedCanonicalParent: item.expectedCanonicalParent
            ))
        }

        guard !targets.isEmpty else {
            banner = OperationBanner(
                isError: true,
                message: l10n.fileOperationBlockedTitle,
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }

        let hasTrashItems = trashTargetCount > 0
        let allTargetsInTrash = trashTargetCount == targets.count
        let hasLocked = isDemoMode ? false : targets.contains { guardCopy.isUserImmutable($0.url) }
        let runningIDs: [String]
        let runningNames: [String]
        if isDemoMode {
            var matchedIDs = Set<String>()
            var matchedNames = Set<String>()
            for appURL in targetAppURLs {
                if let bundleID = fileManagerStore.demoBundleID(for: appURL) {
                    let lowerID = bundleID.lowercased()
                    let matchingApp = apps.first { $0.bundleID.lowercased() == lowerID }
                    let isRunning = (matchingApp?.isRunning ?? false) || demoRunningBundleIDs.contains(lowerID)
                    if isRunning {
                        matchedIDs.insert(bundleID)
                        matchedNames.insert(matchingApp?.localizedName ?? appURL.deletingPathExtension().lastPathComponent)
                    }
                }
            }
            runningIDs = Array(matchedIDs)
            runningNames = Array(matchedNames)
        } else {
            let running = targetAppURLs.isEmpty
                ? []
                : AppScanner.runningProcesses(matchingBundleIDs: [], bundleURLs: targetAppURLs)
            runningIDs = Array(Set(running.map(\.bundleID).filter { !$0.isEmpty }))
            runningNames = Array(Set(running.map(\.name)))
        }

        pendingConfirmation = PendingConfirmation(
            title: title,
            isReset: false,
            targets: targets,
            packageIDsToForget: [],
            runningAppBundleIDs: runningIDs,
            runningAppNames: runningNames,
            targetAppBundleIDs: [],
            targetAppURLs: targetAppURLs,
            browserBundleIDsToRequireClosed: [],
            hasAppleAppStoreApp: false,
            hasChromiumExtension: false,
            sourceTab: .fileManager,
            affectedAppIDs: [],
            affectedStartupIDs: [],
            affectedExtensionIDs: [],
            affectedLeftoverIDs: [],
            hasUserLockedItems: hasLocked,
            preferredRemovalModeOverride: allTargetsInTrash ? .permanent : preferredRemovalModeOverride,
            forcePermanentMode: allTargetsInTrash,
            hasTrashItems: hasTrashItems
        )
    }

    // MARK: - Junk Cleaner & Resource Release Removal Preparation

    func prepareRemovalForCleanupItems(
        _ items: [CleanupRemovalInput],
        title: String,
        sourceTab: MainTab,
        browserBundleIDsToRequireClosed: [String] = [],
        preferredRemovalModeOverride: RemovalMode? = nil
    ) {
        guard !isPerformingRemoval else { return }
        let guardCopy = safetyGuard
        let trashDir = URL(fileURLWithPath: guardCopy.homeDirectoryPath).appendingPathComponent(".Trash")

        var targets: [RemovalTarget] = []
        var seen = Set<String>()
        var targetAppURLs: [URL] = []
        var trashTargetCount = 0

        for item in items {
            let stdURL = item.url.standardizedFileURL
            let isProtectedDemoApp: Bool
            if isDemoMode, let bundleID = fileManagerStore.demoBundleID(for: stdURL) {
                isProtectedDemoApp = guardCopy.matchesProtectedBundleID(bundleID)
            } else {
                isProtectedDemoApp = false
            }
            guard !isProtectedDemoApp else { continue }
            if item.requireCacheSubpath {
                guard guardCopy.validateCacheSubpath(stdURL).isAllowed else { continue }
            } else {
                guard guardCopy.validateForRemoval(stdURL).isAllowed else { continue }
            }
            guard seen.insert(stdURL.path).inserted else { continue }
            if RemovalEngine.isInsideDirectory(stdURL, directory: trashDir) {
                trashTargetCount += 1
            }
            if stdURL.pathExtension.lowercased() == "app" {
                targetAppURLs.append(stdURL)
            }
            targets.append(RemovalTarget(
                url: stdURL,
                estimatedSize: max(0, item.size),
                requiresAdmin: isDemoMode ? item.requiresAdmin : (item.requiresAdmin || guardCopy.requiresAdmin(for: stdURL)),
                expectedCanonicalParent: item.expectedCanonicalParent
            ))
        }

        guard !targets.isEmpty else {
            banner = OperationBanner(
                isError: true,
                message: l10n.fileOperationBlockedTitle,
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }

        let hasTrashItems = trashTargetCount > 0
        let allTargetsInTrash = trashTargetCount == targets.count
        let hasLocked = isDemoMode ? false : targets.contains { guardCopy.isUserImmutable($0.url) }
        let runningIDs: [String]
        let runningNames: [String]
        if isDemoMode {
            var matchedIDs = Set<String>()
            var matchedNames = Set<String>()
            for appURL in targetAppURLs {
                if let bundleID = fileManagerStore.demoBundleID(for: appURL) {
                    let lowerID = bundleID.lowercased()
                    let matchingApp = apps.first { $0.bundleID.lowercased() == lowerID }
                    let isRunning = (matchingApp?.isRunning ?? false) || demoRunningBundleIDs.contains(lowerID)
                    if isRunning {
                        matchedIDs.insert(bundleID)
                        matchedNames.insert(matchingApp?.localizedName ?? appURL.deletingPathExtension().lastPathComponent)
                    }
                }
            }
            runningIDs = Array(matchedIDs)
            runningNames = Array(matchedNames)
        } else {
            let running = targetAppURLs.isEmpty
                ? []
                : AppScanner.runningProcesses(matchingBundleIDs: [], bundleURLs: targetAppURLs)
            runningIDs = Array(Set(running.map(\.bundleID).filter { !$0.isEmpty }))
            runningNames = Array(Set(running.map(\.name)))
        }

        pendingConfirmation = PendingConfirmation(
            title: title,
            isReset: false,
            targets: targets,
            packageIDsToForget: [],
            runningAppBundleIDs: runningIDs,
            runningAppNames: runningNames,
            targetAppBundleIDs: [],
            targetAppURLs: targetAppURLs,
            browserBundleIDsToRequireClosed: browserBundleIDsToRequireClosed,
            hasAppleAppStoreApp: false,
            hasChromiumExtension: false,
            sourceTab: sourceTab,
            affectedAppIDs: [],
            affectedStartupIDs: [],
            affectedExtensionIDs: [],
            affectedLeftoverIDs: [],
            hasUserLockedItems: hasLocked,
            preferredRemovalModeOverride: allTargetsInTrash ? .permanent : preferredRemovalModeOverride,
            forcePermanentMode: allTargetsInTrash,
            hasTrashItems: hasTrashItems
        )
    }
}

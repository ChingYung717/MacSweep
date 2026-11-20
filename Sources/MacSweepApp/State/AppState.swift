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

enum MainTab: String, CaseIterable, Identifiable {
    case applications
    case startup
    case extensions
    case leftovers

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .applications: return "app.badge"
        case .startup: return "paperplane.fill"
        case .extensions: return "puzzlepiece.extension.fill"
        case .leftovers: return "doc.text.magnifyingglass"
        }
    }
}

enum AppSortOrder: String, CaseIterable, Identifiable {
    case size
    case name
    case lastUsed
    case modified

    var id: String { rawValue }
}

enum AppActionMode: String, CaseIterable, Identifiable {
    case uninstall
    case reset

    var id: String { rawValue }
}

struct PendingConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let isReset: Bool
    let targets: [RemovalTarget]
    let packageIDsToForget: [String]
    let runningAppBundleIDs: [String]
    let runningAppNames: [String]
    let hasAppleAppStoreApp: Bool
    let hasChromiumExtension: Bool
    let sourceTab: MainTab
    let affectedAppIDs: [String]
    let affectedStartupIDs: [String]
    let affectedExtensionIDs: [String]
    let affectedLeftoverIDs: [String]
    /// Preference domains to flush from cfprefsd after a successful reset.
    var resetBundleIDs: [String] = []
}

struct OperationBanner: Identifiable, Equatable {
    let id = UUID()
    let isError: Bool
    let message: String
    let showAppManagementLink: Bool
    let showFDALink: Bool
    /// Apps that did not quit gracefully; the banner offers an explicit (user-confirmed) Force Quit.
    var forceQuitBundleIDs: [String] = []
}

@MainActor
final class AppState: ObservableObject {
    // Navigation & Sheets
    @Published var activeTab: MainTab = .applications
    @Published var showSettingsSheet: Bool = false
    @Published var pendingConfirmation: PendingConfirmation?
    @Published var banner: OperationBanner?

    // Preferences & Permissions
    @Published var preferences: SweepPreferences
    @Published var cleanupHistory: [CleanupRecord] = []
    @Published var hasFullDiskAccess: Bool = false

    // Shared Core Engines
    private let prefsStore = PreferencesStore()
    private let historyStore = CleanupHistoryStore()
    let sizer = DirectorySizer()
    private var libraryIndex: LibraryIndex?
    private var cachedThirdPartyPackages: [String]?
    private var ambiguousNames: Set<String> = []

    // Tab 1: Applications
    @Published var apps: [AppItem] = []
    @Published var isScanningApps: Bool = false
    @Published var isCalculatingSizes: Bool = false
    @Published var appSearchText: String = ""
    @Published var appSortOrder: AppSortOrder = .size
    @Published var selectedAppID: String?
    @Published var droppedApp: AppItem?
    @Published var appActionMode: AppActionMode = .uninstall
    @Published var includeAppBundleInRemoval: Bool = true
    @Published var isPerformingRemoval: Bool = false

    // Tab 2: Startup (wired in M2)
    @Published var startupItems: [StartupItem] = []
    @Published var isScanningStartup: Bool = false
    @Published var startupSearchText: String = ""

    // Tab 3: Extensions (M4)
    @Published var extensionItems: [ExtensionItem] = []
    @Published var isScanningExtensions: Bool = false
    @Published var extensionsNeedFDAForBrowsers: Bool = false
    @Published var blockedBrowserNames: [String] = []
    @Published var extensionSearchText: String = ""

    // Tab 4: Leftovers (wired in M3)
    @Published var leftoverGroups: [LeftoverGroup] = []
    @Published var isScanningLeftovers: Bool = false
    @Published var leftoverSearchText: String = ""

    private var scanGeneration: Int = 0
    private var sizeTask: Task<Void, Never>?

    var l10n: L10n {
        L10n(language: preferences.language)
    }

    var safetyGuard: SafetyGuard {
        SafetyGuard(
            protectedPaths: preferences.protectedPaths,
            protectedBundleIDs: preferences.protectedBundleIDs
        )
    }

    init() {
        let loaded = prefsStore.load()
        self.preferences = loaded
        self.cleanupHistory = historyStore.load()
        self.hasFullDiskAccess = PermissionChecker.checkFullDiskAccess().hasFullDiskAccess
    }

    // MARK: - Persistence & Permissions

    func savePreferences() {
        prefsStore.save(preferences)
        refreshAppProtectionFlags()
    }

    func refreshPermissionStatus() {
        hasFullDiskAccess = PermissionChecker.checkFullDiskAccess().hasFullDiskAccess
    }

    func openSystemSettings(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clearHistory() {
        historyStore.clear()
        cleanupHistory = []
    }

    // MARK: - Applications Scanning (M1)

    func loadInitialDataIfNeeded() async {
        refreshPermissionStatus()
        if apps.isEmpty && !isScanningApps {
            await scanApplications()
        }
    }

    func scanApplications() async {
        scanGeneration += 1
        let gen = scanGeneration
        sizeTask?.cancel()
        isScanningApps = true
        isCalculatingSizes = true
        droppedApp = nil

        let guardCopy = safetyGuard
        let includeUtil = preferences.includeUtilitiesFolder
        let showSys = preferences.showSystemApps

        let (scannedApps, index, thirdPartyPkgs, ambiguous) = await Task.detached(priority: .userInitiated) {
            let index = LibraryIndex.build(safetyGuard: guardCopy)
            let scanner = AppScanner(
                includeUtilities: includeUtil,
                showSystemApps: showSys,
                safetyGuard: guardCopy
            )
            let matcher = ServiceFileMatcher(safetyGuard: guardCopy)
            var found = scanner.scanApplications()
            // Names claimed by ≥2 installed apps (e.g. shared executables) are never used for name matching.
            let ambiguous = ServiceFileMatcher.ambiguousNameCandidates(across: found)
            // Installed copies sharing one bundle ID share their data: never pre-select it for removal.
            var bundleIDCounts: [String: Int] = [:]
            for app in found { bundleIDCounts[app.bundleID.lowercased(), default: 0] += 1 }
            for i in found.indices {
                var matched = matcher.matchInMemory(app: found[i], index: index, ambiguousNames: ambiguous)
                if (bundleIDCounts[found[i].bundleID.lowercased()] ?? 0) > 1 {
                    found[i].sharesBundleIDWithOtherApp = true
                    for j in matched.indices { matched[j].isSelected = false }
                }
                found[i].serviceFiles = matched
                found[i].scanState = .ready
            }
            let pkgs = ServiceFileMatcher.listThirdPartyPackages()
            return (found, index, pkgs, ambiguous)
        }.value

        guard gen == scanGeneration else { return }
        self.libraryIndex = index
        self.cachedThirdPartyPackages = thirdPartyPkgs
        self.ambiguousNames = ambiguous
        self.apps = scannedApps
        self.isScanningApps = false

        // Keep selection valid if still present
        if let sel = selectedAppID, !apps.contains(where: { $0.id == sel }) {
            selectedAppID = nil
        }

        // Start bounded concurrent size calculation in background
        startBackgroundSizeCalculation(generation: gen)
    }

    private func startBackgroundSizeCalculation(generation: Int) {
        sizeTask?.cancel()
        let currentApps = self.apps
        let sizerRef = self.sizer

        sizeTask = Task.detached(priority: .utility) { [weak self] in
            // Process in small batches so UI updates progressively like App Cleaner 9!
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
                let sizedMap = await sizerRef.sizes(of: urlsToSize, maxConcurrency: 6)
                if Task.isCancelled { return }

                await MainActor.run { [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    for app in slice {
                        guard let idx = self.apps.firstIndex(where: { $0.id == app.id }) else { continue }
                        let bundleKey = self.apps[idx].url.standardizedFileURL.path
                        self.apps[idx].bundleSize = sizedMap[bundleKey] ?? 0
                        for sfIdx in self.apps[idx].serviceFiles.indices {
                            let sfKey = self.apps[idx].serviceFiles[sfIdx].url.standardizedFileURL.path
                            if let sz = sizedMap[sfKey] {
                                self.apps[idx].serviceFiles[sfIdx].size = sz
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

    /// Lazy pkgutil enrichment + fresh size computation when an app is selected.
    func selectApp(id: String?) {
        droppedApp = nil
        selectedAppID = id
        appActionMode = .uninstall
        includeAppBundleInRemoval = true
        guard let id else { return }
        enrichSelectedAppWithPackages(appID: id)
    }

    private func enrichSelectedAppWithPackages(appID: String) {
        guard let idx = apps.firstIndex(where: { $0.id == appID }) else { return }
        let targetApp = apps[idx]
        guard targetApp.matchedPackageIDs.isEmpty,
              let index = libraryIndex,
              let allPkgs = cachedThirdPartyPackages else {
            return
        }
        let guardCopy = safetyGuard
        let sizerRef = sizer
        let ambiguous = ambiguousNames
        let shared = targetApp.sharesBundleIDWithOtherApp

        Task.detached(priority: .userInitiated) { [weak self] in
            let matcher = ServiceFileMatcher(safetyGuard: guardCopy)
            let result = matcher.matchWithPackages(
                app: targetApp,
                index: index,
                allPackageIDs: allPkgs,
                ambiguousNames: ambiguous
            )
            let allURLs = [targetApp.url] + result.files.map(\.url)
            let sizeMap = await sizerRef.sizes(of: allURLs, maxConcurrency: 6)

            var sizedFiles = result.files
            for i in sizedFiles.indices {
                sizedFiles[i].size = sizeMap[sizedFiles[i].url.standardizedFileURL.path] ?? 0
                if shared { sizedFiles[i].isSelected = false }
            }
            let bundleSize = sizeMap[targetApp.url.standardizedFileURL.path] ?? targetApp.bundleSize ?? 0
            // A duplicate copy must not forget the shared installer receipt.
            let pkgIDs = shared ? [] : result.matchedPackageIDs

            let immutableSized = sizedFiles
            await MainActor.run { [weak self] in
                guard let self, let liveIdx = self.apps.firstIndex(where: { $0.id == appID }) else { return }
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
                self.apps[liveIdx].serviceFiles = merged
                self.apps[liveIdx].matchedPackageIDs = pkgIDs
                self.apps[liveIdx].isRunning = AppScanner.runningBundleIDs().contains(
                    self.apps[liveIdx].bundleID.lowercased()
                )
            }
        }
    }

    /// Handles Drag & Drop of any `.app` bundle (even outside `/Applications`) or Dock drop.
    func inspectDroppedApp(at url: URL) {
        guard url.pathExtension.lowercased() == "app" else { return }
        activeTab = .applications

        // If already in scanned list, select it directly!
        let stdPath = url.standardizedFileURL.path
        if let existing = apps.first(where: { $0.url.standardizedFileURL.path == stdPath }) {
            selectApp(id: existing.id)
            return
        }

        let guardCopy = safetyGuard
        let existingIndex = libraryIndex
        let existingPkgs = cachedThirdPartyPackages
        let sizerRef = sizer
        let installedApps = apps

        Task.detached(priority: .userInitiated) { [weak self] in
            let scanner = AppScanner(safetyGuard: guardCopy)
            guard var inspected = scanner.inspectApp(at: url) else { return }
            let index = existingIndex ?? LibraryIndex.build(safetyGuard: guardCopy)
            let pkgs = existingPkgs ?? ServiceFileMatcher.listThirdPartyPackages()
            let ambiguous = ServiceFileMatcher.ambiguousNameCandidates(across: installedApps + [inspected])
            let shared = installedApps.contains {
                $0.bundleID.lowercased() == inspected.bundleID.lowercased()
                    && $0.url.standardizedFileURL.path != inspected.url.standardizedFileURL.path
            }
            let matcher = ServiceFileMatcher(safetyGuard: guardCopy)
            let matched = matcher.matchWithPackages(
                app: inspected,
                index: index,
                allPackageIDs: pkgs,
                ambiguousNames: ambiguous
            )

            let urls = [inspected.url] + matched.files.map(\.url)
            let sizes = await sizerRef.sizes(of: urls, maxConcurrency: 6)

            inspected.bundleSize = sizes[inspected.url.standardizedFileURL.path] ?? 0
            inspected.sharesBundleIDWithOtherApp = shared
            inspected.serviceFiles = matched.files.map { sf in
                var copy = sf
                copy.size = sizes[sf.url.standardizedFileURL.path] ?? 0
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
        guard let selectedAppID else { return nil }
        return apps.first(where: { $0.id == selectedAppID })
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
            if let sfIdx = dropped.serviceFiles.firstIndex(where: { $0.id == fileID }) {
                dropped.serviceFiles[sfIdx].isSelected.toggle()
                droppedApp = dropped
            }
            return
        }
        guard let appIdx = apps.firstIndex(where: { $0.id == appID }),
              let sfIdx = apps[appIdx].serviceFiles.firstIndex(where: { $0.id == fileID }) else {
            return
        }
        apps[appIdx].serviceFiles[sfIdx].isSelected.toggle()
    }

    func toggleServiceCategory(appID: String, category: ServiceFileCategory, selected: Bool) {
        if var dropped = droppedApp, dropped.id == appID {
            for i in dropped.serviceFiles.indices where dropped.serviceFiles[i].category == category {
                dropped.serviceFiles[i].isSelected = selected
            }
            droppedApp = dropped
            return
        }
        guard let appIdx = apps.firstIndex(where: { $0.id == appID }) else { return }
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

    private func refreshAppProtectionFlags() {
        let protectedIDs = Set(preferences.protectedBundleIDs.map { $0.lowercased() })
        for i in apps.indices {
            let isProt = protectedIDs.contains(apps[i].bundleID.lowercased())
            apps[i].isProtected = isProt
            if isProt { apps[i].isChecked = false }
        }
        if var dropped = droppedApp {
            dropped.isProtected = protectedIDs.contains(dropped.bundleID.lowercased())
            droppedApp = dropped
        }
    }

    func quitApp(_ app: AppItem) async {
        _ = await RemovalEngine.terminateRunningApps(bundleIDs: [app.bundleID], forceAfterTimeout: false)
        let running = AppScanner.runningBundleIDs()
        if let idx = apps.firstIndex(where: { $0.id == app.id }) {
            apps[idx].isRunning = running.contains(apps[idx].bundleID.lowercased())
        }
        if var dropped = droppedApp, dropped.id == app.id {
            dropped.isRunning = running.contains(dropped.bundleID.lowercased())
            droppedApp = dropped
        }
    }

    // MARK: - Removal Preparation & Execution

    func prepareRemovalForCurrentApps() {
        let runningNow = AppScanner.runningBundleIDs()
        var targets: [RemovalTarget] = []
        var pkgIDs: [String] = []
        var runningBundleIDs: [String] = []
        var runningNames: [String] = []
        var hasAppleStore = false
        var affectedIDs: [String] = []

        // Batch mode if multiple apps checked; otherwise active single/dropped app.
        let batch = checkedApps
        if !batch.isEmpty && droppedApp == nil {
            for app in batch {
                affectedIDs.append(app.id)
                if app.isAppleAppStoreApp { hasAppleStore = true }
                if runningNow.contains(app.bundleID.lowercased()) {
                    runningBundleIDs.append(app.bundleID)
                    runningNames.append(app.localizedName)
                }
                targets.append(RemovalTarget(
                    url: app.url,
                    estimatedSize: app.bundleSize ?? 0,
                    requiresAdmin: app.requiresAdmin
                ))
                for sf in app.serviceFiles where sf.isSelected {
                    targets.append(RemovalTarget(
                        url: sf.url,
                        estimatedSize: sf.size ?? 0,
                        requiresAdmin: sf.requiresAdmin
                    ))
                }
                pkgIDs.append(contentsOf: app.matchedPackageIDs)
            }
            guard !targets.isEmpty else { return }
            let title = l10n.isChinese ? "批量卸载 \(batch.count) 个应用" : "Uninstall \(batch.count) apps"
            pendingConfirmation = PendingConfirmation(
                title: title,
                isReset: false,
                targets: targets,
                packageIDsToForget: Array(Set(pkgIDs)),
                runningAppBundleIDs: runningBundleIDs,
                runningAppNames: runningNames,
                hasAppleAppStoreApp: hasAppleStore,
                hasChromiumExtension: false,
                sourceTab: .applications,
                affectedAppIDs: affectedIDs,
                affectedStartupIDs: [],
                affectedExtensionIDs: [],
                affectedLeftoverIDs: []
            )
            return
        }

        guard let app = activeDetailApp, app.canUninstall else { return }
        let isReset = (appActionMode == .reset)
        affectedIDs = [app.id]
        if app.isAppleAppStoreApp && !isReset { hasAppleStore = true }
        if runningNow.contains(app.bundleID.lowercased()) {
            runningBundleIDs = [app.bundleID]
            runningNames = [app.localizedName]
        }

        if !isReset && includeAppBundleInRemoval {
            targets.append(RemovalTarget(
                url: app.url,
                estimatedSize: app.bundleSize ?? 0,
                requiresAdmin: app.requiresAdmin
            ))
            pkgIDs = app.matchedPackageIDs
        }

        for sf in app.serviceFiles where sf.isSelected {
            targets.append(RemovalTarget(
                url: sf.url,
                estimatedSize: sf.size ?? 0,
                requiresAdmin: sf.requiresAdmin
            ))
        }

        guard !targets.isEmpty else { return }
        let title = isReset
            ? (l10n.isChinese ? "重置 \(app.localizedName)" : "Reset \(app.localizedName)")
            : (l10n.isChinese ? "卸载 \(app.localizedName)" : "Uninstall \(app.localizedName)")

        pendingConfirmation = PendingConfirmation(
            title: title,
            isReset: isReset,
            targets: targets,
            packageIDsToForget: pkgIDs,
            runningAppBundleIDs: runningBundleIDs,
            runningAppNames: runningNames,
            hasAppleAppStoreApp: hasAppleStore,
            hasChromiumExtension: false,
            sourceTab: .applications,
            affectedAppIDs: affectedIDs,
            affectedStartupIDs: [],
            affectedExtensionIDs: [],
            affectedLeftoverIDs: [],
            resetBundleIDs: isReset ? [app.bundleID] : []
        )
    }

    func executePendingConfirmation(mode: RemovalMode) async {
        guard let conf = pendingConfirmation else { return }
        pendingConfirmation = nil
        isPerformingRemoval = true

        // 1. Quit running apps gracefully first. Never force-quit silently and never delete files of an
        //    app that is still running (it may hold unsaved documents, and cfprefsd could write back).
        if !conf.runningAppBundleIDs.isEmpty {
            let stillRunning = await RemovalEngine.terminateRunningApps(
                bundleIDs: conf.runningAppBundleIDs,
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
                    forceQuitBundleIDs: stillRunning
                )
                return
            }
        }

        let guardCopy = safetyGuard
        let histStore = historyStore

        // 2. Unload launchd services whose plists are about to be removed (F2): bootout first, verify it is
        //    no longer loaded, and only then allow the plist to be deleted.
        let launchTargets = StartupController.launchTargets(for: conf.targets.map(\.url))
        var targetsToRemove = conf.targets
        var stillLoadedPlists = Set<String>()
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
            targetsToRemove.removeAll { stillLoadedPlists.contains($0.url.standardizedFileURL.path) }
        }

        let removalTargets = targetsToRemove
        let report = await Task.detached(priority: .userInitiated) {
            let engine = RemovalEngine(safetyGuard: guardCopy, historyStore: histStore)
            return engine.remove(
                targets: removalTargets,
                mode: mode,
                actionTitle: conf.title,
                packageIDsToForget: conf.packageIDsToForget
            )
        }.value

        // 3. Reset: flush cfprefsd's in-memory cache for the domain so stale values are not written back
        //    or served on next launch. Best-effort and isolated (failure does not affect the removal result).
        if conf.isReset && !report.succeededURLs.isEmpty {
            let domains = conf.resetBundleIDs
            await Task.detached(priority: .utility) {
                for domain in domains {
                    _ = ProcessRunner.run(executable: "/usr/bin/defaults", arguments: ["delete", domain])
                }
            }.value
        }

        isPerformingRemoval = false
        cleanupHistory = historyStore.load()

        if report.cancelledByUser {
            banner = OperationBanner(
                isError: false,
                message: l10n.t("已取消管理员授权，未删除受保护项。", "Administrator authorization cancelled."),
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }

        // Apply incremental UI updates for succeeded paths
        let removedSet = Set(report.succeededURLs.map { $0.standardizedFileURL.path })
        applyIncrementalRemoval(removedPaths: removedSet, confirmation: conf)

        // Show feedback banner
        let failureCount = report.failures.count + stillLoadedPlists.count
        if failureCount == 0 {
            let freed = ByteFormatter.format(report.freedBytes)
            let msg = l10n.isChinese
                ? "已完成：移除了 \(report.succeededURLs.count) 个项目，释放 \(freed)"
                : "Completed: removed \(report.succeededURLs.count) items, freed \(freed)"
            banner = OperationBanner(
                isError: false,
                message: msg,
                showAppManagementLink: false,
                showFDALink: false
            )
        } else {
            let firstErr = report.failures.first?.reason
                ?? l10n.t("后台服务仍在运行，已保留其配置文件", "Launch service still loaded; its plist was kept")
            let msg = l10n.isChinese
                ? "部分项目移除失败（成功 \(report.succeededURLs.count) 项，失败 \(failureCount) 项）：\(firstErr)"
                : "Partial failure (\(report.succeededURLs.count) removed, \(failureCount) failed): \(firstErr)"
            banner = OperationBanner(
                isError: true,
                message: msg,
                showAppManagementLink: report.needsAppManagementPermission,
                showFDALink: false
            )
        }
    }

    /// Explicit, user-initiated force quit offered by the banner after a graceful quit timed out.
    func forceQuitApps(bundleIDs: [String]) async {
        let still = await RemovalEngine.terminateRunningApps(bundleIDs: bundleIDs, forceAfterTimeout: true, timeoutSeconds: 0.5)
        let running = AppScanner.runningBundleIDs()
        for i in apps.indices {
            apps[i].isRunning = running.contains(apps[i].bundleID.lowercased())
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

    private func applyIncrementalRemoval(removedPaths: Set<String>, confirmation: PendingConfirmation) {
        guard !removedPaths.isEmpty else { return }

        // Invalidate sizer cache for removed paths
        Task {
            for path in removedPaths {
                await sizer.invalidate(path: path)
            }
        }

        switch confirmation.sourceTab {
        case .applications:
            if var dropped = droppedApp {
                if removedPaths.contains(dropped.url.standardizedFileURL.path) {
                    droppedApp = nil
                } else {
                    dropped.serviceFiles.removeAll { removedPaths.contains($0.url.standardizedFileURL.path) }
                    droppedApp = dropped
                }
            }
            apps.removeAll { removedPaths.contains($0.url.standardizedFileURL.path) }
            for i in apps.indices {
                apps[i].serviceFiles.removeAll { removedPaths.contains($0.url.standardizedFileURL.path) }
                if removedPaths.contains(apps[i].url.standardizedFileURL.path) {
                    apps[i].isChecked = false
                }
            }
            if let sel = selectedAppID, !apps.contains(where: { $0.id == sel }) {
                selectedAppID = nil
            }
        case .startup:
            startupItems.removeAll { removedPaths.contains($0.plistURL.standardizedFileURL.path) }
        case .extensions:
            extensionItems.removeAll { removedPaths.contains($0.path.standardizedFileURL.path) }
        case .leftovers:
            for i in leftoverGroups.indices {
                leftoverGroups[i].files.removeAll { removedPaths.contains($0.url.standardizedFileURL.path) }
            }
            leftoverGroups.removeAll { $0.files.isEmpty }
        }
    }

    // MARK: - Startup Programs (M2)

    func loadStartupIfNeeded() async {
        if startupItems.isEmpty && !isScanningStartup {
            await scanStartupItems()
        }
    }

    func scanStartupItems() async {
        isScanningStartup = true
        let guardCopy = safetyGuard
        let found = await Task.detached(priority: .userInitiated) {
            StartupScanner(safetyGuard: guardCopy).scanAll()
        }.value
        startupItems = found
        isScanningStartup = false
    }

    func toggleStartupItem(_ item: StartupItem, enable: Bool) async {
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

    func prepareRemovalForStartupItem(_ item: StartupItem) {
        guard item.canRemove else { return }
        pendingConfirmation = PendingConfirmation(
            title: l10n.isChinese ? "移除启动项 \(item.label)" : "Remove startup item \(item.label)",
            isReset: false,
            targets: [RemovalTarget(url: item.plistURL, estimatedSize: item.fileSize, requiresAdmin: item.requiresAdmin)],
            packageIDsToForget: [],
            runningAppBundleIDs: [],
            runningAppNames: [],
            hasAppleAppStoreApp: false,
            hasChromiumExtension: false,
            sourceTab: .startup,
            affectedAppIDs: [],
            affectedStartupIDs: [item.id],
            affectedExtensionIDs: [],
            affectedLeftoverIDs: []
        )
    }

    // MARK: - Leftovers (M3)

    func loadLeftoversIfNeeded() async {
        if leftoverGroups.isEmpty && !isScanningLeftovers {
            await scanLeftovers()
        }
    }

    func scanLeftovers() async {
        isScanningLeftovers = true
        let guardCopy = safetyGuard
        let ignored = preferences.ignoredLeftoverIDs
        let existingIndex = libraryIndex
        let sizerRef = sizer

        let (groups, freshIndex) = await Task.detached(priority: .userInitiated) {
            let idx = existingIndex ?? LibraryIndex.build(safetyGuard: guardCopy)
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
        leftoverGroups[idx].isChecked.toggle()
        let newState = leftoverGroups[idx].isChecked
        for fIdx in leftoverGroups[idx].files.indices {
            leftoverGroups[idx].files[fIdx].isSelected = newState
        }
    }

    func toggleLeftoverFile(groupID: String, fileID: String) {
        guard let gIdx = leftoverGroups.firstIndex(where: { $0.id == groupID }),
              let fIdx = leftoverGroups[gIdx].files.firstIndex(where: { $0.id == fileID }) else {
            return
        }
        leftoverGroups[gIdx].files[fIdx].isSelected.toggle()
        leftoverGroups[gIdx].isChecked = leftoverGroups[gIdx].files.contains(where: \.isSelected)
    }

    func selectHighConfidenceLeftoversOnly() {
        for idx in leftoverGroups.indices {
            let isHigh = leftoverGroups[idx].confidence == .high
            leftoverGroups[idx].isChecked = isHigh
            for fIdx in leftoverGroups[idx].files.indices {
                leftoverGroups[idx].files[fIdx].isSelected = isHigh
            }
        }
    }

    func ignoreLeftoverGroup(_ group: LeftoverGroup) {
        if !preferences.ignoredLeftoverIDs.contains(where: { $0.lowercased() == group.id.lowercased() }) {
            preferences.ignoredLeftoverIDs.append(group.id)
            savePreferences()
        }
        leftoverGroups.removeAll { $0.id == group.id }
    }

    func prepareRemovalForCheckedLeftovers() {
        var targets: [RemovalTarget] = []
        var groupIDs: [String] = []
        for group in leftoverGroups where group.isChecked {
            let selected = group.files.filter(\.isSelected)
            guard !selected.isEmpty else { continue }
            groupIDs.append(group.id)
            for file in selected {
                targets.append(RemovalTarget(
                    url: file.url,
                    estimatedSize: file.size ?? 0,
                    requiresAdmin: file.requiresAdmin
                ))
            }
        }
        guard !targets.isEmpty else { return }
        pendingConfirmation = PendingConfirmation(
            title: l10n.isChinese ? "清理 \(groupIDs.count) 组残留文件" : "Clean \(groupIDs.count) leftover groups",
            isReset: false,
            targets: targets,
            packageIDsToForget: [],
            runningAppBundleIDs: [],
            runningAppNames: [],
            hasAppleAppStoreApp: false,
            hasChromiumExtension: false,
            sourceTab: .leftovers,
            affectedAppIDs: [],
            affectedStartupIDs: [],
            affectedExtensionIDs: [],
            affectedLeftoverIDs: groupIDs
        )
    }

    // MARK: - Extensions (M4)

    func loadExtensionsIfNeeded() async {
        if extensionItems.isEmpty && !isScanningExtensions {
            await scanExtensions()
        }
    }

    func scanExtensions() async {
        isScanningExtensions = true
        let guardCopy = safetyGuard
        let result = await Task.detached(priority: .userInitiated) {
            ExtensionScanner(safetyGuard: guardCopy).scanAll()
        }.value
        extensionItems = result.items
        extensionsNeedFDAForBrowsers = result.needsFullDiskAccessForBrowsers
        blockedBrowserNames = result.blockedBrowserNames
        isScanningExtensions = false
    }

    func toggleExtensionItem(_ item: ExtensionItem, enable: Bool) async {
        guard item.canToggle else { return }
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
        return AppScanner.runningBundleIDs().contains(bid)
    }

    func quitBrowser(for item: ExtensionItem) async {
        guard let bid = item.browserBundleID else { return }
        _ = await RemovalEngine.terminateRunningApps(bundleIDs: [bid], forceAfterTimeout: false)
        objectWillChange.send()
    }

    func prepareRemovalForExtension(_ item: ExtensionItem) {
        guard item.canRemove else { return }
        if item.category.isChromium && isBrowserRunning(for: item) {
            banner = OperationBanner(
                isError: true,
                message: l10n.t("请先退出对应浏览器后再移除该扩展。", "Please quit the browser before removing this extension."),
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }
        pendingConfirmation = PendingConfirmation(
            title: l10n.isChinese ? "移除扩展 \(item.name)" : "Remove extension \(item.name)",
            isReset: false,
            targets: [RemovalTarget(url: item.path, estimatedSize: item.size, requiresAdmin: item.requiresAdmin)],
            packageIDsToForget: [],
            runningAppBundleIDs: [],
            runningAppNames: [],
            hasAppleAppStoreApp: false,
            hasChromiumExtension: item.category.isChromium,
            sourceTab: .extensions,
            affectedAppIDs: [],
            affectedStartupIDs: [],
            affectedExtensionIDs: [item.id],
            affectedLeftoverIDs: []
        )
    }
}

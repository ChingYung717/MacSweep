import AppKit
import Combine
import Foundation
import MacSweepCore

public enum ResourceReleaseSubTab: String, CaseIterable, Identifiable {
    case largeFiles
    case duplicates
    case memory

    public var id: String { rawValue }
}

public enum LargeFileSortOrder: String, CaseIterable, Identifiable {
    case sizeDescending
    case modifiedDescending
    case nameAscending

    public var id: String { rawValue }
}

public enum LargeFileCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case video
    case archiveOrDiskImage
    case installer
    case audio
    case document
    case other

    public var id: String { rawValue }

    var coreCategory: LargeFileCategory? {
        switch self {
        case .all: return nil
        case .video: return .video
        case .archiveOrDiskImage: return .diskImageAndArchive
        case .installer: return .installer
        case .audio: return .audio
        case .document: return .document
        case .other: return .other
        }
    }
}

public enum DuplicateMinSizePreset: UInt64, CaseIterable, Identifiable {
    case kb100 = 100_000
    case mb1 = 1_000_000
    case mb10 = 10_000_000
    case mb50 = 50_000_000
    case mb100 = 100_000_000

    public var id: UInt64 { rawValue }

    public var label: String {
        switch self {
        case .kb100: return "≥ 100 KB"
        case .mb1: return "≥ 1 MB"
        case .mb10: return "≥ 10 MB"
        case .mb50: return "≥ 50 MB"
        case .mb100: return "≥ 100 MB"
        }
    }
}

struct CleanupRemovalInput: Sendable {
    let url: URL
    let size: Int64
    let requiresAdmin: Bool
    let expectedCanonicalParent: String
    let requireCacheSubpath: Bool
    let browserBundleID: String?
}

public struct DuplicateAllCopiesWarning: Identifiable {
    public let id = UUID()
    public let affectedGroupIDs: [String]
    public let affectedGroupLabels: [String]
    public let preferredRemovalMode: RemovalMode?
}

@MainActor
public final class CleanupCenterStore: ObservableObject {
    private weak var appState: AppState?

    // MARK: - Junk Cleaner State
    @Published public var junkCategories: [JunkCategoryItem] = []
    @Published public var selectedJunkCategoryID: String?
    @Published public var focusedJunkEntryID: String?
    @Published public var junkSearchText: String = ""
    @Published public var isScanningJunk: Bool = false
    @Published public var junkScanProgressText: String?
    @Published public var junkError: String?
    @Published public var junkNeedsFDA: Bool = false
    @Published public var junkBlockedBrowserNames: [String] = []

    // MARK: - Resource Release Navigation
    @Published public var resourceSubTab: ResourceReleaseSubTab = .largeFiles

    // MARK: - Large Files State
    @Published public var largeFilesRootURL: URL
    @Published public var largeFileMinSizePreset: DiskSizeThresholdPreset = .mb100
    @Published public var largeFileAgePreset: DiskAgePreset = .all
    @Published public var largeFileCategoryFilter: LargeFileCategoryFilter = .all
    @Published public var largeFileSortOrder: LargeFileSortOrder = .sizeDescending
    @Published public var largeFileSearchText: String = ""
    @Published public var largeFiles: [LargeFileItem] = []
    @Published public var selectedLargeFileIDs: Set<String> = []
    @Published public var focusedLargeFileID: String?
    @Published public var isScanningLargeFiles: Bool = false
    @Published public var largeFilesProgress: ResourceScanProgress?
    @Published public var largeFilesError: String?
    @Published public var showLargeFileInspector: Bool = true
    @Published public var inspectedLargeFileURL: URL?
    @Published public var inspectedLargeFileMetadata: FileMetadataInfo?
    @Published var largeFilePreviewState: InspectorPreviewState = .none
    @Published public var isInspectedLargeFileProtected: Bool = false
    @Published public var inspectedLargeFileProtectionReason: String?

    // MARK: - Duplicate Files State
    @Published public var duplicateRootURL: URL
    @Published public var duplicateMinSizePreset: DuplicateMinSizePreset = .mb1
    @Published public var duplicateGroups: [DuplicateGroup] = []
    @Published public var duplicateSearchText: String = ""
    @Published public var isScanningDuplicates: Bool = false
    @Published public var duplicateProgress: ResourceScanProgress?
    @Published public var duplicateError: String?
    @Published public var focusedDuplicateURL: URL?
    @Published public var pendingAllCopiesWarning: DuplicateAllCopiesWarning?

    // MARK: - Memory / RAM State
    @Published public var memorySnapshot: MemorySnapshot?
    @Published public var lastMemoryReleaseResult: MemoryReleaseResult?
    @Published public var isRefreshingMemory: Bool = false
    @Published public var isReleasingMemory: Bool = false
    @Published public var memoryError: String?
    @Published public var autoRefreshMemory: Bool = true
    @Published public var showElevatedPurgeConfirm: Bool = false

    // MARK: - Task & Generation Guards
    private var junkGeneration: Int = 0
    private var junkTask: Task<Void, Never>?
    private var largeFilesGeneration: Int = 0
    private var largeFilesTask: Task<Void, Never>?
    private var duplicatesGeneration: Int = 0
    private var duplicatesTask: Task<Void, Never>?
    private var largePreviewGeneration: Int = 0
    private var largePreviewTask: Task<Void, Never>?
    private var hasLoadedJunkOnce: Bool = false
    private var hasLoadedLargeFilesOnce: Bool = false
    private var demoCatalog: DemoFixtureCatalog?

    init(initialDirectory: URL = URL(fileURLWithPath: "/")) {
        let std = initialDirectory.standardizedFileURL
        self.largeFilesRootURL = std
        self.duplicateRootURL = std
    }

    func configureInitialDirectory(_ url: URL) {
        let std = url.standardizedFileURL
        self.largeFilesRootURL = std
        self.duplicateRootURL = std
    }

    func attach(to appState: AppState) {
        self.appState = appState
    }

    func loadDemoCatalog(_ catalog: DemoFixtureCatalog) {
        self.demoCatalog = catalog
        self.junkCategories = catalog.junkCategories
        self.junkNeedsFDA = catalog.junkScanResult.needsFullDiskAccess
        self.junkBlockedBrowserNames = catalog.junkScanResult.blockedLocations
        self.selectedJunkCategoryID = catalog.junkCategories.first?.id
        self.focusedJunkEntryID = catalog.junkCategories.first?.entries.first?.id
        self.isScanningJunk = false

        self.largeFilesRootURL = DemoFixtureCatalog.homeDirectoryURL
        self.largeFiles = catalog.largeFiles
        self.isScanningLargeFiles = false
        if let firstLarge = catalog.largeFiles.first {
            self.focusLargeFile(firstLarge)
        }

        self.duplicateRootURL = DemoFixtureCatalog.homeDirectoryURL
        self.duplicateGroups = catalog.duplicateGroups
        self.isScanningDuplicates = false
        self.focusedDuplicateURL = catalog.duplicateGroups.first?.files.first?.url

        self.memorySnapshot = catalog.memorySnapshot
        self.lastMemoryReleaseResult = catalog.memoryReleaseResult(from: catalog.memorySnapshot, elevated: false)
        self.autoRefreshMemory = false
        self.isRefreshingMemory = false
        self.isReleasingMemory = false

        self.hasLoadedJunkOnce = true
        self.hasLoadedLargeFilesOnce = true
        self.refreshProtectionFlags(using: currentGuard)
    }

    private var isDemoMode: Bool {
        appState?.isDemoMode ?? false
    }

    private var currentGuard: SafetyGuard {
        appState?.safetyGuard ?? SafetyGuard()
    }

    private var l10n: L10n {
        appState?.l10n ?? L10n(language: .system)
    }

    // MARK: - Lifecycle

    func loadJunkIfNeeded() async {
        if isDemoMode { return }
        if !hasLoadedJunkOnce && !isScanningJunk {
            hasLoadedJunkOnce = true
            scanJunk()
        }
    }

    func loadResourceTabIfNeeded() async {
        if isDemoMode { return }
        if memorySnapshot == nil {
            await refreshMemorySnapshot()
        }
        if resourceSubTab == .largeFiles && !hasLoadedLargeFilesOnce && !isScanningLargeFiles {
            hasLoadedLargeFilesOnce = true
            scanLargeFiles()
        }
    }

    // MARK: - Junk Cleaner Computeds & Actions

    var activeJunkCategory: JunkCategoryItem? {
        if let id = selectedJunkCategoryID,
           let match = junkCategories.first(where: { $0.id == id }) {
            return match
        }
        return junkCategories.first
    }

    var totalJunkDiscoveredBytes: UInt64 {
        junkCategories.reduce(into: UInt64(0)) { $0 &+= $1.totalBytes }
    }

    var selectedJunkCount: Int {
        junkCategories.reduce(into: 0) { $0 += $1.selectedCount }
    }

    var selectedJunkBytes: UInt64 {
        junkCategories.reduce(into: UInt64(0)) { $0 &+= $1.selectedBytes }
    }

    func filteredEntries(for category: JunkCategoryItem) -> [JunkEntry] {
        let q = junkSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return category.entries }
        return category.entries.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.url.path.localizedCaseInsensitiveContains(q)
                || ($0.subgroup?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    func scanJunk() {
        junkTask?.cancel()
        junkGeneration += 1
        let gen = junkGeneration

        if isDemoMode, let catalog = demoCatalog {
            junkCategories = catalog.junkCategories
            junkNeedsFDA = catalog.junkScanResult.needsFullDiskAccess
            junkBlockedBrowserNames = catalog.junkScanResult.blockedLocations
            selectedJunkCategoryID = catalog.junkCategories.first?.id
            focusedJunkEntryID = catalog.junkCategories.first?.entries.first?.id
            isScanningJunk = false
            junkError = nil
            junkScanProgressText = nil
            refreshProtectionFlags(using: currentGuard)
            return
        }

        isScanningJunk = true
        junkError = nil
        junkScanProgressText = nil
        focusedJunkEntryID = nil

        let guardCopy = currentGuard
        let sizerRef = appState?.sizer ?? DirectorySizer()

        junkTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let onProgress: @Sendable (JunkScanProgress) -> Void = { [weak self] progress in
                    let sanitized = SafeFileReader.sanitizeForDisplay(progress.currentPath)
                    Task { @MainActor [weak self] in
                        guard let self, self.junkGeneration == gen, self.isScanningJunk else { return }
                        self.junkScanProgressText = sanitized
                    }
                }
                let innerTask = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let scanner = JunkCacheScanner(safetyGuard: guardCopy, sizer: sizerRef)
                    return try await scanner.scanAll(onProgress: onProgress)
                }
                let result = try await withTaskCancellationHandler {
                    try await innerTask.value
                } onCancel: {
                    innerTask.cancel()
                }

                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.junkGeneration == gen else { return }
                    self.junkCategories = result.categories
                    self.junkNeedsFDA = result.needsFullDiskAccess
                    self.junkBlockedBrowserNames = result.blockedLocations
                    if self.selectedJunkCategoryID == nil
                        || !result.categories.contains(where: { $0.id == self.selectedJunkCategoryID }) {
                        self.selectedJunkCategoryID = result.categories.first(where: { !$0.entries.isEmpty })?.id
                            ?? result.categories.first?.id
                    }
                    self.isScanningJunk = false
                    self.junkScanProgressText = nil
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.junkGeneration == gen else { return }
                    self.isScanningJunk = false
                    self.junkScanProgressText = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.junkGeneration == gen else { return }
                    self.isScanningJunk = false
                    self.junkScanProgressText = nil
                    self.junkError = error.localizedDescription
                }
            }
        }
    }

    func cancelJunkScan() {
        junkGeneration += 1
        junkTask?.cancel()
        junkTask = nil
        isScanningJunk = false
        junkScanProgressText = nil
    }

    func toggleJunkEntry(categoryID: String, entryID: String) {
        guard let cIdx = junkCategories.firstIndex(where: { $0.id == categoryID }),
              let eIdx = junkCategories[cIdx].entries.firstIndex(where: { $0.id == entryID }) else {
            return
        }
        let entry = junkCategories[cIdx].entries[eIdx]
        guard !entry.isProtected && !entry.isRunningAppBlocked else { return }
        junkCategories[cIdx].entries[eIdx].isSelected.toggle()
    }

    func toggleJunkCategory(categoryID: String, selected: Bool) {
        guard let cIdx = junkCategories.firstIndex(where: { $0.id == categoryID }) else { return }
        for eIdx in junkCategories[cIdx].entries.indices {
            let entry = junkCategories[cIdx].entries[eIdx]
            guard !entry.isProtected && !entry.isRunningAppBlocked else { continue }
            if selected {
                // Keep admin-required or safety-flagged items (e.g. Xcode Archives) opt-in unless explicitly toggled per-item,
                // OR allow category toggle for non-admin safe items; if all are admin/flagged, allow toggling user entries.
                let isUnsafeDefault = entry.category == .developerCaches && !entry.isRecommendedSafe
                if !isUnsafeDefault && !entry.requiresAdmin {
                    junkCategories[cIdx].entries[eIdx].isSelected = true
                }
            } else {
                junkCategories[cIdx].entries[eIdx].isSelected = false
            }
        }
    }

    func selectRecommendedSafeJunk() {
        for cIdx in junkCategories.indices {
            for eIdx in junkCategories[cIdx].entries.indices {
                let entry = junkCategories[cIdx].entries[eIdx]
                junkCategories[cIdx].entries[eIdx].isSelected = entry.isRecommendedSafe
                    && !entry.isProtected
                    && !entry.isRunningAppBlocked
                    && !entry.requiresAdmin
            }
        }
    }

    func clearAllJunkSelections() {
        for cIdx in junkCategories.indices {
            for eIdx in junkCategories[cIdx].entries.indices {
                junkCategories[cIdx].entries[eIdx].isSelected = false
            }
        }
    }

    public func requestRemovalForSelectedJunk() {
        guard let appState else { return }
        let selectedEntries = junkCategories.flatMap(\.entries).filter {
            $0.isSelected && !$0.isProtected && !$0.isRunningAppBlocked
        }
        guard !selectedEntries.isEmpty else { return }

        // Enforce running-browser safety check if any browser cache entry was selected.
        let browserIDs = Array(Set(selectedEntries.compactMap(\.browserBundleID)))
        if !browserIDs.isEmpty {
            let hasRunningBrowser: Bool
            if isDemoMode {
                hasRunningBrowser = browserIDs.contains { appState.isDemoBrowserRunning(bundleID: $0) }
            } else {
                hasRunningBrowser = !AppScanner.runningProcesses(matchingBundleIDs: browserIDs, bundleURLs: []).isEmpty
            }
            if hasRunningBrowser {
                appState.banner = OperationBanner(
                    isError: true,
                    message: l10n.junkQuitBrowsersFirst,
                    showAppManagementLink: false,
                    showFDALink: false
                )
                return
            }
        }

        let inputs = selectedEntries.map { entry in
            CleanupRemovalInput(
                url: entry.url,
                size: Int64(entry.bytes),
                requiresAdmin: entry.requiresAdmin,
                expectedCanonicalParent: entry.expectedCanonicalParent,
                requireCacheSubpath: (entry.category == .userCaches || entry.category == .browserCaches),
                browserBundleID: entry.browserBundleID
            )
        }
        let title = l10n.isChinese
            ? "清理 \(inputs.count) 项垃圾与缓存"
            : (inputs.count == 1 ? "Clean 1 junk item" : "Clean \(inputs.count) junk items")
        appState.prepareRemovalForCleanupItems(
            inputs,
            title: title,
            sourceTab: .junkCleaner,
            browserBundleIDsToRequireClosed: browserIDs
        )
    }

    // MARK: - Large Files Computeds & Actions

    var filteredAndSortedLargeFiles: [LargeFileItem] {
        let now = isDemoMode ? DemoFixtureCatalog.referenceDate : Date()
        let cutoff: Date? = largeFileAgePreset == .all
            ? nil
            : now.addingTimeInterval(-TimeInterval(largeFileAgePreset.rawValue) * 86_400)
        let query = largeFileSearchText.trimmingCharacters(in: .whitespacesAndNewlines)

        let filtered = largeFiles.filter { item in
            if let cutoff {
                guard let mod = item.modificationDate, mod <= cutoff else { return false }
            }
            if let cat = largeFileCategoryFilter.coreCategory, item.category != cat {
                return false
            }
            if !query.isEmpty {
                let matchesName = item.name.localizedCaseInsensitiveContains(query)
                let matchesPath = item.relativePathFromRoot.localizedCaseInsensitiveContains(query)
                if !matchesName && !matchesPath { return false }
            }
            return true
        }

        switch largeFileSortOrder {
        case .sizeDescending:
            return filtered.sorted {
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .modifiedDescending:
            return filtered.sorted {
                let lDate = $0.modificationDate ?? .distantPast
                let rDate = $1.modificationDate ?? .distantPast
                if lDate != rDate { return lDate > rDate }
                return $0.bytes > $1.bytes
            }
        case .nameAscending:
            return filtered.sorted {
                let cmp = $0.name.localizedStandardCompare($1.name)
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return $0.url.path < $1.url.path
            }
        }
    }

    var selectedLargeFileCount: Int {
        largeFiles.count { selectedLargeFileIDs.contains($0.id) && !$0.isProtected }
    }

    var selectedLargeFileBytes: UInt64 {
        largeFiles
            .filter { selectedLargeFileIDs.contains($0.id) && !$0.isProtected }
            .reduce(into: UInt64(0)) { $0 &+= $1.bytes }
    }

    func scanLargeFiles(at rootURL: URL? = nil) {
        let targetURL = (rootURL ?? largeFilesRootURL).standardizedFileURL
        largeFilesTask?.cancel()
        largeFilesGeneration += 1
        let gen = largeFilesGeneration

        largeFilesRootURL = targetURL
        isScanningLargeFiles = true
        largeFilesError = nil
        largeFilesProgress = nil
        selectedLargeFileIDs.removeAll()
        focusedLargeFileID = nil
        hasLoadedLargeFilesOnce = true

        let minBytes = max(LargeFileSizeThreshold.mb50.rawValue, largeFileMinSizePreset.rawValue)
        let guardCopy = currentGuard

        if isDemoMode, let catalog = demoCatalog {
            let rootPath = targetURL.path
            largeFiles = catalog.largeFiles.filter { item in
                item.bytes >= minBytes && (rootPath == DemoFixtureCatalog.homeDirectoryPath || item.url.path.hasPrefix(rootPath + "/") || item.url.path == rootPath)
            }
            isScanningLargeFiles = false
            largeFilesProgress = nil
            refreshProtectionFlags(using: guardCopy)
            focusLargeFile(largeFiles.first)
            return
        }

        largeFilesTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let onProgress: @Sendable (ResourceScanProgress) -> Void = { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.largeFilesGeneration == gen, self.isScanningLargeFiles else { return }
                        self.largeFilesProgress = progress
                    }
                }
                let scanner = LargeAndDuplicateScanner(safetyGuard: guardCopy)
                let items = try await scanner.scanLargeFiles(
                    under: targetURL,
                    options: LargeFileScanOptions(minBytes: minBytes, maxResults: 500),
                    onProgress: onProgress
                )

                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.largeFilesGeneration == gen else { return }
                    self.largeFiles = items
                    self.isScanningLargeFiles = false
                    self.largeFilesProgress = nil
                    if let first = items.first {
                        self.focusLargeFile(first)
                    } else {
                        self.focusLargeFile(nil)
                    }
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.largeFilesGeneration == gen else { return }
                    self.isScanningLargeFiles = false
                    self.largeFilesProgress = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.largeFilesGeneration == gen else { return }
                    self.isScanningLargeFiles = false
                    self.largeFilesProgress = nil
                    self.largeFilesError = error.localizedDescription
                }
            }
        }
    }

    func cancelLargeFilesScan() {
        largeFilesGeneration += 1
        largeFilesTask?.cancel()
        largeFilesTask = nil
        isScanningLargeFiles = false
        largeFilesProgress = nil
    }

    func toggleLargeFileSelection(_ id: String) {
        guard let item = largeFiles.first(where: { $0.id == id }), !item.isProtected else { return }
        if selectedLargeFileIDs.contains(id) {
            selectedLargeFileIDs.remove(id)
        } else {
            selectedLargeFileIDs.insert(id)
        }
    }

    func selectAllFilteredLargeFiles() {
        for item in filteredAndSortedLargeFiles where !item.isProtected {
            selectedLargeFileIDs.insert(item.id)
        }
    }

    func clearLargeFileSelections() {
        selectedLargeFileIDs.removeAll()
    }

    func focusLargeFile(_ item: LargeFileItem?) {
        focusedLargeFileID = item?.id
        inspectLargeFile(url: item?.url)
    }

    private func inspectLargeFile(url: URL?) {
        largePreviewTask?.cancel()
        largePreviewGeneration += 1
        let gen = largePreviewGeneration

        guard let url else {
            inspectedLargeFileURL = nil
            inspectedLargeFileMetadata = nil
            largeFilePreviewState = .none
            isInspectedLargeFileProtected = false
            inspectedLargeFileProtectionReason = nil
            return
        }

        inspectedLargeFileURL = url.standardizedFileURL

        if isDemoMode, let catalog = demoCatalog {
            let payload = catalog.previewPayload(for: url)
            inspectedLargeFileMetadata = payload.metadata
            switch currentGuard.validateForRemoval(url) {
            case .allowed:
                isInspectedLargeFileProtected = payload.isProtected
                inspectedLargeFileProtectionReason = payload.protectionReason
            case let .blocked(reason):
                isInspectedLargeFileProtected = true
                inspectedLargeFileProtectionReason = reason
            }
            largeFilePreviewState = FileManagerStore.mapPreviewPayload(payload)
            return
        }

        largeFilePreviewState = .loading
        let guardCopy = currentGuard

        largePreviewTask = Task {
            do {
                let payload = try await FileBrowserService(safetyGuard: guardCopy).loadPreviewAsync(at: url)
                guard !Task.isCancelled else { return }
                let mappedState = FileManagerStore.mapPreviewPayload(payload)
                await MainActor.run { [weak self] in
                    guard let self, self.largePreviewGeneration == gen else { return }
                    self.inspectedLargeFileMetadata = payload.metadata
                    self.isInspectedLargeFileProtected = payload.isProtected
                    self.inspectedLargeFileProtectionReason = payload.protectionReason
                    self.largeFilePreviewState = mappedState
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.largePreviewGeneration == gen else { return }
                    self.inspectedLargeFileMetadata = nil
                    self.largeFilePreviewState = .unavailable(.notFound)
                }
            }
        }
    }

    func requestRemovalForSelectedLargeFiles(preferredMode: RemovalMode? = nil) {
        guard let appState else { return }
        let selected = largeFiles.filter { selectedLargeFileIDs.contains($0.id) && !$0.isProtected }
        guard !selected.isEmpty else { return }
        let inputs = selected.map { item in
            CleanupRemovalInput(
                url: item.url,
                size: Int64(item.bytes),
                requiresAdmin: item.requiresAdmin,
                expectedCanonicalParent: item.expectedCanonicalParent,
                requireCacheSubpath: false,
                browserBundleID: nil
            )
        }
        let title = l10n.isChinese
            ? "清理 \(inputs.count) 个大文件"
            : (inputs.count == 1 ? "Remove 1 large file" : "Remove \(inputs.count) large files")
        appState.prepareRemovalForCleanupItems(
            inputs,
            title: title,
            sourceTab: .resourceRelease,
            preferredRemovalModeOverride: preferredMode
        )
    }

    // MARK: - Duplicate Files Computeds & Actions

    public var filteredDuplicateGroups: [DuplicateGroup] {
        let minBytes = duplicateMinSizePreset.rawValue
        let q = duplicateSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return duplicateGroups.filter { group in
            guard group.fileSize >= minBytes else { return false }
            guard !q.isEmpty else { return true }
            return group.sha256Hex.localizedCaseInsensitiveContains(q)
                || group.files.contains {
                    $0.name.localizedCaseInsensitiveContains(q)
                        || $0.url.path.localizedCaseInsensitiveContains(q)
                }
        }
    }

    var totalDuplicateCopiesCount: Int {
        duplicateGroups.reduce(into: 0) { $0 += $1.files.count }
    }

    var totalDuplicateReclaimableBytes: UInt64 {
        duplicateGroups.reduce(into: UInt64(0)) { $0 &+= $1.reclaimableBytes }
    }

    var selectedDuplicateCount: Int {
        duplicateGroups.reduce(into: 0) { $0 += $1.selectedCount }
    }

    var selectedDuplicateBytes: UInt64 {
        duplicateGroups.reduce(into: UInt64(0)) { $0 &+= $1.selectedReclaimableBytes }
    }

    var groupsWithAllCopiesSelected: [DuplicateGroup] {
        duplicateGroups.filter(\.allCopiesSelected)
    }

    public func scanDuplicates(at rootURL: URL? = nil) {
        let targetURL = (rootURL ?? duplicateRootURL).standardizedFileURL
        duplicatesTask?.cancel()
        duplicatesGeneration += 1
        let gen = duplicatesGeneration

        duplicateRootURL = targetURL
        isScanningDuplicates = true
        duplicateError = nil
        duplicateProgress = nil
        focusedDuplicateURL = nil

        let minBytes = duplicateMinSizePreset.rawValue
        let guardCopy = currentGuard

        if isDemoMode, let catalog = demoCatalog {
            let rootPath = targetURL.path
            duplicateGroups = catalog.duplicateGroups.filter { group in
                group.fileSize >= minBytes && group.files.contains {
                    rootPath == DemoFixtureCatalog.homeDirectoryPath || $0.url.path.hasPrefix(rootPath + "/")
                }
            }
            isScanningDuplicates = false
            duplicateProgress = nil
            refreshProtectionFlags(using: guardCopy)
            return
        }

        duplicatesTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let onProgress: @Sendable (ResourceScanProgress) -> Void = { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.duplicatesGeneration == gen, self.isScanningDuplicates else { return }
                        self.duplicateProgress = progress
                    }
                }
                let scanner = LargeAndDuplicateScanner(safetyGuard: guardCopy)
                let groups = try await scanner.scanDuplicates(
                    under: targetURL,
                    options: DuplicateScanOptions(minBytes: minBytes, maxGroups: 400),
                    onProgress: onProgress
                )

                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.duplicatesGeneration == gen else { return }
                    self.duplicateGroups = groups
                    self.isScanningDuplicates = false
                    self.duplicateProgress = nil
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.duplicatesGeneration == gen else { return }
                    self.isScanningDuplicates = false
                    self.duplicateProgress = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.duplicatesGeneration == gen else { return }
                    self.isScanningDuplicates = false
                    self.duplicateProgress = nil
                    self.duplicateError = error.localizedDescription
                }
            }
        }
    }

    func cancelDuplicatesScan() {
        duplicatesGeneration += 1
        duplicatesTask?.cancel()
        duplicatesTask = nil
        isScanningDuplicates = false
        duplicateProgress = nil
    }

    func toggleDuplicateEntry(groupID: String, entryID: String) {
        guard let gIdx = duplicateGroups.firstIndex(where: { $0.id == groupID }),
              let eIdx = duplicateGroups[gIdx].files.firstIndex(where: { $0.id == entryID }) else {
            return
        }
        guard !duplicateGroups[gIdx].files[eIdx].isProtected else { return }
        duplicateGroups[gIdx].files[eIdx].isSelected.toggle()
    }

    func applyDuplicateSelectionPreset(_ preset: DuplicateSelectionPreset) {
        duplicateGroups = duplicateGroups.map { $0.applyingPreset(preset) }
    }

    func keepOnlyDuplicateEntry(groupID: String, entryID: String) {
        guard let gIdx = duplicateGroups.firstIndex(where: { $0.id == groupID }) else { return }
        for eIdx in duplicateGroups[gIdx].files.indices {
            let entry = duplicateGroups[gIdx].files[eIdx]
            if entry.id == entryID || entry.isProtected {
                duplicateGroups[gIdx].files[eIdx].isSelected = false
            } else {
                duplicateGroups[gIdx].files[eIdx].isSelected = true
            }
        }
    }

    func requestRemovalForSelectedDuplicates(preferredMode: RemovalMode? = nil) {
        let selectedCount = selectedDuplicateCount
        guard selectedCount > 0 else { return }

        let allSelectedGroups = groupsWithAllCopiesSelected
        if !allSelectedGroups.isEmpty {
            pendingAllCopiesWarning = DuplicateAllCopiesWarning(
                affectedGroupIDs: allSelectedGroups.map(\.id),
                affectedGroupLabels: allSelectedGroups.map { $0.files.first?.displayName ?? $0.sha256Hex },
                preferredRemovalMode: preferredMode
            )
            return
        }

        forwardSelectedDuplicatesToConfirmation(preferredMode: preferredMode)
    }

    func confirmKeepOneCopyAndProceed() {
        guard let warning = pendingAllCopiesWarning else { return }
        let affected = Set(warning.affectedGroupIDs)
        let preferredMode = warning.preferredRemovalMode
        pendingAllCopiesWarning = nil

        for gIdx in duplicateGroups.indices where affected.contains(duplicateGroups[gIdx].id) {
            duplicateGroups[gIdx] = duplicateGroups[gIdx].applyingPreset(.preferNonDownloads)
        }
        forwardSelectedDuplicatesToConfirmation(preferredMode: preferredMode)
    }

    func confirmDeleteAllCopiesAnyway() {
        guard let warning = pendingAllCopiesWarning else { return }
        let preferredMode = warning.preferredRemovalMode
        pendingAllCopiesWarning = nil
        forwardSelectedDuplicatesToConfirmation(preferredMode: preferredMode)
    }

    private func forwardSelectedDuplicatesToConfirmation(preferredMode: RemovalMode?) {
        guard let appState else { return }
        var inputs: [CleanupRemovalInput] = []
        for group in duplicateGroups {
            for entry in group.files where entry.isSelected && !entry.isProtected {
                inputs.append(CleanupRemovalInput(
                    url: entry.url,
                    size: Int64(group.fileSize),
                    requiresAdmin: entry.requiresAdmin,
                    expectedCanonicalParent: entry.expectedCanonicalParent,
                    requireCacheSubpath: false,
                    browserBundleID: nil
                ))
            }
        }
        guard !inputs.isEmpty else { return }
        let title = l10n.isChinese
            ? "清理 \(inputs.count) 份重复文件"
            : (inputs.count == 1 ? "Remove 1 duplicate file" : "Remove \(inputs.count) duplicate files")
        appState.prepareRemovalForCleanupItems(
            inputs,
            title: title,
            sourceTab: .resourceRelease,
            preferredRemovalModeOverride: preferredMode
        )
    }

    // MARK: - Memory / RAM Actions

    func refreshMemorySnapshot() async {
        if isDemoMode {
            if memorySnapshot == nil, let catalog = demoCatalog {
                memorySnapshot = catalog.memorySnapshot
            }
            isRefreshingMemory = false
            return
        }
        guard !isRefreshingMemory else { return }
        isRefreshingMemory = true
        let guardCopy = currentGuard
        let snap = await Task.detached(priority: .utility) {
            MemoryReleaseService(privilegedExecutor: PrivilegedExecutor(safetyGuard: guardCopy)).captureSnapshot()
        }.value
        memorySnapshot = snap
        isRefreshingMemory = false
    }

    func performStandardPressureRelief() async {
        guard !isReleasingMemory else { return }
        if isDemoMode, let catalog = demoCatalog {
            let before = memorySnapshot ?? catalog.memorySnapshot
            let result = catalog.memoryReleaseResult(from: before, elevated: false)
            memorySnapshot = result.after
            lastMemoryReleaseResult = result
            let deltaStr = ByteFormatter.formatMemory(Int64(result.reclaimedEstimateBytes))
            appState?.banner = OperationBanner(
                isError: false,
                message: l10n.isChinese
                    ? "演示模式：已完成标准内存压力释放（空闲内存变化：+\(deltaStr)）"
                    : "Demo mode: Completed standard pressure relief (free RAM delta: +\(deltaStr))",
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }
        isReleasingMemory = true
        memoryError = nil
        let guardCopy = currentGuard

        let result = await Task.detached(priority: .userInitiated) {
            await MemoryReleaseService(privilegedExecutor: PrivilegedExecutor(safetyGuard: guardCopy)).performStandardRelief()
        }.value

        memorySnapshot = result.after
        lastMemoryReleaseResult = result
        isReleasingMemory = false

        let deltaStr = ByteFormatter.formatMemory(Int64(result.reclaimedEstimateBytes))
        appState?.banner = OperationBanner(
            isError: false,
            message: l10n.isChinese
                ? "已完成标准内存压力释放（空闲内存变化：+\(deltaStr)）"
                : "Completed standard pressure relief (free RAM delta: +\(deltaStr))",
            showAppManagementLink: false,
            showFDALink: false
        )
    }

    func performElevatedPurge() async {
        guard !isReleasingMemory else { return }
        if isDemoMode, let catalog = demoCatalog {
            let before = memorySnapshot ?? catalog.memorySnapshot
            let result = catalog.memoryReleaseResult(from: before, elevated: true)
            memorySnapshot = result.after
            lastMemoryReleaseResult = result
            let deltaStr = ByteFormatter.formatMemory(Int64(result.reclaimedEstimateBytes))
            appState?.banner = OperationBanner(
                isError: false,
                message: l10n.isChinese
                    ? "演示模式：已模拟 /usr/sbin/purge 清理内核缓存（空闲内存变化：+\(deltaStr)）"
                    : "Demo mode: Simulated /usr/sbin/purge (free RAM delta: +\(deltaStr))",
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }
        isReleasingMemory = true
        memoryError = nil
        let guardCopy = currentGuard

        let outcome: Result<MemoryReleaseResult, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let service = MemoryReleaseService(privilegedExecutor: PrivilegedExecutor(safetyGuard: guardCopy))
                let res = try await service.performElevatedPurge()
                return .success(res)
            } catch {
                return .failure(error)
            }
        }.value

        isReleasingMemory = false

        switch outcome {
        case let .success(res):
            memorySnapshot = res.after
            lastMemoryReleaseResult = res
            let deltaStr = ByteFormatter.formatMemory(Int64(res.reclaimedEstimateBytes))
            appState?.banner = OperationBanner(
                isError: false,
                message: l10n.isChinese
                    ? "已执行 /usr/sbin/purge 清理内核磁盘缓存（空闲内存变化：+\(deltaStr)）"
                    : "Executed /usr/sbin/purge (free RAM delta: +\(deltaStr))",
                showAppManagementLink: false,
                showFDALink: false
            )
        case let .failure(err):
            if let privErr = err as? PrivilegedError, privErr == .userCancelled {
                appState?.banner = OperationBanner(
                    isError: false,
                    message: l10n.t("已取消管理员授权，未执行内存清理。", "Administrator authorization cancelled."),
                    showAppManagementLink: false,
                    showFDALink: false
                )
            } else {
                memoryError = err.localizedDescription
                appState?.banner = OperationBanner(
                    isError: true,
                    message: err.localizedDescription,
                    showAppManagementLink: false,
                    showFDALink: false
                )
            }
        }
    }

    // MARK: - Sync Hooks from AppState

    func protectPath(_ url: URL) {
        guard let appState else { return }
        switch appState.addProtectedPath(url.path) {
        case .added:
            appState.banner = OperationBanner(
                isError: false,
                message: l10n.protectedAddedMessage(url.lastPathComponent),
                showAppManagementLink: false,
                showFDALink: false
            )
        case .duplicate:
            appState.banner = OperationBanner(
                isError: false,
                message: l10n.duplicatePathError,
                showAppManagementLink: false,
                showFDALink: false
            )
        case .invalid:
            appState.banner = OperationBanner(
                isError: true,
                message: l10n.invalidPathError,
                showAppManagementLink: false,
                showFDALink: false
            )
        case .saveFailed:
            appState.banner = OperationBanner(
                isError: true,
                message: l10n.preferencesSaveFailedWarning,
                showAppManagementLink: false,
                showFDALink: false
            )
        }
    }

    func refreshProtectionFlags(using safetyGuard: SafetyGuard) {
        for cIdx in junkCategories.indices {
            for eIdx in junkCategories[cIdx].entries.indices {
                let url = junkCategories[cIdx].entries[eIdx].url
                let allowed = safetyGuard.validateForRemoval(url).isAllowed
                junkCategories[cIdx].entries[eIdx].isProtected = !allowed
                if !allowed {
                    junkCategories[cIdx].entries[eIdx].isSelected = false
                }
            }
            junkCategories[cIdx].recalculateTotalBytes()
        }

        for idx in largeFiles.indices {
            let allowed = safetyGuard.validateForRemoval(largeFiles[idx].url).isAllowed
            largeFiles[idx].isProtected = !allowed
            if !allowed {
                selectedLargeFileIDs.remove(largeFiles[idx].id)
            }
        }

        for gIdx in duplicateGroups.indices {
            for eIdx in duplicateGroups[gIdx].files.indices {
                let allowed = safetyGuard.validateForRemoval(duplicateGroups[gIdx].files[eIdx].url).isAllowed
                duplicateGroups[gIdx].files[eIdx].isProtected = !allowed
                if !allowed {
                    duplicateGroups[gIdx].files[eIdx].isSelected = false
                }
            }
        }

        if let url = inspectedLargeFileURL {
            switch safetyGuard.validateForRemoval(url) {
            case .allowed:
                isInspectedLargeFileProtected = false
                inspectedLargeFileProtectionReason = nil
            case let .blocked(reason):
                isInspectedLargeFileProtected = true
                inspectedLargeFileProtectionReason = reason
            }
        }
    }

    public func applyIncrementalRemoval(removedPaths: Set<String>) {
        guard !removedPaths.isEmpty else { return }
        let normalizedRemoved = Set(removedPaths.map(Self.normalizedKey))

        // 1. Junk Cleaner
        for cIdx in junkCategories.indices {
            junkCategories[cIdx].entries.removeAll {
                Self.matchesAnyRemoved($0.url.path, removedNormalized: normalizedRemoved)
            }
            junkCategories[cIdx].recalculateTotalBytes()
        }
        if let focusedJ = focusedJunkEntryID,
           Self.matchesAnyRemoved(focusedJ, removedNormalized: normalizedRemoved) {
            focusedJunkEntryID = nil
        }

        // 2. Large Files
        largeFiles.removeAll {
            Self.matchesAnyRemoved($0.url.path, removedNormalized: normalizedRemoved)
        }
        selectedLargeFileIDs = selectedLargeFileIDs.filter {
            !Self.matchesAnyRemoved($0, removedNormalized: normalizedRemoved)
        }
        if let focusedL = focusedLargeFileID,
           Self.matchesAnyRemoved(focusedL, removedNormalized: normalizedRemoved) {
            focusedLargeFileID = nil
        }
        if let inspectedURL = inspectedLargeFileURL,
           Self.matchesAnyRemoved(inspectedURL.path, removedNormalized: normalizedRemoved) {
            inspectLargeFile(url: nil)
        }

        // 3. Duplicate Files (drop group if < 2 copies remain, otherwise recalculate reclaimableBytes)
        var updatedGroups: [DuplicateGroup] = []
        updatedGroups.reserveCapacity(duplicateGroups.count)
        for var group in duplicateGroups {
            group.files.removeAll {
                Self.matchesAnyRemoved($0.url.path, removedNormalized: normalizedRemoved)
            }
            if group.files.count >= 2 {
                group.recalculateReclaimableBytes()
                updatedGroups.append(group)
            }
        }
        duplicateGroups = updatedGroups
        if let focusedDup = focusedDuplicateURL,
           Self.matchesAnyRemoved(focusedDup.path, removedNormalized: normalizedRemoved) {
            focusedDuplicateURL = nil
        }
    }

    private nonisolated static func normalizedKey(_ path: String) -> String {
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
        let norm = normalizedKey(path)
        return removedNormalized.contains(where: { isSameOrDescendant(norm, ofNormalizedBase: $0) })
    }
}

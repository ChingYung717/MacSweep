import AppKit
import Combine
import Foundation
import MacSweepCore
import UniformTypeIdentifiers

public enum FileManagerMode: String, CaseIterable, Identifiable {
    case spaceAnalyzer
    case fileBrowser

    public var id: String { rawValue }
}

public enum InspectorPreviewState: Equatable {
    case none
    case loading
    case text(String, encoding: String, isTruncated: Bool, totalBytes: Int64?, shownBytes: Int)
    case hexDump(String, byteCount: Int, isTruncated: Bool, totalBytes: Int64?)
    case image(NSImage, utiIdentifier: String?, byteCount: Int)
    case unavailable(FilePreviewUnavailableReason)

    public static func == (lhs: InspectorPreviewState, rhs: InspectorPreviewState) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none), (.loading, .loading):
            return true
        case let (.text(lt, le, ltr, ltot, lsh), .text(rt, re, rtr, rtot, rsh)):
            return lt == rt && le == re && ltr == rtr && ltot == rtot && lsh == rsh
        case let (.hexDump(lh, lb, ltr, ltot), .hexDump(rh, rb, rtr, rtot)):
            return lh == rh && lb == rb && ltr == rtr && ltot == rtot
        case let (.image(li, lu, lb), .image(ri, ru, rb)):
            return li === ri && lu == ru && lb == rb
        case let (.unavailable(lr), .unavailable(rr)):
            return lr == rr
        default:
            return false
        }
    }
}

@MainActor
public final class FileManagerStore: ObservableObject {
    private weak var appState: AppState?

    // Mode
    @Published public var mode: FileManagerMode = .spaceAnalyzer

    // MARK: - Space Analyzer State
    @Published public var analyzerRootURL: URL
    @Published public var analyzerRootNode: DiskTreeNode?
    @Published public var analyzerBreadcrumbIDs: [String] = []
    @Published public var analyzerVolumeInfo: VolumeStorageInfo?
    @Published public var analyzerAvailableVolumes: [VolumeStorageInfo] = []
    @Published public var isAnalyzing: Bool = false
    @Published public var scanProgress: DiskScanProgress?
    @Published public var analyzerError: String?
    @Published public var analyzerSearchText: String = ""
    @Published public var analyzerSizePreset: DiskSizeThresholdPreset = .all
    @Published public var analyzerAgePreset: DiskAgePreset = .all
    @Published public var analyzerAgeBasis: DiskAgeDateBasis = .modificationDate
    @Published public var analyzerIncludeHiddenFiles: Bool = true
    @Published public var analyzerFilteredItems: [DiskFilteredItem] = []
    @Published public var isFilteringDeep: Bool = false
    @Published public var selectedAnalyzerNodeIDs: Set<String> = []
    @Published public var focusedAnalyzerNodeID: String?

    // MARK: - File Browser State
    @Published public var currentDirectoryURL: URL
    @Published public var currentDirectoryCanonicalPath: String = ""
    @Published public var favorites: [FileBrowserFavorite] = []
    @Published public var browserEntries: [FileBrowserEntry] = []
    @Published public var backStack: [URL] = []
    @Published public var forwardStack: [URL] = []
    @Published public var showHiddenFiles: Bool = false
    @Published public var browserSortBy: FileBrowserSort = .name
    @Published public var browserAscending: Bool = true
    @Published public var browserSearchText: String = ""
    @Published public var selectedBrowserEntryIDs: Set<String> = []
    @Published public var focusedBrowserEntryID: String?
    @Published public var isLoadingDirectory: Bool = false
    @Published public var isPerformingFileOp: Bool = false
    @Published public var browserErrorMessage: String?
    @Published public var browserNeedsFDA: Bool = false
    @Published public var showInspector: Bool = true

    // MARK: - Shared Inspector & Preview State
    @Published public var inspectedURL: URL?
    @Published public var inspectedMetadata: FileMetadataInfo?
    @Published public var previewState: InspectorPreviewState = .none
    @Published public var isInspectedURLProtected: Bool = false
    @Published public var inspectedProtectionReason: String?

    private struct HistoryStateSnapshot {
        var currentDirectoryURL: URL
        var backStack: [URL]
        var forwardStack: [URL]
    }

    private enum DirectoryLoadTransition {
        case none
        case pushHistory
        case commitHistory(HistoryStateSnapshot)
    }

    // Concurrency & generation guards
    private var analyzerGeneration: Int = 0
    private var analyzerTask: Task<Void, Never>?
    private var filterGeneration: Int = 0
    private var filterTask: Task<Void, Never>?
    private var browserGeneration: Int = 0
    private var browserTask: Task<Void, Never>?
    private var unfilteredBrowserEntries: [FileBrowserEntry] = []
    private var pendingHistorySnapshot: HistoryStateSnapshot?
    private var previewGeneration: Int = 0
    private var previewTask: Task<Void, Never>?
    private var hasInitialized = false

    // Demo Mode in-memory state
    private var demoCatalog: DemoFixtureCatalog?
    private var demoDirectories: [String: [FileBrowserEntry]] = [:]
    private var demoPreviews: [String: FilePreviewPayload] = [:]
    private var demoRemovedPaths: Set<String> = []
    private var demoBundleIDsByPath: [String: String] = [:]
    private var demoBundleIDsInitialized: Bool = false
    private var demoHomeDiskTree: DiskTreeNode?
    private var demoAppsDiskTree: DiskTreeNode?

    public init(initialDirectory: URL = URL(fileURLWithPath: "/")) {
        let std = initialDirectory.standardizedFileURL
        self.analyzerRootURL = std
        self.currentDirectoryURL = std
        self.currentDirectoryCanonicalPath = std.path
    }

    func configureInitialDirectory(_ url: URL) {
        let std = url.standardizedFileURL
        self.analyzerRootURL = std
        self.currentDirectoryURL = std
        self.currentDirectoryCanonicalPath = PrivilegedExecutor.canonicalParentPath(for: std.path)
    }

    func attach(to appState: AppState) {
        self.appState = appState
    }

    func loadDemoCatalog(_ catalog: DemoFixtureCatalog) {
        self.demoCatalog = catalog
        self.demoDirectories = Dictionary(
            catalog.browserDirectories.map { (Self.normalizedKey($0.key), $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )
        self.demoPreviews = Dictionary(
            catalog.filePreviews.map { (Self.normalizedKey($0.key), $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )
        self.demoRemovedPaths = []
        self.demoBundleIDsByPath = Dictionary(
            catalog.applications.map { (Self.normalizedKey($0.url.path), $0.bundleID) },
            uniquingKeysWith: { _, latest in latest }
        )
        self.demoBundleIDsInitialized = true
        self.demoHomeDiskTree = catalog.diskTree
        self.demoAppsDiskTree = catalog.applicationsDiskTree

        self.analyzerRootURL = DemoFixtureCatalog.homeDirectoryURL
        self.analyzerRootNode = catalog.diskTree
        self.analyzerBreadcrumbIDs = []
        self.analyzerFilteredItems = []
        self.selectedAnalyzerNodeIDs = []
        self.focusedAnalyzerNodeID = nil
        self.analyzerVolumeInfo = catalog.volumeInfo
        self.analyzerAvailableVolumes = catalog.availableVolumes
        self.isAnalyzing = false
        self.analyzerError = nil

        self.favorites = catalog.favorites
        self.backStack = []
        self.forwardStack = []
        self.browserErrorMessage = nil
        self.currentDirectoryURL = catalog.defaultBrowserDirectoryURL
        self.currentDirectoryCanonicalPath = catalog.defaultBrowserDirectoryURL.standardizedFileURL.path
        self.browserEntries = filteredAndSortedDemoEntries(at: catalog.defaultBrowserDirectoryURL)
        self.focusedBrowserEntryID = catalog.defaultInspectedFileURL.path
        self.selectedBrowserEntryIDs = [catalog.defaultInspectedFileURL.path]
        self.inspectAndPreview(url: catalog.defaultInspectedFileURL)
        self.refreshProtectionFlags(using: currentGuard)
        self.hasInitialized = true
    }

    func demoPathExists(_ path: String) -> Bool {
        demoPathState(path) ?? false
    }

    func demoPathState(_ path: String) -> Bool? {
        let stdURL = URL(fileURLWithPath: path).standardizedFileURL
        let norm = Self.normalizedKey(stdURL.path)
        if demoRemovedPaths.contains(where: { Self.isSameOrDescendant(norm, ofNormalizedBase: $0) }) {
            return false
        }
        if demoDirectories[norm] != nil || demoPreviews[norm] != nil {
            return true
        }
        if demoDirectories.values.contains(where: { entries in
            entries.contains(where: { Self.normalizedKey($0.url.path) == norm })
        }) {
            return true
        }
        var cursorURL = stdURL
        while cursorURL.path != "/" {
            let parentURL = cursorURL.deletingLastPathComponent()
            let parentNorm = Self.normalizedKey(parentURL.path)
            let childNorm = Self.normalizedKey(cursorURL.path)
            if let parentEntries = demoDirectories[parentNorm] {
                if !parentEntries.contains(where: { Self.normalizedKey($0.url.path) == childNorm }) {
                    return false
                }
            }
            if parentURL.path == cursorURL.path {
                break
            }
            cursorURL = parentURL
        }
        if let catalog = demoCatalog, catalog.pathExists(stdURL.path) {
            return true
        }
        return nil
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

    func loadInitialIfNeeded() async {
        if isDemoMode { return }
        refreshVolumesAndFavorites()
        if !hasInitialized {
            hasInitialized = true
            await loadDirectory(currentDirectoryURL, pushHistory: false)
            if analyzerRootNode == nil && !isAnalyzing {
                startSpaceAnalysis(at: analyzerRootURL)
            }
        }
    }

    func refreshVolumesAndFavorites() {
        if isDemoMode {
            if let catalog = demoCatalog {
                analyzerAvailableVolumes = catalog.availableVolumes
                favorites = catalog.favorites
                analyzerVolumeInfo = catalog.volumeInfo
            }
            return
        }
        let guardCopy = currentGuard
        let rootURL = analyzerRootURL
        Task.detached(priority: .utility) { [weak self] in
            let vols = DiskSpaceAnalyzer.mountedVolumes()
            let favs = FileBrowserService(safetyGuard: guardCopy).quickFavorites()
            let rootVol = try? DiskSpaceAnalyzer.volumeInfo(for: rootURL)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.analyzerAvailableVolumes = vols
                self.favorites = favs
                if let rootVol {
                    self.analyzerVolumeInfo = rootVol
                }
            }
        }
    }

    // MARK: - Space Analyzer

    public var currentAnalyzerNode: DiskTreeNode? {
        guard let root = analyzerRootNode else { return nil }
        var current = root
        for id in analyzerBreadcrumbIDs {
            if let next = current.children.first(where: { $0.id == id }) {
                current = next
            } else {
                break
            }
        }
        return current
    }

    var analyzerBreadcrumbs: [DiskTreeNode] {
        guard let root = analyzerRootNode else { return [] }
        var trail: [DiskTreeNode] = [root]
        var current = root
        for id in analyzerBreadcrumbIDs {
            if let next = current.children.first(where: { $0.id == id }) {
                trail.append(next)
                current = next
            } else {
                break
            }
        }
        return trail
    }

    var isAnalyzerFilterActive: Bool {
        analyzerSizePreset != .all
            || analyzerAgePreset != .all
            || !analyzerSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var activeAnalyzerEntryFilter: DiskEntryFilter {
        DiskEntryFilter(
            minBytes: analyzerSizePreset.rawValue,
            olderThanDays: analyzerAgePreset == .all ? nil : analyzerAgePreset.rawValue,
            ageBasis: analyzerAgeBasis,
            scope: .filesAndPackages,
            excludeProtected: false,
            includeHiddenFiles: analyzerIncludeHiddenFiles,
            searchText: analyzerSearchText,
            maxResults: 400
        )
    }

    var selectedAnalyzerSummary: (count: Int, bytes: UInt64) {
        if isAnalyzerFilterActive {
            let selected = analyzerFilteredItems.filter { selectedAnalyzerNodeIDs.contains($0.id) && !$0.isProtected }
            let total = selected.reduce(into: UInt64(0)) { $0 &+= $1.bytes }
            return (selected.count, total)
        } else if let current = currentAnalyzerNode {
            let selected = current.children.filter { selectedAnalyzerNodeIDs.contains($0.id) && !$0.isProtected && !$0.isSymlink }
            let total = selected.reduce(into: UInt64(0)) { $0 &+= $1.bytes }
            return (selected.count, total)
        }
        return (0, 0)
    }

    func startSpaceAnalysis(at rootURL: URL? = nil) {
        let targetURL = (rootURL ?? analyzerRootURL).standardizedFileURL
        analyzerTask?.cancel()
        filterTask?.cancel()
        analyzerGeneration += 1
        let gen = analyzerGeneration

        analyzerRootURL = targetURL
        analyzerError = nil
        scanProgress = nil
        isAnalyzing = true
        selectedAnalyzerNodeIDs.removeAll()
        focusedAnalyzerNodeID = nil

        let includeHidden = analyzerIncludeHiddenFiles

        if isDemoMode, let catalog = demoCatalog {
            analyzerVolumeInfo = catalog.volumeInfo
            let targetNorm = Self.normalizedKey(targetURL.path)
            let matchedNode = demoDiskTreeNode(forNormalizedPath: targetNorm)
            let fallbackRoot = demoHomeDiskTree
                ?? Self.pruningTree(catalog.diskTreeRoot(for: targetURL), removedNormalized: demoRemovedPaths)
            let effectiveRoot = matchedNode ?? fallbackRoot
            let filteredRoot = Self.filteringHiddenTree(effectiveRoot, includeHidden: includeHidden)
            analyzerRootNode = updatingDemoProtection(filteredRoot, using: currentGuard)
            analyzerBreadcrumbIDs = []
            isAnalyzing = false
            scanProgress = nil
            recomputeAnalyzerFilter()
            return
        }

        let guardCopy = currentGuard

        analyzerTask = Task { [weak self] in
            let volInfo = await Task.detached(priority: .userInitiated) {
                try? DiskSpaceAnalyzer.volumeInfo(for: targetURL)
            }.value

            await MainActor.run { [weak self] in
                guard let self, self.analyzerGeneration == gen else { return }
                self.analyzerVolumeInfo = volInfo
            }

            do {
                let analyzer = DiskSpaceAnalyzer(
                    safetyGuard: guardCopy,
                    maxChildrenPerDirectory: 200,
                    progressThrottleInterval: 0.12,
                    includeHiddenFiles: includeHidden
                )
                let tree = try await analyzer.analyze(
                    root: targetURL,
                    maxDepth: 4,
                    onPartialTree: { [weak self] partial in
                        Task { @MainActor [weak self] in
                            guard let self, self.analyzerGeneration == gen, self.isAnalyzing else { return }
                            self.analyzerRootNode = partial
                        }
                    },
                    onProgress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard let self, self.analyzerGeneration == gen, self.isAnalyzing else { return }
                            self.scanProgress = progress
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.analyzerGeneration == gen else { return }
                    self.analyzerRootNode = tree
                    if self.analyzerRootURL != targetURL {
                        self.analyzerBreadcrumbIDs = []
                    }
                    self.isAnalyzing = false
                    self.scanProgress = nil
                    self.recomputeAnalyzerFilter()
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.analyzerGeneration == gen else { return }
                    self.isAnalyzing = false
                    self.scanProgress = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.analyzerGeneration == gen else { return }
                    self.isAnalyzing = false
                    self.scanProgress = nil
                    self.analyzerError = error.localizedDescription
                }
            }
        }
    }

    func cancelSpaceAnalysis() {
        analyzerGeneration += 1
        analyzerTask?.cancel()
        analyzerTask = nil
        isAnalyzing = false
        scanProgress = nil
    }

    public func drillIntoAnalyzerNode(_ node: DiskTreeNode) {
        guard node.isDirectory && !node.isSymlink && node.isAccessible else { return }
        if node.isTruncated && node.children.isEmpty {
            // Depth-capped leaf folder: re-analyze rooted at this directory so user can inspect inside it.
            startSpaceAnalysis(at: node.url)
            return
        }
        analyzerBreadcrumbIDs.append(node.id)
        selectedAnalyzerNodeIDs.removeAll()
        focusedAnalyzerNodeID = nil
        recomputeAnalyzerFilter()
    }

    func navigateAnalyzerBreadcrumb(to nodeID: String) {
        guard let root = analyzerRootNode else { return }
        if nodeID == root.id {
            analyzerBreadcrumbIDs = []
        } else if let idx = analyzerBreadcrumbIDs.firstIndex(of: nodeID) {
            analyzerBreadcrumbIDs = Array(analyzerBreadcrumbIDs.prefix(idx + 1))
        }
        selectedAnalyzerNodeIDs.removeAll()
        focusedAnalyzerNodeID = nil
        recomputeAnalyzerFilter()
    }

    func navigateAnalyzerUp() {
        guard !analyzerBreadcrumbIDs.isEmpty else { return }
        analyzerBreadcrumbIDs.removeLast()
        selectedAnalyzerNodeIDs.removeAll()
        focusedAnalyzerNodeID = nil
        recomputeAnalyzerFilter()
    }

    func toggleAnalyzerSelection(_ nodeID: String) {
        if selectedAnalyzerNodeIDs.contains(nodeID) {
            selectedAnalyzerNodeIDs.remove(nodeID)
        } else {
            selectedAnalyzerNodeIDs.insert(nodeID)
        }
    }

    func focusAnalyzerNode(_ url: URL?, nodeID: String?) {
        focusedAnalyzerNodeID = nodeID
        inspectAndPreview(url: url)
    }

    func recomputeAnalyzerFilter() {
        filterTask?.cancel()
        filterGeneration += 1
        let gen = filterGeneration

        guard isAnalyzerFilterActive, let currentNode = currentAnalyzerNode else {
            analyzerFilteredItems = []
            isFilteringDeep = false
            return
        }

        let filter = activeAnalyzerEntryFilter
        let refDate = isDemoMode ? DemoFixtureCatalog.referenceDate : Date()
        analyzerFilteredItems = DiskSpaceAnalyzer.filterNodes(in: currentNode, filter: filter, referenceDate: refDate)

        if isDemoMode {
            isFilteringDeep = false
            return
        }

        guard currentNode.hasTruncatedDescendant else {
            isFilteringDeep = false
            return
        }

        isFilteringDeep = true
        let targetURL = currentNode.url
        let guardCopy = currentGuard
        let includeHidden = analyzerIncludeHiddenFiles

        filterTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let analyzer = DiskSpaceAnalyzer(safetyGuard: guardCopy, includeHiddenFiles: includeHidden)
                let deepResults = try await analyzer.findMatchingFiles(under: targetURL, filter: filter)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.filterGeneration == gen else { return }
                    self.analyzerFilteredItems = deepResults
                    self.isFilteringDeep = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.filterGeneration == gen else { return }
                    self.isFilteringDeep = false
                }
            }
        }
    }

    public func toggleAnalyzerIncludeHiddenFiles() {
        analyzerIncludeHiddenFiles.toggle()
        startSpaceAnalysis(at: analyzerRootURL)
    }

    func setAnalyzerSizePreset(_ preset: DiskSizeThresholdPreset) {
        analyzerSizePreset = preset
        selectedAnalyzerNodeIDs.removeAll()
        recomputeAnalyzerFilter()
    }

    func setAnalyzerAgePreset(_ preset: DiskAgePreset) {
        analyzerAgePreset = preset
        selectedAnalyzerNodeIDs.removeAll()
        recomputeAnalyzerFilter()
    }

    func setAnalyzerAgeBasis(_ basis: DiskAgeDateBasis) {
        analyzerAgeBasis = basis
        recomputeAnalyzerFilter()
    }

    // MARK: - File Browser Navigation & Listing

    var canGoBack: Bool { !(pendingHistorySnapshot?.backStack ?? backStack).isEmpty }
    var canGoForward: Bool { !(pendingHistorySnapshot?.forwardStack ?? forwardStack).isEmpty }
    var canGoUp: Bool { currentDirectoryURL.path != "/" }

    public var selectedBrowserEntries: [FileBrowserEntry] {
        browserEntries.filter { selectedBrowserEntryIDs.contains($0.id) }
    }

    public var focusedBrowserEntry: FileBrowserEntry? {
        if let focusedID = focusedBrowserEntryID,
           let match = browserEntries.first(where: { $0.id == focusedID }) {
            return match
        }
        if selectedBrowserEntries.count == 1 {
            return selectedBrowserEntries.first
        }
        return nil
    }

    public var selectedBrowserBytes: Int64 {
        selectedBrowserEntries.reduce(0) { $0 + max(0, $1.sizeBytes) }
    }

    var pathBreadcrumbs: [(title: String, url: URL)] {
        let std = currentDirectoryURL.standardizedFileURL
        var items: [(String, URL)] = [("/", URL(fileURLWithPath: "/"))]
        let parts = std.pathComponents.filter { $0 != "/" }
        var running = URL(fileURLWithPath: "/")
        for part in parts {
            running = running.appendingPathComponent(part)
            items.append((SafeFileReader.sanitizeForDisplay(part), running))
        }
        return items
    }

    public func loadDirectory(_ url: URL, pushHistory: Bool = true) async {
        guard let task = scheduleDirectoryLoad(url, transition: pushHistory ? .pushHistory : .none) else { return }
        await task.value
    }

    @discardableResult
    private func scheduleDirectoryLoad(_ url: URL, transition: DirectoryLoadTransition) -> Task<Void, Never>? {
        guard url.isFileURL else { return nil }
        let targetURL = url.standardizedFileURL

        browserTask?.cancel()
        browserGeneration += 1
        let gen = browserGeneration

        switch transition {
        case .none, .pushHistory:
            pendingHistorySnapshot = nil
        case let .commitHistory(snapshot):
            pendingHistorySnapshot = snapshot
        }

        isLoadingDirectory = true
        browserErrorMessage = nil
        browserNeedsFDA = false

        let previousURL = currentDirectoryURL
        let guardCopy = currentGuard
        let hidden = showHiddenFiles
        let sortBy = browserSortBy
        let ascending = browserAscending

        if isDemoMode {
            let entries = filteredAndSortedDemoEntries(at: targetURL)
                .map { updatingDemoProtection($0, using: guardCopy) }
            switch transition {
            case .none:
                pendingHistorySnapshot = nil
            case .pushHistory:
                pendingHistorySnapshot = nil
                if previousURL.path != targetURL.path {
                    backStack.append(previousURL)
                    forwardStack.removeAll()
                }
            case let .commitHistory(snapshot):
                pendingHistorySnapshot = nil
                backStack = snapshot.backStack
                forwardStack = snapshot.forwardStack
            }
            isLoadingDirectory = false
            currentDirectoryURL = targetURL
            currentDirectoryCanonicalPath = targetURL.standardizedFileURL.path
            unfilteredBrowserEntries = entries
            browserEntries = entries
            let validIDs = Set(entries.map(\.id))
            selectedBrowserEntryIDs = selectedBrowserEntryIDs.intersection(validIDs)
            if let focused = focusedBrowserEntryID, !validIDs.contains(focused) {
                focusedBrowserEntryID = nil
            }
            if Self.normalizedKey(targetURL.path) != Self.normalizedKey(previousURL.path) {
                if inspectedURL != nil {
                    inspectAndPreview(url: nil)
                }
            } else if let curInspected = inspectedURL,
                      Self.normalizedKey(curInspected.deletingLastPathComponent().path) == Self.normalizedKey(targetURL.path),
                      !validIDs.contains(curInspected.standardizedFileURL.path) {
                inspectAndPreview(url: nil)
            }
            return nil
        }

        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.browserGeneration == gen else { return }

            let result: Result<(entries: [FileBrowserEntry], canonicalPath: String), Error> = await Task.detached(priority: .userInitiated) {
                if Task.isCancelled {
                    return .failure(CancellationError())
                }
                do {
                    let service = FileBrowserService(safetyGuard: guardCopy)
                    let entries = try service.listDirectory(
                        at: targetURL,
                        showHidden: hidden,
                        sortBy: sortBy,
                        ascending: ascending,
                        searchQuery: ""
                    )
                    let canonical = PrivilegedExecutor.canonicalParentPath(for: targetURL.path)
                    return .success((entries, canonical))
                } catch {
                    return .failure(error)
                }
            }.value

            guard !Task.isCancelled, self.browserGeneration == gen else { return }
            self.isLoadingDirectory = false

            switch result {
            case let .success((entries, canonicalPath)):
                switch transition {
                case .none:
                    self.pendingHistorySnapshot = nil
                case .pushHistory:
                    self.pendingHistorySnapshot = nil
                    if previousURL.path != targetURL.path {
                        self.backStack.append(previousURL)
                        self.forwardStack.removeAll()
                    }
                case let .commitHistory(snapshot):
                    self.pendingHistorySnapshot = nil
                    self.backStack = snapshot.backStack
                    self.forwardStack = snapshot.forwardStack
                }
                self.currentDirectoryURL = targetURL
                self.currentDirectoryCanonicalPath = canonicalPath
                self.unfilteredBrowserEntries = entries
                self.applyInMemoryBrowserFilterAndSort()
                let validIDs = Set(self.browserEntries.map(\.id))
                if Self.normalizedKey(targetURL.path) != Self.normalizedKey(previousURL.path) {
                    if self.inspectedURL != nil {
                        self.inspectAndPreview(url: nil)
                    }
                } else if let curInspected = self.inspectedURL,
                          Self.normalizedKey(curInspected.deletingLastPathComponent().path) == Self.normalizedKey(targetURL.path),
                          !validIDs.contains(curInspected.standardizedFileURL.path) {
                    self.inspectAndPreview(url: nil)
                }
            case let .failure(err):
                self.pendingHistorySnapshot = nil
                if let fbErr = err as? FileBrowserError {
                    switch fbErr {
                    case let .tccOrPermissionDenied(_, needsFDA):
                        self.browserErrorMessage = self.l10n.folderPermissionDenied
                        self.browserNeedsFDA = needsFDA && !(self.appState?.hasFullDiskAccess ?? false)
                    default:
                        self.browserErrorMessage = fbErr.localizedDescription
                        self.browserNeedsFDA = false
                    }
                } else {
                    self.browserErrorMessage = err.localizedDescription
                    self.browserNeedsFDA = false
                }
            }
        }
        browserTask = task
        return task
    }

    func goBack() {
        var state = pendingHistorySnapshot ?? HistoryStateSnapshot(
            currentDirectoryURL: currentDirectoryURL,
            backStack: backStack,
            forwardStack: forwardStack
        )
        guard let prev = state.backStack.popLast() else { return }
        state.forwardStack.append(state.currentDirectoryURL)
        state.currentDirectoryURL = prev.standardizedFileURL
        scheduleDirectoryLoad(prev, transition: .commitHistory(state))
    }

    func goForward() {
        var state = pendingHistorySnapshot ?? HistoryStateSnapshot(
            currentDirectoryURL: currentDirectoryURL,
            backStack: backStack,
            forwardStack: forwardStack
        )
        guard let next = state.forwardStack.popLast() else { return }
        state.backStack.append(state.currentDirectoryURL)
        state.currentDirectoryURL = next.standardizedFileURL
        scheduleDirectoryLoad(next, transition: .commitHistory(state))
    }

    public func goUp() {
        guard canGoUp else { return }
        let parent = currentDirectoryURL.deletingLastPathComponent()
        scheduleDirectoryLoad(parent, transition: .pushHistory)
    }

    func refreshCurrentDirectory() {
        scheduleDirectoryLoad(currentDirectoryURL, transition: .none)
    }

    func toggleShowHiddenFiles() {
        showHiddenFiles.toggle()
        refreshCurrentDirectory()
    }

    public func updateBrowserSearchText(_ newText: String) {
        browserSearchText = newText
        applyInMemoryBrowserFilterAndSort()
    }

    private func applyInMemoryBrowserFilterAndSort() {
        let updated: [FileBrowserEntry]
        if isDemoMode {
            let guardCopy = currentGuard
            updated = filteredAndSortedDemoEntries(at: currentDirectoryURL)
                .map { updatingDemoProtection($0, using: guardCopy) }
        } else {
            let query = browserSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let filtered = query.isEmpty
                ? unfilteredBrowserEntries
                : unfilteredBrowserEntries.filter { $0.name.localizedCaseInsensitiveContains(query) }
            updated = FileBrowserService.sortEntries(filtered, by: browserSortBy, ascending: browserAscending)
        }
        browserEntries = updated
        let validIDs = Set(updated.map(\.id))
        selectedBrowserEntryIDs = selectedBrowserEntryIDs.intersection(validIDs)
        if let focused = focusedBrowserEntryID, !validIDs.contains(focused) {
            focusedBrowserEntryID = nil
        }
    }

    func setBrowserSort(by sortBy: FileBrowserSort, ascending: Bool? = nil) {
        if browserSortBy == sortBy && ascending == nil {
            browserAscending.toggle()
        } else {
            browserSortBy = sortBy
            if let ascending {
                browserAscending = ascending
            } else {
                browserAscending = (sortBy == .name || sortBy == .kind)
            }
        }
        applyInMemoryBrowserFilterAndSort()
    }

    func toggleBrowserSelection(_ entry: FileBrowserEntry, additive: Bool = true) {
        if entry.isProtected || entry.isSIPRestricted {
            if !additive {
                selectedBrowserEntryIDs = []
            }
            focusedBrowserEntryID = entry.id
            inspectAndPreview(url: entry.url)
            return
        }
        if additive {
            if selectedBrowserEntryIDs.contains(entry.id) {
                selectedBrowserEntryIDs.remove(entry.id)
            } else {
                selectedBrowserEntryIDs.insert(entry.id)
            }
        } else {
            selectedBrowserEntryIDs = [entry.id]
        }
        focusedBrowserEntryID = entry.id
        inspectAndPreview(url: entry.url)
    }

    public func selectSingleBrowserEntry(_ entry: FileBrowserEntry) {
        if entry.isProtected || entry.isSIPRestricted {
            selectedBrowserEntryIDs = []
        } else {
            selectedBrowserEntryIDs = [entry.id]
        }
        focusedBrowserEntryID = entry.id
        inspectAndPreview(url: entry.url)
    }

    func openBrowserEntry(_ entry: FileBrowserEntry) {
        if entry.isDirectory && !entry.isPackage && !entry.isSymbolicLink {
            scheduleDirectoryLoad(entry.url, transition: .pushHistory)
        }
    }

    // MARK: - File Operations (Create Folder, Rename, Move)

    public func createFolder(named rawName: String) async -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try FileOperationsEngine.validateItemName(name)
        } catch {
            return l10n.invalidFileNameError(name)
        }

        isPerformingFileOp = true
        let guardCopy = currentGuard
        let parentURL = currentDirectoryURL
        let expectedParent = currentDirectoryCanonicalPath

        if isDemoMode {
            let parentStd = parentURL.standardizedFileURL
            let parentNorm = Self.normalizedKey(parentStd.path)
            let createdURL = parentStd.appendingPathComponent(name).standardizedFileURL
            let createdNorm = Self.normalizedKey(createdURL.path)

            if case let .blocked(reason) = guardCopy.validateDirectoryCreation(at: createdURL) {
                isPerformingFileOp = false
                return reason
            }
            let dstProt = demoProtectionStatus(for: createdURL, using: guardCopy)
            if dstProt.isProtected {
                isPerformingFileOp = false
                return dstProt.reason ?? l10n.fileOperationBlockedTitle
            }
            guard isExistingDemoDirectory(parentStd) else {
                isPerformingFileOp = false
                return l10n.fileOperationBlockedTitle
            }

            var parentEntries = demoAllEntries(at: parentStd)
            if demoPathState(createdURL.path) == true
                || parentEntries.contains(where: { Self.normalizedKey($0.url.path) == createdNorm }) {
                isPerformingFileOp = false
                return l10n.t("目标文件夹已存在同名项目。", "An item with that name already exists.")
            }
            let newEntry = FileBrowserEntry(
                url: createdURL,
                name: name,
                kind: .directory,
                sizeBytes: 0,
                modificationDate: DemoFixtureCatalog.referenceDate,
                createdDate: DemoFixtureCatalog.referenceDate,
                isDirectory: true,
                isPackage: false,
                isSymbolicLink: false,
                isSymlinkBroken: false,
                isHidden: name.hasPrefix("."),
                isDataless: false,
                isUserImmutable: false,
                isSIPRestricted: false,
                isProtected: false,
                protectionReason: nil,
                requiresAdmin: false,
                utiIdentifier: "public.folder",
                kindDescription: "Folder",
                expectedCanonicalParent: parentStd.path
            )
            parentEntries.append(newEntry)
            demoDirectories[parentNorm] = parentEntries
            demoDirectories[createdNorm] = []
            demoPreviews[createdNorm] = Self.synthesizedPreviewPayload(for: newEntry)
            demoRemovedPaths = demoRemovedPaths.filter { !Self.isSameOrDescendant($0, ofNormalizedBase: createdNorm) }
            insertDemoDiskTreeNode(Self.makeDiskTreeNode(from: newEntry), intoParentNormalized: parentNorm)
            syncAnalyzerWithDemoTrees()
            isPerformingFileOp = false
            await loadDirectory(parentURL, pushHistory: false)
            selectedBrowserEntryIDs = [createdURL.path]
            focusedBrowserEntryID = createdURL.path
            inspectAndPreview(url: createdURL)
            appState?.banner = OperationBanner(
                isError: false,
                message: l10n.folderCreatedMessage(name),
                showAppManagementLink: false,
                showFDALink: false
            )
            return nil
        }

        let res: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let engine = FileOperationsEngine(safetyGuard: guardCopy)
                let created = try await engine.createDirectory(
                    named: name,
                    in: parentURL,
                    expectedParentCanonicalParent: expectedParent
                )
                return .success(created)
            } catch {
                return .failure(error)
            }
        }.value

        isPerformingFileOp = false
        switch res {
        case let .success(createdURL):
            await loadDirectory(parentURL, pushHistory: false)
            selectedBrowserEntryIDs = [createdURL.standardizedFileURL.path]
            focusedBrowserEntryID = createdURL.standardizedFileURL.path
            inspectAndPreview(url: createdURL)
            appState?.banner = OperationBanner(
                isError: false,
                message: l10n.folderCreatedMessage(name),
                showAppManagementLink: false,
                showFDALink: false
            )
            return nil
        case let .failure(err):
            return err.localizedDescription
        }
    }

    public func renameEntry(_ entry: FileBrowserEntry, to rawNewName: String) async -> String? {
        guard !entry.isMutationLocked else {
            return l10n.fileOperationBlockedTitle
        }
        let newName = rawNewName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try FileOperationsEngine.validateItemName(newName)
        } catch {
            return l10n.invalidFileNameError(newName)
        }

        isPerformingFileOp = true
        let guardCopy = currentGuard
        let srcURL = entry.url
        let expectedParent = entry.expectedCanonicalParent
        let sizerRef = appState?.sizer

        if isDemoMode {
            let srcStd = entry.url.standardizedFileURL
            let parentStd = srcStd.deletingLastPathComponent().standardizedFileURL
            let parentPath = parentStd.path
            let parentNorm = Self.normalizedKey(parentPath)
            let renamedURL = parentStd.appendingPathComponent(newName).standardizedFileURL
            let renamedNorm = Self.normalizedKey(renamedURL.path)
            let entryNorm = Self.normalizedKey(srcStd.path)

            guard demoPathState(srcStd.path) == true else {
                isPerformingFileOp = false
                return l10n.fileOperationBlockedTitle
            }
            if entry.name == newName {
                isPerformingFileOp = false
                return l10n.t("目标文件夹已存在同名项目。", "An item with that name already exists.")
            }
            if case let .blocked(reason) = guardCopy.validateForMoveOrRename(source: srcStd, destination: renamedURL) {
                isPerformingFileOp = false
                return reason
            }
            let srcProt = demoProtectionStatus(for: srcStd, using: guardCopy)
            if srcProt.isProtected {
                isPerformingFileOp = false
                return srcProt.reason ?? l10n.fileOperationBlockedTitle
            }
            let dstProt = demoProtectionStatus(for: renamedURL, using: guardCopy)
            if dstProt.isProtected {
                isPerformingFileOp = false
                return dstProt.reason ?? l10n.fileOperationBlockedTitle
            }

            var list = demoAllEntries(at: parentStd)
            if (demoPathState(renamedURL.path) == true && renamedNorm != entryNorm)
                || list.contains(where: {
                    let candidateNorm = Self.normalizedKey($0.url.path)
                    return candidateNorm == renamedNorm && candidateNorm != entryNorm
                }) {
                isPerformingFileOp = false
                return l10n.t("目标文件夹已存在同名项目。", "An item with that name already exists.")
            }
            guard let idx = list.firstIndex(where: { $0.id == entry.id || Self.normalizedKey($0.url.path) == entryNorm }) else {
                isPerformingFileOp = false
                return l10n.fileOperationBlockedTitle
            }
            let old = list[idx]
            let updatedEntry = FileBrowserEntry(
                url: renamedURL,
                name: newName,
                kind: old.kind,
                sizeBytes: old.sizeBytes,
                modificationDate: DemoFixtureCatalog.referenceDate,
                createdDate: old.createdDate,
                isDirectory: old.isDirectory,
                isPackage: old.isPackage,
                isSymbolicLink: old.isSymbolicLink,
                isSymlinkBroken: old.isSymlinkBroken,
                isHidden: newName.hasPrefix("."),
                isDataless: old.isDataless,
                isUserImmutable: old.isUserImmutable,
                isSIPRestricted: old.isSIPRestricted,
                isProtected: old.isProtected,
                protectionReason: old.protectionReason,
                requiresAdmin: old.requiresAdmin,
                utiIdentifier: old.utiIdentifier,
                kindDescription: old.kindDescription,
                expectedCanonicalParent: parentPath
            )
            list[idx] = updatedEntry
            demoDirectories[parentNorm] = list
            migrateDemoSubtree(
                from: old.url,
                to: renamedURL,
                newName: newName,
                isDirectory: old.isDirectory && !old.isSymbolicLink,
                sourceEntry: old
            )
            renameDemoDiskTreeNode(
                from: old.url,
                to: renamedURL,
                newName: newName,
                fallbackEntry: updatedEntry
            )
            syncAnalyzerWithDemoTrees()
            isPerformingFileOp = false
            await loadDirectory(currentDirectoryURL, pushHistory: false)
            selectedBrowserEntryIDs = [renamedURL.path]
            focusedBrowserEntryID = renamedURL.path
            inspectAndPreview(url: renamedURL)
            appState?.banner = OperationBanner(
                isError: false,
                message: l10n.itemRenamedMessage(newName),
                showAppManagementLink: false,
                showFDALink: false
            )
            return nil
        }

        let res: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let engine = FileOperationsEngine(safetyGuard: guardCopy)
                let renamed = try await engine.renameItem(
                    at: srcURL,
                    toNewName: newName,
                    expectedSourceCanonicalParent: expectedParent
                )
                return .success(renamed)
            } catch {
                return .failure(error)
            }
        }.value

        isPerformingFileOp = false
        switch res {
        case let .success(renamedURL):
            if let sizerRef {
                Task { await sizerRef.invalidate(path: srcURL.path) }
            }
            await loadDirectory(currentDirectoryURL, pushHistory: false)
            selectedBrowserEntryIDs = [renamedURL.standardizedFileURL.path]
            focusedBrowserEntryID = renamedURL.standardizedFileURL.path
            inspectAndPreview(url: renamedURL)
            appState?.banner = OperationBanner(
                isError: false,
                message: l10n.itemRenamedMessage(newName),
                showAppManagementLink: false,
                showFDALink: false
            )
            return nil
        case let .failure(err):
            return err.localizedDescription
        }
    }

    public func moveEntries(_ entries: [FileBrowserEntry], to destinationDirectory: URL) async {
        let movable = entries.filter { !$0.isMutationLocked }
        guard !movable.isEmpty else {
            appState?.banner = OperationBanner(
                isError: true,
                message: l10n.fileOperationBlockedTitle,
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }

        let dstStd = destinationDirectory.standardizedFileURL
        let guardCopy = currentGuard
        if isDemoMode {
            guard destinationDirectory.isFileURL,
                  !destinationDirectory.path.isEmpty,
                  !destinationDirectory.path.contains("\0"),
                  !destinationDirectory.pathComponents.contains(".."),
                  !destinationDirectory.path.split(separator: "/").contains("..") else {
                appState?.banner = OperationBanner(
                    isError: true,
                    message: l10n.fileOperationBlockedTitle,
                    showAppManagementLink: false,
                    showFDALink: false
                )
                return
            }

            let probeSrc = URL(fileURLWithPath: "/Users/alex/.macsweep_demo_probe")
            let probeDst = dstStd.appendingPathComponent(".macsweep_demo_probe").standardizedFileURL
            if case let .blocked(reason) = guardCopy.validateForMoveOrRename(source: probeSrc, destination: probeDst) {
                appState?.banner = OperationBanner(
                    isError: true,
                    message: reason,
                    showAppManagementLink: false,
                    showFDALink: false
                )
                return
            }
            let dstDirProt = demoProtectionStatus(for: probeDst, using: guardCopy)
            if dstDirProt.isProtected {
                appState?.banner = OperationBanner(
                    isError: true,
                    message: dstDirProt.reason ?? l10n.fileOperationBlockedTitle,
                    showAppManagementLink: false,
                    showFDALink: false
                )
                return
            }
            guard isExistingDemoDirectory(dstStd) else {
                appState?.banner = OperationBanner(
                    isError: true,
                    message: l10n.fileOperationBlockedTitle,
                    showAppManagementLink: false,
                    showFDALink: false
                )
                return
            }

            let srcStdDir = currentDirectoryURL.standardizedFileURL
            let srcNorm = Self.normalizedKey(srcStdDir.path)
            let dstNorm = Self.normalizedKey(dstStd.path)
            guard dstNorm != srcNorm else { return }

            var dstList = demoAllEntries(at: dstStd)
            var movedCount = 0
            var movedSources: [URL] = []
            var firstError: String?

            for item in movable {
                let srcStd = item.url.standardizedFileURL
                let itemSrcNorm = Self.normalizedKey(srcStd.path)
                let itemParentStd = srcStd.deletingLastPathComponent().standardizedFileURL
                let itemParentNorm = Self.normalizedKey(itemParentStd.path)

                guard itemParentNorm != dstNorm else { continue }
                guard demoPathState(srcStd.path) == true else {
                    if firstError == nil {
                        firstError = l10n.fileOperationBlockedTitle
                    }
                    continue
                }
                if item.isDirectory && !item.isSymbolicLink && Self.isSameOrDescendant(dstNorm, ofNormalizedBase: itemSrcNorm) {
                    if firstError == nil {
                        firstError = "Cannot move a directory into itself"
                    }
                    continue
                }
                let dstURL = dstStd.appendingPathComponent(item.name).standardizedFileURL
                let dstItemNorm = Self.normalizedKey(dstURL.path)

                if case let .blocked(reason) = guardCopy.validateForMoveOrRename(source: srcStd, destination: dstURL) {
                    if firstError == nil {
                        firstError = reason
                    }
                    continue
                }
                let srcProt = demoProtectionStatus(for: srcStd, using: guardCopy)
                if srcProt.isProtected {
                    if firstError == nil {
                        firstError = srcProt.reason ?? l10n.fileOperationBlockedTitle
                    }
                    continue
                }
                let dstItemProt = demoProtectionStatus(for: dstURL, using: guardCopy)
                if dstItemProt.isProtected {
                    if firstError == nil {
                        firstError = dstItemProt.reason ?? l10n.fileOperationBlockedTitle
                    }
                    continue
                }
                if demoPathState(dstURL.path) == true
                    || dstList.contains(where: { Self.normalizedKey($0.url.path) == dstItemNorm }) {
                    if firstError == nil {
                        firstError = l10n.t("目标文件夹已存在同名项目：\(item.name)", "Destination already exists: \(item.name)")
                    }
                    continue
                }

                var itemParentList = demoAllEntries(at: itemParentStd)
                itemParentList.removeAll { Self.normalizedKey($0.url.path) == itemSrcNorm }
                demoDirectories[itemParentNorm] = itemParentList

                let movedEntry = FileBrowserEntry(
                    url: dstURL,
                    name: item.name,
                    kind: item.kind,
                    sizeBytes: item.sizeBytes,
                    modificationDate: item.modificationDate,
                    createdDate: item.createdDate,
                    isDirectory: item.isDirectory,
                    isPackage: item.isPackage,
                    isSymbolicLink: item.isSymbolicLink,
                    isSymlinkBroken: item.isSymlinkBroken,
                    isHidden: item.isHidden,
                    isDataless: item.isDataless,
                    isUserImmutable: item.isUserImmutable,
                    isSIPRestricted: item.isSIPRestricted,
                    isProtected: item.isProtected,
                    protectionReason: item.protectionReason,
                    requiresAdmin: item.requiresAdmin,
                    utiIdentifier: item.utiIdentifier,
                    kindDescription: item.kindDescription,
                    expectedCanonicalParent: dstStd.path
                )
                dstList.append(movedEntry)
                migrateDemoSubtree(
                    from: srcStd,
                    to: dstURL,
                    newName: item.name,
                    isDirectory: item.isDirectory && !item.isSymbolicLink,
                    sourceEntry: item
                )
                moveDemoDiskTreeNode(
                    from: srcStd,
                    to: dstURL,
                    newName: item.name,
                    fallbackEntry: movedEntry
                )
                movedCount += 1
                movedSources.append(srcStd)
            }

            if movedCount > 0 {
                demoDirectories[dstNorm] = dstList
                syncAnalyzerWithDemoTrees()
                if let curInspected = inspectedURL {
                    let curNorm = Self.normalizedKey(curInspected.path)
                    if movedSources.contains(where: { Self.isSameOrDescendant(curNorm, ofNormalizedBase: Self.normalizedKey($0.path)) }) {
                        inspectAndPreview(url: nil)
                    }
                }
                await loadDirectory(currentDirectoryURL, pushHistory: false)
            }

            if movedCount > 0 && firstError == nil {
                appState?.banner = OperationBanner(
                    isError: false,
                    message: l10n.itemsMovedMessage(count: movedCount, destination: dstStd.lastPathComponent),
                    showAppManagementLink: false,
                    showFDALink: false
                )
            } else if let firstError {
                let prefix = movedCount > 0
                    ? "\(l10n.itemsMovedMessage(count: movedCount, destination: dstStd.lastPathComponent)); "
                    : ""
                appState?.banner = OperationBanner(
                    isError: true,
                    message: "\(prefix)\(firstError)",
                    showAppManagementLink: false,
                    showFDALink: false
                )
            } else if movedCount == 0 {
                appState?.banner = OperationBanner(
                    isError: true,
                    message: l10n.fileOperationBlockedTitle,
                    showAppManagementLink: false,
                    showFDALink: false
                )
            }
            return
        }
        let dstCanonical = PrivilegedExecutor.canonicalParentPath(for: dstStd.path)
        let sizerRef = appState?.sizer
        isPerformingFileOp = true

        let outcome: (movedCount: Int, movedSources: [URL], firstError: String?) = await Task.detached(priority: .userInitiated) {
            let engine = FileOperationsEngine(safetyGuard: guardCopy)
            var count = 0
            var movedSrcs: [URL] = []
            var firstErr: String?
            for item in movable {
                do {
                    _ = try await engine.moveItem(
                        from: item.url,
                        to: dstStd,
                        expectedSourceCanonicalParent: item.expectedCanonicalParent,
                        expectedDestinationCanonicalParent: dstCanonical
                    )
                    count += 1
                    movedSrcs.append(item.url.standardizedFileURL)
                    if let sizerRef {
                        await sizerRef.invalidate(path: item.url.path)
                    }
                } catch {
                    if firstErr == nil {
                        firstErr = error.localizedDescription
                    }
                }
            }
            return (count, movedSrcs, firstErr)
        }.value

        isPerformingFileOp = false
        if !outcome.movedSources.isEmpty, let curInspected = inspectedURL {
            let curNorm = Self.normalizedKey(curInspected.path)
            if outcome.movedSources.contains(where: { Self.isSameOrDescendant(curNorm, ofNormalizedBase: Self.normalizedKey($0.path)) }) {
                inspectAndPreview(url: nil)
            }
        }
        await loadDirectory(currentDirectoryURL, pushHistory: false)

        if outcome.movedCount > 0 && outcome.firstError == nil {
            appState?.banner = OperationBanner(
                isError: false,
                message: l10n.itemsMovedMessage(count: outcome.movedCount, destination: dstStd.lastPathComponent),
                showAppManagementLink: false,
                showFDALink: false
            )
        } else if let firstError = outcome.firstError {
            let prefix = outcome.movedCount > 0
                ? "\(l10n.itemsMovedMessage(count: outcome.movedCount, destination: dstStd.lastPathComponent)); "
                : ""
            appState?.banner = OperationBanner(
                isError: true,
                message: "\(prefix)\(firstError)",
                showAppManagementLink: false,
                showFDALink: false
            )
        }
    }

    // MARK: - Deletion (Strictly via ConfirmationSheet + RemovalEngine) & Protection

    public func requestRemovalForAnalyzerSelection(preferredMode: RemovalMode? = nil) {
        guard let appState else { return }
        let items: [(url: URL, size: Int64, requiresAdmin: Bool, expectedCanonicalParent: String)]

        let isDemo = appState.isDemoMode
        if isAnalyzerFilterActive {
            let selected = analyzerFilteredItems.filter { selectedAnalyzerNodeIDs.contains($0.id) && !$0.isProtected }
            items = selected.map { item in
                (
                    url: item.url,
                    size: Int64(min(item.bytes, UInt64(Int64.max))),
                    requiresAdmin: isDemo ? Self.demoRequiresAdmin(for: item.url) : currentGuard.requiresAdmin(for: item.url),
                    expectedCanonicalParent: item.expectedCanonicalParent
                )
            }
        } else if let current = currentAnalyzerNode {
            let selected = current.children.filter { selectedAnalyzerNodeIDs.contains($0.id) && !$0.isProtected && !$0.isSymlink }
            items = selected.map { node in
                (
                    url: node.url,
                    size: Int64(min(node.bytes, UInt64(Int64.max))),
                    requiresAdmin: isDemo ? Self.demoRequiresAdmin(for: node.url) : currentGuard.requiresAdmin(for: node.url),
                    expectedCanonicalParent: node.expectedCanonicalParent
                )
            }
        } else {
            items = []
        }

        guard !items.isEmpty else {
            appState.banner = OperationBanner(
                isError: true,
                message: l10n.fileOperationBlockedTitle,
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }
        let title = items.count == 1
            ? items[0].url.lastPathComponent
            : (l10n.isChinese ? "清理 \(items.count) 个文件/文件夹" : "Clean \(items.count) items")
        appState.prepareRemovalForFileManagerItems(
            items,
            title: title,
            preferredRemovalModeOverride: preferredMode
        )
    }

    func requestRemovalForBrowserSelection(
        entries explicitEntries: [FileBrowserEntry]? = nil,
        preferredMode: RemovalMode? = nil
    ) {
        guard let appState else { return }
        let candidates = explicitEntries ?? selectedBrowserEntries
        let removable = candidates.filter { !$0.isProtected && !$0.isSIPRestricted }
        guard !removable.isEmpty else {
            appState.banner = OperationBanner(
                isError: true,
                message: l10n.fileOperationBlockedTitle,
                showAppManagementLink: false,
                showFDALink: false
            )
            return
        }

        let items = removable.map { entry in
            (
                url: entry.url,
                size: max(0, entry.sizeBytes),
                requiresAdmin: entry.requiresAdmin,
                expectedCanonicalParent: entry.expectedCanonicalParent
            )
        }
        let title = items.count == 1
            ? removable[0].name
            : (l10n.isChinese ? "移除 \(items.count) 个项目" : "Remove \(items.count) items")
        appState.prepareRemovalForFileManagerItems(
            items,
            title: title,
            preferredRemovalModeOverride: preferredMode
        )
    }

    public func protectURLs(_ urls: [URL]) {
        guard let appState, !urls.isEmpty else { return }
        if urls.count == 1, let single = urls.first {
            let result = appState.addProtectedPath(single.path)
            switch result {
            case .added:
                appState.banner = OperationBanner(
                    isError: false,
                    message: l10n.protectedAddedMessage(single.lastPathComponent),
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
        } else {
            let saved = appState.addProtectedPaths(urls: urls)
            appState.banner = OperationBanner(
                isError: !saved,
                message: saved
                    ? l10n.protectedAddedMessage("\(urls.count)")
                    : l10n.preferencesSaveFailedWarning,
                showAppManagementLink: false,
                showFDALink: false
            )
        }
    }

    // MARK: - Sync Hooks from AppState

    public func refreshProtectionFlags(using safetyGuard: SafetyGuard) {
        if isDemoMode {
            browserEntries = browserEntries.map { updatingDemoProtection($0, using: safetyGuard) }
            let protectedBrowserIDs = Set(browserEntries.filter(\.isProtected).map(\.id))
            selectedBrowserEntryIDs.subtract(protectedBrowserIDs)

            if let root = analyzerRootNode {
                analyzerRootNode = updatingDemoProtection(root, using: safetyGuard)
            }
            if !analyzerFilteredItems.isEmpty {
                analyzerFilteredItems = analyzerFilteredItems.map { item in
                    let prot = demoProtectionStatus(for: item.url, using: safetyGuard).isProtected
                    return DiskFilteredItem(
                        url: item.url,
                        name: item.name,
                        isDirectory: item.isDirectory,
                        isPackage: item.isPackage,
                        bytes: item.bytes,
                        modificationDate: item.modificationDate,
                        accessDate: item.accessDate,
                        expectedCanonicalParent: item.expectedCanonicalParent,
                        isProtected: prot,
                        isUserImmutable: item.isUserImmutable,
                        isHidden: item.isHidden,
                        relativePathFromRoot: item.relativePathFromRoot
                    )
                }
            }
            pruneProtectedAnalyzerSelection()
            if let inspectedURL {
                let status = demoProtectionStatus(for: inspectedURL, using: safetyGuard)
                isInspectedURLProtected = status.isProtected
                inspectedProtectionReason = status.reason
            }
            return
        }

        unfilteredBrowserEntries = unfilteredBrowserEntries.map { $0.updatingProtection(using: safetyGuard) }
        browserEntries = browserEntries.map { $0.updatingProtection(using: safetyGuard) }
        let protectedBrowserIDs = Set(browserEntries.filter(\.isProtected).map(\.id))
        selectedBrowserEntryIDs.subtract(protectedBrowserIDs)

        if let root = analyzerRootNode {
            analyzerRootNode = root.updatingProtection(using: safetyGuard)
        }
        if !analyzerFilteredItems.isEmpty {
            analyzerFilteredItems = analyzerFilteredItems.map { item in
                let prot = !safetyGuard.validateForRemoval(item.url).isAllowed
                return DiskFilteredItem(
                    url: item.url,
                    name: item.name,
                    isDirectory: item.isDirectory,
                    isPackage: item.isPackage,
                    bytes: item.bytes,
                    modificationDate: item.modificationDate,
                    accessDate: item.accessDate,
                    expectedCanonicalParent: item.expectedCanonicalParent,
                    isProtected: prot,
                    isUserImmutable: item.isUserImmutable,
                    isHidden: item.isHidden,
                    relativePathFromRoot: item.relativePathFromRoot
                )
            }
        }
        pruneProtectedAnalyzerSelection()
        if let inspectedURL {
            let res = safetyGuard.validateForRemoval(inspectedURL)
            switch res {
            case .allowed:
                isInspectedURLProtected = false
                inspectedProtectionReason = nil
            case let .blocked(reason):
                isInspectedURLProtected = true
                inspectedProtectionReason = reason
            }
        }
    }

    private func pruneProtectedAnalyzerSelection() {
        var protectedIDs = Set<String>()
        if isAnalyzerFilterActive {
            protectedIDs.formUnion(analyzerFilteredItems.filter(\.isProtected).map(\.id))
        } else if let current = currentAnalyzerNode {
            protectedIDs.formUnion(current.children.filter(\.isProtected).map(\.id))
        }
        if !protectedIDs.isEmpty {
            selectedAnalyzerNodeIDs.subtract(protectedIDs)
        }
    }

    public func applyIncrementalRemoval(removedPaths normalizedRemoved: Set<String>) {
        guard !normalizedRemoved.isEmpty else { return }
        let removedNorm = Set(normalizedRemoved.map(Self.normalizedKey))

        if isDemoMode {
            let newlyRemoved = removedNorm.filter { candidate in
                !demoRemovedPaths.contains(where: { Self.isSameOrDescendant(candidate, ofNormalizedBase: $0) })
            }
            let minimalNewlyRemoved = newlyRemoved.filter { candidate in
                !newlyRemoved.contains(where: { other in
                    other != candidate && Self.isSameOrDescendant(candidate, ofNormalizedBase: other)
                })
            }

            for targetNorm in minimalNewlyRemoved {
                guard demoDiskTreeNode(forNormalizedPath: targetNorm) == nil else {
                    continue
                }
                let parentURL = URL(fileURLWithPath: targetNorm).deletingLastPathComponent().standardizedFileURL
                let parentNorm = Self.normalizedKey(parentURL.path)
                guard parentNorm != targetNorm,
                      demoDiskTreeNode(forNormalizedPath: parentNorm) != nil else {
                    continue
                }
                if let entry = demoAllEntries(at: parentURL).first(where: { Self.normalizedKey($0.url.path) == targetNorm }) {
                    let contribution = Self.aggregateContribution(for: entry)
                    deductDemoAggregate(
                        bytes: contribution.bytes,
                        fileCount: contribution.fileCount,
                        folderCount: contribution.folderCount,
                        fromParentNormalized: parentNorm
                    )
                }
            }

            demoRemovedPaths.formUnion(removedNorm)
            for dirKey in Array(demoDirectories.keys) {
                if removedNorm.contains(where: { Self.isSameOrDescendant(dirKey, ofNormalizedBase: $0) }) {
                    demoDirectories.removeValue(forKey: dirKey)
                } else if let list = demoDirectories[dirKey] {
                    demoDirectories[dirKey] = list.filter { entry in
                        let entryNorm = Self.normalizedKey(entry.url.path)
                        return !removedNorm.contains(where: { Self.isSameOrDescendant(entryNorm, ofNormalizedBase: $0) })
                    }
                }
            }
            for key in Array(demoPreviews.keys) {
                if removedNorm.contains(where: { Self.isSameOrDescendant(key, ofNormalizedBase: $0) }) {
                    demoPreviews.removeValue(forKey: key)
                }
            }
            for key in Array(demoBundleIDsByPath.keys) {
                if removedNorm.contains(where: { Self.isSameOrDescendant(key, ofNormalizedBase: $0) }) {
                    demoBundleIDsByPath.removeValue(forKey: key)
                }
            }
            if let homeTree = demoHomeDiskTree {
                let homeNorm = Self.normalizedKey(homeTree.url.path)
                if removedNorm.contains(where: { Self.isSameOrDescendant(homeNorm, ofNormalizedBase: $0) }) {
                    demoHomeDiskTree = nil
                } else {
                    demoHomeDiskTree = Self.pruningTree(homeTree, removedNormalized: removedNorm)
                }
            }
            if let appsTree = demoAppsDiskTree {
                let appsNorm = Self.normalizedKey(appsTree.url.path)
                if removedNorm.contains(where: { Self.isSameOrDescendant(appsNorm, ofNormalizedBase: $0) }) {
                    demoAppsDiskTree = nil
                } else {
                    demoAppsDiskTree = Self.pruningTree(appsTree, removedNormalized: removedNorm)
                }
            }
        }

        unfilteredBrowserEntries.removeAll { entry in
            let entryNorm = Self.normalizedKey(entry.url.path)
            return removedNorm.contains(where: { Self.isSameOrDescendant(entryNorm, ofNormalizedBase: $0) })
        }
        browserEntries.removeAll { entry in
            let entryNorm = Self.normalizedKey(entry.url.path)
            return removedNorm.contains(where: { Self.isSameOrDescendant(entryNorm, ofNormalizedBase: $0) })
        }
        selectedBrowserEntryIDs = Set(browserEntries.map(\.id)).intersection(selectedBrowserEntryIDs)
        if let focused = focusedBrowserEntryID, !browserEntries.contains(where: { $0.id == focused }) {
            focusedBrowserEntryID = nil
        }

        analyzerFilteredItems.removeAll { item in
            let itemNorm = Self.normalizedKey(item.url.path)
            return removedNorm.contains(where: { Self.isSameOrDescendant(itemNorm, ofNormalizedBase: $0) })
        }
        selectedAnalyzerNodeIDs = selectedAnalyzerNodeIDs.filter { id in
            let idNorm = Self.normalizedKey(id)
            return !removedNorm.contains(where: { Self.isSameOrDescendant(idNorm, ofNormalizedBase: $0) })
        }
        if let focusedA = focusedAnalyzerNodeID,
           removedNorm.contains(where: { Self.isSameOrDescendant(Self.normalizedKey(focusedA), ofNormalizedBase: $0) }) {
            focusedAnalyzerNodeID = nil
        }

        if let inspectedURL,
           removedNorm.contains(where: { Self.isSameOrDescendant(Self.normalizedKey(inspectedURL.path), ofNormalizedBase: $0) }) {
            inspectAndPreview(url: nil)
        }

        if isDemoMode {
            syncAnalyzerWithDemoTrees()
        } else if let root = analyzerRootNode {
            if removedNorm.contains(where: { Self.isSameOrDescendant(Self.normalizedKey(root.url.path), ofNormalizedBase: $0) }) {
                analyzerRootNode = nil
                analyzerBreadcrumbIDs = []
            } else {
                let prunedRoot = Self.pruningTree(root, removedNormalized: removedNorm)
                analyzerRootNode = prunedRoot
                var validBreadcrumbs: [String] = []
                var cursor = prunedRoot
                for id in analyzerBreadcrumbIDs {
                    if let next = cursor.children.first(where: { $0.id == id }) {
                        validBreadcrumbs.append(id)
                        cursor = next
                    } else {
                        break
                    }
                }
                analyzerBreadcrumbIDs = validBreadcrumbs
            }
            recomputeAnalyzerFilter()
        }

        let currentNorm = Self.normalizedKey(currentDirectoryURL.path)
        let affectsCurrentDir = removedNorm.contains(where: { removed in
            Self.isSameOrDescendant(currentNorm, ofNormalizedBase: removed)
                || Self.normalizedKey(URL(fileURLWithPath: removed).deletingLastPathComponent().path) == currentNorm
        })
        if affectsCurrentDir {
            refreshCurrentDirectory()
        }
    }

    // MARK: - Inspector & Bounded Non-Blocking Preview

    public func inspectAndPreview(url: URL?) {
        previewTask?.cancel()
        previewGeneration += 1
        let gen = previewGeneration

        guard let url else {
            inspectedURL = nil
            inspectedMetadata = nil
            previewState = .none
            isInspectedURLProtected = false
            inspectedProtectionReason = nil
            return
        }

        let stdURL = url.standardizedFileURL
        inspectedURL = stdURL

        if isDemoMode, let catalog = demoCatalog {
            let stdNorm = Self.normalizedKey(stdURL.path)
            if demoPathState(stdURL.path) == false || !demoPathExists(stdURL.path) {
                inspectedMetadata = nil
                isInspectedURLProtected = false
                inspectedProtectionReason = nil
                previewState = .unavailable(.notFound)
                return
            }
            let payload = demoPreviews[stdNorm] ?? catalog.previewPayload(for: stdURL)
            inspectedMetadata = payload.metadata
            let status = demoProtectionStatus(for: stdURL, using: currentGuard)
            isInspectedURLProtected = status.isProtected
            inspectedProtectionReason = status.reason
            previewState = Self.mapPreviewPayload(payload)
            return
        }

        previewState = .loading
        let guardCopy = currentGuard

        previewTask = Task {
            do {
                let payload = try await FileBrowserService(safetyGuard: guardCopy).loadPreviewAsync(at: url)
                guard !Task.isCancelled else { return }
                let mappedState = Self.mapPreviewPayload(payload)
                await MainActor.run { [weak self] in
                    guard let self, self.previewGeneration == gen else { return }
                    self.inspectedMetadata = payload.metadata
                    self.isInspectedURLProtected = payload.isProtected
                    self.inspectedProtectionReason = payload.protectionReason
                    self.previewState = mappedState
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.previewGeneration == gen else { return }
                    self.inspectedMetadata = nil
                    self.previewState = .unavailable(.notFound)
                }
            }
        }
    }

    // MARK: - Helpers

    nonisolated static func sanitizeMultilinePreview(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.count)
        var lastWasCR = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v == 0x0D {
                result.append("\n")
                lastWasCR = true
                continue
            }
            if v == 0x0A {
                if !lastWasCR {
                    result.append("\n")
                }
                lastWasCR = false
                continue
            }
            lastWasCR = false
            switch v {
            case 0x00:
                result.append("\\0")
            case 0x09:
                result.append("\t")
            default:
                if v <= 0x1F || (v >= 0x7F && v <= 0x9F)
                    || v == 0x061C
                    || (v >= 0x200E && v <= 0x200F)
                    || (v >= 0x2028 && v <= 0x202E)
                    || (v >= 0x2066 && v <= 0x2069) {
                    result.append(String(format: "\\u{%04X}", v))
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    nonisolated static func mapPreviewPayload(_ payload: FilePreviewPayload) -> InspectorPreviewState {
        switch payload.content {
        case let .text(raw, encoding, isTruncated, totalBytes):
            let sanitized = sanitizeMultilinePreview(raw)
            return .text(
                sanitized,
                encoding: encoding,
                isTruncated: isTruncated,
                totalBytes: totalBytes,
                shownBytes: raw.utf8.count
            )
        case let .hexDump(hex, byteCount, isTruncated, totalBytes):
            return .hexDump(hex, byteCount: byteCount, isTruncated: isTruncated, totalBytes: totalBytes)
        case let .image(data, uti, byteCount):
            if let nsImg = NSImage(data: data) {
                return .image(nsImg, utiIdentifier: uti, byteCount: byteCount)
            }
            return .unavailable(.unreadable(errno: EFTYPE))
        case let .unavailable(reason):
            return .unavailable(reason)
        }
    }

    private nonisolated static func normalizedKey(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private nonisolated static func parentPath(of url: URL) -> String {
        let parent = url.standardizedFileURL.deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private nonisolated static func isSameOrDescendant(_ pathNorm: String, ofNormalizedBase baseNorm: String) -> Bool {
        if pathNorm == baseNorm {
            return true
        }
        if baseNorm == "/" {
            return pathNorm.hasPrefix("/")
        }
        return pathNorm.hasPrefix(baseNorm + "/")
    }

    private nonisolated static func rebasedNormalizedKey(
        from oldNorm: String,
        to newNorm: String,
        for keyNorm: String
    ) -> String {
        if keyNorm == oldNorm {
            return newNorm
        }
        let oldPrefix = oldNorm == "/" ? "/" : oldNorm + "/"
        guard keyNorm.hasPrefix(oldPrefix) else {
            return keyNorm
        }
        let suffix = String(keyNorm.dropFirst(oldNorm == "/" ? 0 : oldNorm.count))
        if newNorm == "/" {
            return suffix.hasPrefix("/") ? suffix : "/" + suffix
        }
        return newNorm + suffix
    }

    private nonisolated static func rebasedURL(from oldBase: URL, to newBase: URL, for originalURL: URL) -> URL {
        let oldStd = oldBase.standardizedFileURL
        let newStd = newBase.standardizedFileURL
        let origStd = originalURL.standardizedFileURL

        if normalizedKey(origStd.path) == normalizedKey(oldStd.path) {
            return newStd
        }

        let oldComponents = oldStd.pathComponents
        let origComponents = origStd.pathComponents
        guard origComponents.count > oldComponents.count else {
            return newStd
        }
        var rebased = newStd
        for component in origComponents.dropFirst(oldComponents.count) {
            rebased = rebased.appendingPathComponent(component)
        }
        return rebased.standardizedFileURL
    }

    private nonisolated static func rebasedEntry(
        _ entry: FileBrowserEntry,
        from oldBase: URL,
        to newBase: URL
    ) -> FileBrowserEntry {
        let updatedURL = rebasedURL(from: oldBase, to: newBase, for: entry.url)
        let updatedParent = parentPath(of: updatedURL)
        return FileBrowserEntry(
            url: updatedURL,
            name: entry.name,
            kind: entry.kind,
            sizeBytes: entry.sizeBytes,
            modificationDate: entry.modificationDate,
            createdDate: entry.createdDate,
            isDirectory: entry.isDirectory,
            isPackage: entry.isPackage,
            isSymbolicLink: entry.isSymbolicLink,
            isSymlinkBroken: entry.isSymlinkBroken,
            isHidden: entry.isHidden,
            isDataless: entry.isDataless,
            isUserImmutable: entry.isUserImmutable,
            isSIPRestricted: entry.isSIPRestricted,
            isProtected: entry.isProtected,
            protectionReason: entry.protectionReason,
            requiresAdmin: entry.requiresAdmin,
            utiIdentifier: entry.utiIdentifier,
            kindDescription: entry.kindDescription,
            expectedCanonicalParent: updatedParent
        )
    }

    private func demoAllEntries(at directoryURL: URL) -> [FileBrowserEntry] {
        let dirNorm = Self.normalizedKey(directoryURL.path)
        if let explicit = demoDirectories[dirNorm] {
            return explicit
        }
        if demoRemovedPaths.contains(where: { Self.isSameOrDescendant(dirNorm, ofNormalizedBase: $0) }) {
            return []
        }
        if let catalog = demoCatalog {
            return catalog.fileBrowserEntries(
                at: directoryURL,
                showHidden: true,
                sortBy: .name,
                ascending: true
            ).filter { entry in
                let entryNorm = Self.normalizedKey(entry.url.path)
                return !demoRemovedPaths.contains(where: { Self.isSameOrDescendant(entryNorm, ofNormalizedBase: $0) })
            }
        }
        return []
    }

    private func materializeDemoDirectoryTreeIfNeeded(at directoryURL: URL) {
        guard let catalog = demoCatalog else { return }
        var stack: [URL] = [directoryURL.standardizedFileURL]
        var visited: Set<String> = []

        while let current = stack.popLast() {
            let dirNorm = Self.normalizedKey(current.path)
            guard visited.insert(dirNorm).inserted else { continue }
            if demoRemovedPaths.contains(where: { Self.isSameOrDescendant(dirNorm, ofNormalizedBase: $0) }) {
                continue
            }

            if demoPreviews[dirNorm] == nil, catalog.pathExists(current.path) {
                demoPreviews[dirNorm] = catalog.previewPayload(for: current)
            }

            let entries: [FileBrowserEntry]
            if let existing = demoDirectories[dirNorm] {
                entries = existing
            } else {
                let catalogEntries = catalog.fileBrowserEntries(
                    at: current,
                    showHidden: true,
                    sortBy: .name,
                    ascending: true
                ).filter { entry in
                    let entryNorm = Self.normalizedKey(entry.url.path)
                    return !demoRemovedPaths.contains(where: { Self.isSameOrDescendant(entryNorm, ofNormalizedBase: $0) })
                }
                demoDirectories[dirNorm] = catalogEntries
                entries = catalogEntries
            }

            for entry in entries {
                let entryNorm = Self.normalizedKey(entry.url.path)
                if demoPreviews[entryNorm] == nil {
                    if catalog.pathExists(entry.url.path) {
                        demoPreviews[entryNorm] = catalog.previewPayload(for: entry.url)
                    } else {
                        demoPreviews[entryNorm] = Self.synthesizedPreviewPayload(for: entry)
                    }
                }
                if entry.isDirectory && !entry.isPackage && !entry.isSymbolicLink {
                    stack.append(entry.url)
                }
            }
        }
    }

    private func migrateDemoSubtree(
        from oldURL: URL,
        to newURL: URL,
        newName: String,
        isDirectory: Bool,
        sourceEntry: FileBrowserEntry? = nil
    ) {
        let oldStd = oldURL.standardizedFileURL
        let newStd = newURL.standardizedFileURL
        let oldNorm = Self.normalizedKey(oldStd.path)
        let newNorm = Self.normalizedKey(newStd.path)

        if isDirectory {
            materializeDemoDirectoryTreeIfNeeded(at: oldStd)

            let matchingDirKeys = demoDirectories.keys.filter {
                Self.isSameOrDescendant($0, ofNormalizedBase: oldNorm)
            }
            var migratedDirs: [(key: String, entries: [FileBrowserEntry])] = []
            migratedDirs.reserveCapacity(matchingDirKeys.count)
            for dirKey in matchingDirKeys {
                if let entries = demoDirectories.removeValue(forKey: dirKey) {
                    let migratedKey = Self.rebasedNormalizedKey(from: oldNorm, to: newNorm, for: dirKey)
                    let migratedEntries = entries.map { Self.rebasedEntry($0, from: oldStd, to: newStd) }
                    migratedDirs.append((key: migratedKey, entries: migratedEntries))
                }
            }
            for migrated in migratedDirs {
                demoDirectories[migrated.key] = migrated.entries
            }
        }

        if demoPreviews[oldNorm] == nil {
            if let catalog = demoCatalog, catalog.pathExists(oldStd.path) {
                demoPreviews[oldNorm] = catalog.previewPayload(for: oldStd)
            } else if let sourceEntry {
                demoPreviews[oldNorm] = Self.synthesizedPreviewPayload(for: sourceEntry)
            }
        }

        let matchingPreviewKeys = demoPreviews.keys.filter { key in
            isDirectory ? Self.isSameOrDescendant(key, ofNormalizedBase: oldNorm) : key == oldNorm
        }
        var migratedPreviews: [(key: String, payload: FilePreviewPayload)] = []
        migratedPreviews.reserveCapacity(matchingPreviewKeys.count)
        for previewKey in matchingPreviewKeys {
            if let payload = demoPreviews.removeValue(forKey: previewKey) {
                let rebasedURL = previewKey == oldNorm
                    ? newStd
                    : Self.rebasedURL(from: oldStd, to: newStd, for: payload.metadata.url)
                let rebasedKey = Self.normalizedKey(rebasedURL.path)
                let rebasedParent = Self.parentPath(of: rebasedURL)
                let migratedName = previewKey == oldNorm ? newName : rebasedURL.lastPathComponent
                let migratedPayload = Self.migratedPreviewPayload(
                    payload,
                    to: rebasedURL,
                    parentPath: rebasedParent,
                    newName: migratedName
                )
                migratedPreviews.append((key: rebasedKey, payload: migratedPayload))
            }
        }
        for migrated in migratedPreviews {
            demoPreviews[migrated.key] = migrated.payload
        }

        let matchingBundleKeys = demoBundleIDsByPath.keys.filter { key in
            isDirectory ? Self.isSameOrDescendant(key, ofNormalizedBase: oldNorm) : key == oldNorm
        }
        var migratedBundles: [(key: String, bundleID: String)] = []
        migratedBundles.reserveCapacity(matchingBundleKeys.count)
        for bundleKey in matchingBundleKeys {
            if let bundleID = demoBundleIDsByPath.removeValue(forKey: bundleKey) {
                let rebasedKey = Self.rebasedNormalizedKey(from: oldNorm, to: newNorm, for: bundleKey)
                migratedBundles.append((key: rebasedKey, bundleID: bundleID))
            }
        }
        for migrated in migratedBundles {
            demoBundleIDsByPath[migrated.key] = migrated.bundleID
        }

        demoRemovedPaths.insert(oldNorm)
        demoRemovedPaths = demoRemovedPaths.filter { !Self.isSameOrDescendant($0, ofNormalizedBase: newNorm) }
    }

    private func filteredAndSortedDemoEntries(at directoryURL: URL) -> [FileBrowserEntry] {
        let dirNorm = Self.normalizedKey(directoryURL.path)
        var entries: [FileBrowserEntry]
        if let explicit = demoDirectories[dirNorm] {
            entries = explicit
        } else if demoRemovedPaths.contains(where: { Self.isSameOrDescendant(dirNorm, ofNormalizedBase: $0) }) {
            return []
        } else if let catalog = demoCatalog {
            return catalog.fileBrowserEntries(
                at: directoryURL,
                showHidden: showHiddenFiles,
                sortBy: browserSortBy,
                ascending: browserAscending,
                searchQuery: browserSearchText
            ).filter { entry in
                let entryNorm = Self.normalizedKey(entry.url.path)
                return !demoRemovedPaths.contains(where: { Self.isSameOrDescendant(entryNorm, ofNormalizedBase: $0) })
            }
        } else {
            return []
        }

        if !showHiddenFiles {
            entries = entries.filter { !$0.isHidden && !$0.name.hasPrefix(".") }
        }
        let q = browserSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            entries = entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
        }

        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            let cmp: ComparisonResult
            switch browserSortBy {
            case .name:
                cmp = lhs.name.localizedStandardCompare(rhs.name)
            case .size:
                if lhs.sizeBytes != rhs.sizeBytes {
                    cmp = lhs.sizeBytes < rhs.sizeBytes ? .orderedAscending : .orderedDescending
                } else {
                    cmp = lhs.name.localizedStandardCompare(rhs.name)
                }
            case .modificationDate:
                let ld = lhs.modificationDate ?? .distantPast
                let rd = rhs.modificationDate ?? .distantPast
                if ld != rd {
                    cmp = ld < rd ? .orderedAscending : .orderedDescending
                } else {
                    cmp = lhs.name.localizedStandardCompare(rhs.name)
                }
            case .kind:
                let kindCmp = lhs.kindDescription.localizedStandardCompare(rhs.kindDescription)
                if kindCmp != .orderedSame {
                    cmp = kindCmp
                } else {
                    cmp = lhs.name.localizedStandardCompare(rhs.name)
                }
            }
            if cmp == .orderedSame {
                let pathCmp = lhs.url.path.localizedStandardCompare(rhs.url.path)
                return browserAscending ? pathCmp == .orderedAscending : pathCmp == .orderedDescending
            }
            return browserAscending ? cmp == .orderedAscending : cmp == .orderedDescending
        }
        return entries
    }

    private nonisolated static func demoRequiresAdmin(for url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path == "/Users/alex" || path.hasPrefix("/Users/alex/") {
            return false
        }
        if path.hasPrefix("/Library/") || path.hasPrefix("/System/") || path.hasPrefix("/private/") || path.hasPrefix("/usr/") {
            return true
        }
        return false
    }

    func demoBundleID(for url: URL) -> String? {
        let stdNorm = Self.normalizedKey(url.path)
        if demoBundleIDsInitialized {
            let matches = demoBundleIDsByPath.filter {
                Self.isSameOrDescendant(stdNorm, ofNormalizedBase: $0.key)
            }
            return matches.max(by: { $0.key.count < $1.key.count })?.value
        }
        let knownApps = appState?.apps ?? demoCatalog?.applications ?? []
        for app in knownApps {
            let appNorm = Self.normalizedKey(app.url.path)
            if Self.isSameOrDescendant(stdNorm, ofNormalizedBase: appNorm) {
                return app.bundleID
            }
        }
        return nil
    }

    func isDemoPathProtected(_ url: URL) -> Bool {
        demoProtectionStatus(for: url, using: currentGuard).isProtected
    }

    private func demoProtectionStatus(for url: URL, using safetyGuard: SafetyGuard) -> (isProtected: Bool, reason: String?) {
        if case let .blocked(reason) = safetyGuard.validateForRemoval(url) {
            return (true, reason)
        }
        let stdNorm = Self.normalizedKey(url.path)
        if demoBundleIDsInitialized {
            for (appNorm, bundleID) in demoBundleIDsByPath where Self.isSameOrDescendant(stdNorm, ofNormalizedBase: appNorm) {
                if safetyGuard.matchesProtectedBundleID(bundleID) {
                    return (true, "Protected by user bundle ID skip list")
                }
            }
        } else {
            let knownApps = appState?.apps ?? demoCatalog?.applications ?? []
            for app in knownApps {
                let appNorm = Self.normalizedKey(app.url.path)
                if Self.isSameOrDescendant(stdNorm, ofNormalizedBase: appNorm) {
                    if safetyGuard.matchesProtectedBundleID(app.bundleID) {
                        return (true, "Protected by user bundle ID skip list")
                    }
                }
            }
        }
        return (false, nil)
    }

    private func updatingDemoProtection(_ entry: FileBrowserEntry, using safetyGuard: SafetyGuard) -> FileBrowserEntry {
        let status = demoProtectionStatus(for: entry.url, using: safetyGuard)
        return FileBrowserEntry(
            url: entry.url,
            name: entry.name,
            kind: entry.kind,
            sizeBytes: entry.sizeBytes,
            modificationDate: entry.modificationDate,
            createdDate: entry.createdDate,
            isDirectory: entry.isDirectory,
            isPackage: entry.isPackage,
            isSymbolicLink: entry.isSymbolicLink,
            isSymlinkBroken: entry.isSymlinkBroken,
            isHidden: entry.isHidden,
            isDataless: entry.isDataless,
            isUserImmutable: entry.isUserImmutable,
            isSIPRestricted: entry.isSIPRestricted,
            isProtected: status.isProtected,
            protectionReason: status.reason,
            requiresAdmin: entry.requiresAdmin,
            utiIdentifier: entry.utiIdentifier,
            kindDescription: entry.kindDescription,
            expectedCanonicalParent: entry.expectedCanonicalParent
        )
    }

    private func updatingDemoProtection(_ node: DiskTreeNode, using safetyGuard: SafetyGuard) -> DiskTreeNode {
        let status = demoProtectionStatus(for: node.url, using: safetyGuard)
        let updatedChildren = node.children.map { updatingDemoProtection($0, using: safetyGuard) }
        return DiskTreeNode(
            url: node.url,
            name: node.name,
            isDirectory: node.isDirectory,
            isPackage: node.isPackage,
            isSymlink: node.isSymlink,
            bytes: node.bytes,
            fileCount: node.fileCount,
            folderCount: node.folderCount,
            modificationDate: node.modificationDate,
            accessDate: node.accessDate,
            children: updatedChildren,
            isTruncated: node.isTruncated,
            truncatedChildCount: node.truncatedChildCount,
            isAccessible: node.isAccessible,
            isProtected: status.isProtected,
            isUserImmutable: node.isUserImmutable,
            isHidden: node.isHidden,
            expectedCanonicalParent: node.expectedCanonicalParent
        )
    }

    private nonisolated static func filteringHiddenTree(_ node: DiskTreeNode, includeHidden: Bool) -> DiskTreeNode {
        guard !includeHidden, node.isDirectory, !node.children.isEmpty else { return node }
        var keptChildren: [DiskTreeNode] = []
        keptChildren.reserveCapacity(node.children.count)
        var removedBytes: UInt64 = 0
        var removedFiles = 0
        var removedFolders = 0

        for child in node.children {
            if child.isHidden {
                removedBytes &+= child.bytes
                removedFiles += child.fileCount
                removedFolders += (child.isDirectory && !child.isSymlink) ? (1 + child.folderCount) : 0
            } else {
                let filtered = filteringHiddenTree(child, includeHidden: false)
                if filtered.bytes < child.bytes {
                    removedBytes &+= (child.bytes - filtered.bytes)
                }
                if filtered.fileCount < child.fileCount {
                    removedFiles += (child.fileCount - filtered.fileCount)
                }
                if filtered.folderCount < child.folderCount {
                    removedFolders += (child.folderCount - filtered.folderCount)
                }
                keptChildren.append(filtered)
            }
        }

        keptChildren.sort(by: Self.diskTreeChildrenSort)

        return DiskTreeNode(
            url: node.url,
            name: node.name,
            isDirectory: node.isDirectory,
            isPackage: node.isPackage,
            isSymlink: node.isSymlink,
            bytes: node.bytes > removedBytes ? (node.bytes - removedBytes) : 0,
            fileCount: max(0, node.fileCount - removedFiles),
            folderCount: max(0, node.folderCount - removedFolders),
            modificationDate: node.modificationDate,
            accessDate: node.accessDate,
            children: keptChildren,
            isTruncated: node.isTruncated,
            truncatedChildCount: node.truncatedChildCount,
            isAccessible: node.isAccessible,
            isProtected: node.isProtected,
            isUserImmutable: node.isUserImmutable,
            isHidden: node.isHidden,
            expectedCanonicalParent: node.expectedCanonicalParent
        )
    }

    private nonisolated static func migratedPreviewPayload(
        _ payload: FilePreviewPayload,
        to destinationURL: URL,
        parentPath: String,
        newName: String
    ) -> FilePreviewPayload {
        let oldMeta = payload.metadata
        let updatedMeta = FileMetadataInfo(
            url: destinationURL,
            name: newName,
            kind: oldMeta.kind,
            sizeBytes: oldMeta.sizeBytes,
            allocatedSizeBytes: oldMeta.allocatedSizeBytes,
            createdDate: oldMeta.createdDate,
            modifiedDate: DemoFixtureCatalog.referenceDate,
            accessedDate: oldMeta.accessedDate,
            posixPermissions: oldMeta.posixPermissions,
            ownerUID: oldMeta.ownerUID,
            groupGID: oldMeta.groupGID,
            isDirectory: oldMeta.isDirectory,
            isPackage: oldMeta.isPackage,
            isSymbolicLink: oldMeta.isSymbolicLink,
            isSymlinkBroken: oldMeta.isSymlinkBroken,
            symlinkTarget: oldMeta.symlinkTarget,
            resolvedTargetPath: oldMeta.resolvedTargetPath,
            isUserImmutable: oldMeta.isUserImmutable,
            isSIPRestricted: oldMeta.isSIPRestricted,
            isHidden: newName.hasPrefix("."),
            isDataless: oldMeta.isDataless,
            utiIdentifier: oldMeta.utiIdentifier,
            kindDescription: oldMeta.kindDescription,
            expectedCanonicalParent: parentPath
        )
        return FilePreviewPayload(
            metadata: updatedMeta,
            content: payload.content,
            isProtected: payload.isProtected,
            protectionReason: payload.protectionReason
        )
    }

    private nonisolated static func pruningTree(_ node: DiskTreeNode, removedNormalized: Set<String>) -> DiskTreeNode {
        guard node.isDirectory && !node.children.isEmpty else { return node }

        var newChildren: [DiskTreeNode] = []
        newChildren.reserveCapacity(node.children.count)
        var removedBytes: UInt64 = 0
        var removedFiles = 0
        var removedFolders = 0

        for child in node.children {
            let key = normalizedKey(child.url.path)
            if removedNormalized.contains(where: { isSameOrDescendant(key, ofNormalizedBase: $0) }) {
                removedBytes &+= child.bytes
                removedFiles += child.fileCount
                removedFolders += (child.isDirectory && !child.isSymlink) ? (1 + child.folderCount) : 0
            } else {
                let pruned = pruningTree(child, removedNormalized: removedNormalized)
                if pruned.bytes < child.bytes {
                    removedBytes &+= (child.bytes - pruned.bytes)
                }
                if pruned.fileCount < child.fileCount {
                    removedFiles += (child.fileCount - pruned.fileCount)
                }
                if pruned.folderCount < child.folderCount {
                    removedFolders += (child.folderCount - pruned.folderCount)
                }
                newChildren.append(pruned)
            }
        }

        newChildren.sort(by: Self.diskTreeChildrenSort)

        let updatedBytes = node.bytes > removedBytes ? (node.bytes - removedBytes) : 0
        let updatedFiles = max(0, node.fileCount - removedFiles)
        let updatedFolders = max(0, node.folderCount - removedFolders)

        return DiskTreeNode(
            url: node.url,
            name: node.name,
            isDirectory: node.isDirectory,
            isPackage: node.isPackage,
            isSymlink: node.isSymlink,
            bytes: updatedBytes,
            fileCount: updatedFiles,
            folderCount: updatedFolders,
            modificationDate: node.modificationDate,
            accessDate: node.accessDate,
            children: newChildren,
            isTruncated: node.isTruncated,
            truncatedChildCount: node.truncatedChildCount,
            isAccessible: node.isAccessible,
            isProtected: node.isProtected,
            isUserImmutable: node.isUserImmutable,
            isHidden: node.isHidden,
            expectedCanonicalParent: node.expectedCanonicalParent
        )
    }

    private func isExistingDemoDirectory(_ directoryURL: URL) -> Bool {
        let std = directoryURL.standardizedFileURL
        let dirNorm = Self.normalizedKey(std.path)
        guard demoPathState(std.path) == true else {
            return false
        }
        if demoDirectories[dirNorm] != nil {
            return true
        }
        let parentURL = std.deletingLastPathComponent().standardizedFileURL
        if parentURL.path != std.path {
            let parentEntries = demoAllEntries(at: parentURL)
            if let match = parentEntries.first(where: { Self.normalizedKey($0.url.path) == dirNorm }) {
                return match.isDirectory && !match.isSymbolicLink
            }
        }
        if let catalog = demoCatalog {
            return catalog.isDirectory(at: std)
        }
        return false
    }

    private nonisolated static func synthesizedPreviewPayload(for entry: FileBrowserEntry) -> FilePreviewPayload {
        let meta = FileMetadataInfo(
            url: entry.url,
            name: entry.name,
            kind: entry.kind,
            sizeBytes: entry.sizeBytes,
            allocatedSizeBytes: entry.sizeBytes,
            createdDate: entry.createdDate,
            modifiedDate: entry.modificationDate,
            accessedDate: entry.modificationDate,
            posixPermissions: entry.isDirectory ? 0o755 : (entry.isUserImmutable ? 0o444 : 0o644),
            ownerUID: 501,
            groupGID: 20,
            isDirectory: entry.isDirectory,
            isPackage: entry.isPackage,
            isSymbolicLink: entry.isSymbolicLink,
            isSymlinkBroken: entry.isSymlinkBroken,
            symlinkTarget: entry.isSymbolicLink ? "/Users/alex/Documents/Architecture-RFCs" : nil,
            resolvedTargetPath: entry.isSymbolicLink ? "/Users/alex/Documents/Architecture-RFCs" : nil,
            isUserImmutable: entry.isUserImmutable,
            isSIPRestricted: entry.isSIPRestricted,
            isHidden: entry.isHidden,
            isDataless: entry.isDataless,
            utiIdentifier: entry.utiIdentifier,
            kindDescription: entry.kindDescription,
            expectedCanonicalParent: entry.expectedCanonicalParent
        )
        let content: FilePreviewContent
        if entry.isSymbolicLink {
            content = .unavailable(reason: .symbolicLink)
        } else if entry.isDirectory {
            content = .unavailable(reason: .directory)
        } else {
            content = .text(
                "Demo preview for \(entry.name)\nPath: \(entry.url.path)\n",
                encodingDescription: "UTF-8",
                isTruncated: false,
                totalBytes: entry.sizeBytes
            )
        }
        return FilePreviewPayload(
            metadata: meta,
            content: content,
            isProtected: entry.isProtected,
            protectionReason: entry.protectionReason
        )
    }

    private nonisolated static func aggregateContribution(
        for entry: FileBrowserEntry
    ) -> (bytes: UInt64, fileCount: Int, folderCount: Int) {
        if entry.isSymbolicLink {
            return (0, 0, 0)
        }
        return (
            bytes: UInt64(max(0, entry.sizeBytes)),
            fileCount: entry.isDirectory ? 0 : 1,
            folderCount: entry.isDirectory ? 1 : 0
        )
    }

    private nonisolated static func makeDiskTreeNode(from entry: FileBrowserEntry) -> DiskTreeNode {
        DiskTreeNode(
            url: entry.url,
            name: entry.name,
            isDirectory: entry.isDirectory,
            isPackage: entry.isPackage,
            isSymlink: entry.isSymbolicLink,
            bytes: entry.isSymbolicLink ? 0 : UInt64(max(0, entry.sizeBytes)),
            fileCount: (entry.isDirectory || entry.isSymbolicLink) ? 0 : 1,
            folderCount: 0,
            modificationDate: entry.modificationDate,
            accessDate: entry.modificationDate,
            children: [],
            isProtected: entry.isProtected,
            isUserImmutable: entry.isUserImmutable,
            isHidden: entry.isHidden,
            expectedCanonicalParent: entry.expectedCanonicalParent
        )
    }

    private nonisolated static func diskTreeChildrenSort(_ lhs: DiskTreeNode, _ rhs: DiskTreeNode) -> Bool {
        if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private func demoEntry(for targetURL: URL) -> FileBrowserEntry? {
        let std = targetURL.standardizedFileURL
        let targetNorm = Self.normalizedKey(std.path)
        let parentURL = std.deletingLastPathComponent().standardizedFileURL
        guard parentURL.path != std.path else { return nil }
        return demoAllEntries(at: parentURL).first {
            Self.normalizedKey($0.url.path) == targetNorm
        }
    }

    @discardableResult
    private func insertIntoExistingDemoTree(_ node: DiskTreeNode, parentNormalized parentNorm: String) -> Bool {
        if let homeTree = demoHomeDiskTree {
            let res = Self.insertingDiskTreeNode(node, into: homeTree, parentNormalized: parentNorm)
            if res.inserted {
                demoHomeDiskTree = res.tree
                return true
            }
        }
        if let appsTree = demoAppsDiskTree {
            let res = Self.insertingDiskTreeNode(node, into: appsTree, parentNormalized: parentNorm)
            if res.inserted {
                demoAppsDiskTree = res.tree
                return true
            }
        }
        return false
    }

    private func materializeMissingDemoAncestorsIfNeeded(
        forParentURL parentURL: URL,
        parentNormalized parentNorm: String
    ) -> Bool {
        guard demoDiskTreeNode(forNormalizedPath: parentNorm) == nil else {
            return true
        }

        var missingChain: [URL] = []
        var cursor = parentURL.standardizedFileURL
        var foundAncestor = false

        while true {
            let cursorNorm = Self.normalizedKey(cursor.path)
            if demoDiskTreeNode(forNormalizedPath: cursorNorm) != nil {
                foundAncestor = true
                break
            }
            missingChain.append(cursor)
            let next = cursor.deletingLastPathComponent().standardizedFileURL
            if next.path == cursor.path {
                break
            }
            cursor = next
        }

        guard foundAncestor else {
            return false
        }

        for dirURL in missingChain.reversed() {
            let dirParentURL = dirURL.deletingLastPathComponent().standardizedFileURL
            let dirParentNorm = Self.normalizedKey(dirParentURL.path)
            guard let parentNode = demoDiskTreeNode(forNormalizedPath: dirParentNorm) else {
                return false
            }

            let dirNode: DiskTreeNode
            if let entry = demoEntry(for: dirURL) {
                let contribution = Self.aggregateContribution(for: entry)
                deductDemoAggregate(
                    bytes: min(parentNode.bytes, contribution.bytes),
                    fileCount: min(parentNode.fileCount, contribution.fileCount),
                    folderCount: min(parentNode.folderCount, contribution.folderCount),
                    fromParentNormalized: dirParentNorm
                )
                dirNode = Self.makeDiskTreeNode(from: entry)
            } else {
                dirNode = DiskTreeNode(
                    url: dirURL,
                    name: dirURL.lastPathComponent,
                    isDirectory: true,
                    bytes: 0,
                    fileCount: 0,
                    folderCount: 0,
                    modificationDate: DemoFixtureCatalog.referenceDate,
                    accessDate: DemoFixtureCatalog.referenceDate,
                    expectedCanonicalParent: dirParentURL.path
                )
            }

            _ = insertIntoExistingDemoTree(dirNode, parentNormalized: dirParentNorm)
        }

        return demoDiskTreeNode(forNormalizedPath: parentNorm) != nil
    }

    private func demoDiskTreeNode(forNormalizedPath norm: String) -> DiskTreeNode? {
        if let homeTree = demoHomeDiskTree,
           let match = Self.findDiskTreeNode(in: homeTree, normalizedPath: norm) {
            return match
        }
        if let appsTree = demoAppsDiskTree,
           let match = Self.findDiskTreeNode(in: appsTree, normalizedPath: norm) {
            return match
        }
        return nil
    }

    private func insertDemoDiskTreeNode(_ node: DiskTreeNode, intoParentNormalized parentNorm: String) {
        if insertIntoExistingDemoTree(node, parentNormalized: parentNorm) {
            return
        }
        let parentURL = node.url.standardizedFileURL.deletingLastPathComponent().standardizedFileURL
        if Self.normalizedKey(parentURL.path) == parentNorm,
           materializeMissingDemoAncestorsIfNeeded(forParentURL: parentURL, parentNormalized: parentNorm) {
            _ = insertIntoExistingDemoTree(node, parentNormalized: parentNorm)
        }
    }

    private func extractDemoDiskTreeNode(normalizedPath: String) -> DiskTreeNode? {
        if let homeTree = demoHomeDiskTree {
            let res = Self.extractingDiskTreeNode(from: homeTree, targetNormalized: normalizedPath)
            if let extracted = res.extracted {
                demoHomeDiskTree = res.tree
                return extracted
            }
        }
        if let appsTree = demoAppsDiskTree {
            let res = Self.extractingDiskTreeNode(from: appsTree, targetNormalized: normalizedPath)
            if let extracted = res.extracted {
                demoAppsDiskTree = res.tree
                return extracted
            }
        }
        return nil
    }

    private func deductDemoAggregate(
        bytes: UInt64,
        fileCount: Int,
        folderCount: Int,
        fromParentNormalized parentNorm: String
    ) {
        guard bytes > 0 || fileCount > 0 || folderCount > 0 else { return }
        if let homeTree = demoHomeDiskTree {
            let res = Self.deductingAggregate(
                bytes: bytes,
                fileCount: fileCount,
                folderCount: folderCount,
                from: homeTree,
                targetParentNormalized: parentNorm
            )
            if res.deducted {
                demoHomeDiskTree = res.tree
                return
            }
        }
        if let appsTree = demoAppsDiskTree {
            let res = Self.deductingAggregate(
                bytes: bytes,
                fileCount: fileCount,
                folderCount: folderCount,
                from: appsTree,
                targetParentNormalized: parentNorm
            )
            if res.deducted {
                demoAppsDiskTree = res.tree
            }
        }
    }

    private func renameDemoDiskTreeNode(
        from oldURL: URL,
        to newURL: URL,
        newName: String,
        fallbackEntry: FileBrowserEntry
    ) {
        let oldNorm = Self.normalizedKey(oldURL.path)
        let oldParentNorm = Self.normalizedKey(Self.parentPath(of: oldURL))
        let parentNorm = Self.normalizedKey(Self.parentPath(of: newURL))
        if let extracted = extractDemoDiskTreeNode(normalizedPath: oldNorm) {
            let rebased = Self.rebasedDiskTreeNode(extracted, to: newURL, newName: newName)
            insertDemoDiskTreeNode(rebased, intoParentNormalized: parentNorm)
        } else {
            let contribution = Self.aggregateContribution(for: fallbackEntry)
            deductDemoAggregate(
                bytes: contribution.bytes,
                fileCount: contribution.fileCount,
                folderCount: contribution.folderCount,
                fromParentNormalized: oldParentNorm
            )
            insertDemoDiskTreeNode(Self.makeDiskTreeNode(from: fallbackEntry), intoParentNormalized: parentNorm)
        }
    }

    private func moveDemoDiskTreeNode(
        from oldURL: URL,
        to dstURL: URL,
        newName: String,
        fallbackEntry: FileBrowserEntry
    ) {
        let oldNorm = Self.normalizedKey(oldURL.path)
        let oldParentNorm = Self.normalizedKey(Self.parentPath(of: oldURL))
        let dstParentNorm = Self.normalizedKey(Self.parentPath(of: dstURL))
        if let extracted = extractDemoDiskTreeNode(normalizedPath: oldNorm) {
            let rebased = Self.rebasedDiskTreeNode(extracted, to: dstURL, newName: newName)
            insertDemoDiskTreeNode(rebased, intoParentNormalized: dstParentNorm)
        } else {
            let contribution = Self.aggregateContribution(for: fallbackEntry)
            deductDemoAggregate(
                bytes: contribution.bytes,
                fileCount: contribution.fileCount,
                folderCount: contribution.folderCount,
                fromParentNormalized: oldParentNorm
            )
            insertDemoDiskTreeNode(Self.makeDiskTreeNode(from: fallbackEntry), intoParentNormalized: dstParentNorm)
        }
    }

    private func syncAnalyzerWithDemoTrees() {
        guard isDemoMode else { return }
        let rootNorm = Self.normalizedKey(analyzerRootURL.path)
        let isVolumeRootFallback = rootNorm == "/"
            || (demoCatalog?.availableVolumes.contains(where: { Self.normalizedKey($0.url.path) == rootNorm }) ?? false)
            || analyzerAvailableVolumes.contains(where: { Self.normalizedKey($0.url.path) == rootNorm })
        let resolvedNode = demoDiskTreeNode(forNormalizedPath: rootNorm)
            ?? (isVolumeRootFallback ? demoHomeDiskTree : nil)

        if let updated = resolvedNode {
            let filtered = Self.filteringHiddenTree(updated, includeHidden: analyzerIncludeHiddenFiles)
            analyzerRootNode = updatingDemoProtection(filtered, using: currentGuard)
            if let root = analyzerRootNode {
                var validBreadcrumbs: [String] = []
                var cursor = root
                for id in analyzerBreadcrumbIDs {
                    if let next = cursor.children.first(where: { $0.id == id }) {
                        validBreadcrumbs.append(id)
                        cursor = next
                    } else {
                        break
                    }
                }
                analyzerBreadcrumbIDs = validBreadcrumbs
            }
            selectedAnalyzerNodeIDs = selectedAnalyzerNodeIDs.filter { demoPathExists($0) }
            if let focused = focusedAnalyzerNodeID, !demoPathExists(focused) {
                focusedAnalyzerNodeID = nil
            }
        } else {
            analyzerRootNode = nil
            analyzerBreadcrumbIDs = []
            selectedAnalyzerNodeIDs.removeAll()
            focusedAnalyzerNodeID = nil
        }
        recomputeAnalyzerFilter()
    }

    private nonisolated static func rebasedDiskTreeNode(
        _ node: DiskTreeNode,
        to newURL: URL,
        newName: String? = nil
    ) -> DiskTreeNode {
        let stdURL = newURL.standardizedFileURL
        let resolvedName = newName ?? (stdURL.path == "/" ? "/" : stdURL.lastPathComponent)
        let parent = parentPath(of: stdURL)
        let rebasedChildren = node.children.map { child in
            rebasedDiskTreeNode(child, to: stdURL.appendingPathComponent(child.name))
        }
        return DiskTreeNode(
            url: stdURL,
            name: resolvedName,
            isDirectory: node.isDirectory,
            isPackage: node.isPackage,
            isSymlink: node.isSymlink,
            bytes: node.bytes,
            fileCount: node.fileCount,
            folderCount: node.folderCount,
            modificationDate: newName != nil ? DemoFixtureCatalog.referenceDate : node.modificationDate,
            accessDate: node.accessDate,
            children: rebasedChildren,
            isTruncated: node.isTruncated,
            truncatedChildCount: node.truncatedChildCount,
            isAccessible: node.isAccessible,
            isProtected: node.isProtected,
            isUserImmutable: node.isUserImmutable,
            isHidden: newName != nil ? resolvedName.hasPrefix(".") : node.isHidden,
            expectedCanonicalParent: parent
        )
    }

    private nonisolated static func findDiskTreeNode(
        in node: DiskTreeNode,
        normalizedPath: String
    ) -> DiskTreeNode? {
        if normalizedKey(node.url.path) == normalizedPath {
            return node
        }
        for child in node.children {
            if let hit = findDiskTreeNode(in: child, normalizedPath: normalizedPath) {
                return hit
            }
        }
        return nil
    }

    private nonisolated static func extractingDiskTreeNode(
        from node: DiskTreeNode,
        targetNormalized: String
    ) -> (tree: DiskTreeNode, extracted: DiskTreeNode?) {
        guard node.isDirectory && !node.children.isEmpty else {
            return (node, nil)
        }

        var newChildren: [DiskTreeNode] = []
        newChildren.reserveCapacity(node.children.count)
        var extractedNode: DiskTreeNode?
        var deltaBytes: UInt64 = 0
        var deltaFiles = 0
        var deltaFolders = 0

        for child in node.children {
            let childNorm = normalizedKey(child.url.path)
            if extractedNode == nil && childNorm == targetNormalized {
                extractedNode = child
                deltaBytes = child.bytes
                deltaFiles = child.fileCount
                deltaFolders = (child.isDirectory && !child.isSymlink) ? (1 + child.folderCount) : 0
            } else if extractedNode == nil && isSameOrDescendant(targetNormalized, ofNormalizedBase: childNorm) {
                let res = extractingDiskTreeNode(from: child, targetNormalized: targetNormalized)
                if let hit = res.extracted {
                    extractedNode = hit
                    deltaBytes = child.bytes > res.tree.bytes ? (child.bytes - res.tree.bytes) : 0
                    deltaFiles = max(0, child.fileCount - res.tree.fileCount)
                    deltaFolders = max(0, child.folderCount - res.tree.folderCount)
                }
                newChildren.append(res.tree)
            } else {
                newChildren.append(child)
            }
        }

        guard let extracted = extractedNode else {
            return (node, nil)
        }

        newChildren.sort(by: Self.diskTreeChildrenSort)

        let updated = DiskTreeNode(
            url: node.url,
            name: node.name,
            isDirectory: node.isDirectory,
            isPackage: node.isPackage,
            isSymlink: node.isSymlink,
            bytes: node.bytes > deltaBytes ? (node.bytes - deltaBytes) : 0,
            fileCount: max(0, node.fileCount - deltaFiles),
            folderCount: max(0, node.folderCount - deltaFolders),
            modificationDate: node.modificationDate,
            accessDate: node.accessDate,
            children: newChildren,
            isTruncated: node.isTruncated,
            truncatedChildCount: node.truncatedChildCount,
            isAccessible: node.isAccessible,
            isProtected: node.isProtected,
            isUserImmutable: node.isUserImmutable,
            isHidden: node.isHidden,
            expectedCanonicalParent: node.expectedCanonicalParent
        )
        return (updated, extracted)
    }

    private nonisolated static func insertingDiskTreeNode(
        _ newNode: DiskTreeNode,
        into node: DiskTreeNode,
        parentNormalized: String
    ) -> (tree: DiskTreeNode, inserted: Bool) {
        let nodeNorm = normalizedKey(node.url.path)
        if nodeNorm == parentNormalized {
            let newNorm = normalizedKey(newNode.url.path)
            var newChildren = node.children.filter { normalizedKey($0.url.path) != newNorm }
            newChildren.append(newNode)
            newChildren.sort(by: Self.diskTreeChildrenSort)
            let addedBytes = newNode.bytes
            let addedFiles = newNode.fileCount
            let addedFolders = (newNode.isDirectory && !newNode.isSymlink) ? (1 + newNode.folderCount) : 0
            let updated = DiskTreeNode(
                url: node.url,
                name: node.name,
                isDirectory: node.isDirectory,
                isPackage: node.isPackage,
                isSymlink: node.isSymlink,
                bytes: node.bytes &+ addedBytes,
                fileCount: node.fileCount + addedFiles,
                folderCount: node.folderCount + addedFolders,
                modificationDate: node.modificationDate,
                accessDate: node.accessDate,
                children: newChildren,
                isTruncated: node.isTruncated,
                truncatedChildCount: node.truncatedChildCount,
                isAccessible: node.isAccessible,
                isProtected: node.isProtected,
                isUserImmutable: node.isUserImmutable,
                isHidden: node.isHidden,
                expectedCanonicalParent: node.expectedCanonicalParent
            )
            return (updated, true)
        }

        guard node.isDirectory && isSameOrDescendant(parentNormalized, ofNormalizedBase: nodeNorm) else {
            return (node, false)
        }

        var newChildren: [DiskTreeNode] = []
        newChildren.reserveCapacity(node.children.count)
        var didInsert = false
        var deltaBytes: UInt64 = 0
        var deltaFiles = 0
        var deltaFolders = 0

        for child in node.children {
            if !didInsert && child.isDirectory && isSameOrDescendant(parentNormalized, ofNormalizedBase: normalizedKey(child.url.path)) {
                let res = insertingDiskTreeNode(newNode, into: child, parentNormalized: parentNormalized)
                if res.inserted {
                    didInsert = true
                    deltaBytes = res.tree.bytes > child.bytes ? (res.tree.bytes - child.bytes) : 0
                    deltaFiles = max(0, res.tree.fileCount - child.fileCount)
                    deltaFolders = max(0, res.tree.folderCount - child.folderCount)
                }
                newChildren.append(res.tree)
            } else {
                newChildren.append(child)
            }
        }

        guard didInsert else {
            return (node, false)
        }

        newChildren.sort(by: Self.diskTreeChildrenSort)

        let updated = DiskTreeNode(
            url: node.url,
            name: node.name,
            isDirectory: node.isDirectory,
            isPackage: node.isPackage,
            isSymlink: node.isSymlink,
            bytes: node.bytes &+ deltaBytes,
            fileCount: node.fileCount + deltaFiles,
            folderCount: node.folderCount + deltaFolders,
            modificationDate: node.modificationDate,
            accessDate: node.accessDate,
            children: newChildren,
            isTruncated: node.isTruncated,
            truncatedChildCount: node.truncatedChildCount,
            isAccessible: node.isAccessible,
            isProtected: node.isProtected,
            isUserImmutable: node.isUserImmutable,
            isHidden: node.isHidden,
            expectedCanonicalParent: node.expectedCanonicalParent
        )
        return (updated, true)
    }

    private nonisolated static func deductingAggregate(
        bytes: UInt64,
        fileCount: Int,
        folderCount: Int,
        from node: DiskTreeNode,
        targetParentNormalized: String
    ) -> (tree: DiskTreeNode, deducted: Bool) {
        let nodeNorm = normalizedKey(node.url.path)
        if nodeNorm == targetParentNormalized {
            let updated = DiskTreeNode(
                url: node.url,
                name: node.name,
                isDirectory: node.isDirectory,
                isPackage: node.isPackage,
                isSymlink: node.isSymlink,
                bytes: node.bytes > bytes ? (node.bytes - bytes) : 0,
                fileCount: max(0, node.fileCount - fileCount),
                folderCount: max(0, node.folderCount - folderCount),
                modificationDate: node.modificationDate,
                accessDate: node.accessDate,
                children: node.children,
                isTruncated: node.isTruncated,
                truncatedChildCount: node.truncatedChildCount,
                isAccessible: node.isAccessible,
                isProtected: node.isProtected,
                isUserImmutable: node.isUserImmutable,
                isHidden: node.isHidden,
                expectedCanonicalParent: node.expectedCanonicalParent
            )
            return (updated, true)
        }

        guard node.isDirectory && isSameOrDescendant(targetParentNormalized, ofNormalizedBase: nodeNorm) else {
            return (node, false)
        }

        var newChildren: [DiskTreeNode] = []
        newChildren.reserveCapacity(node.children.count)
        var didDeduct = false
        var deltaBytes: UInt64 = 0
        var deltaFiles = 0
        var deltaFolders = 0

        for child in node.children {
            if !didDeduct && child.isDirectory && isSameOrDescendant(targetParentNormalized, ofNormalizedBase: normalizedKey(child.url.path)) {
                let res = deductingAggregate(
                    bytes: bytes,
                    fileCount: fileCount,
                    folderCount: folderCount,
                    from: child,
                    targetParentNormalized: targetParentNormalized
                )
                if res.deducted {
                    didDeduct = true
                    deltaBytes = child.bytes > res.tree.bytes ? (child.bytes - res.tree.bytes) : 0
                    deltaFiles = max(0, child.fileCount - res.tree.fileCount)
                    deltaFolders = max(0, child.folderCount - res.tree.folderCount)
                }
                newChildren.append(res.tree)
            } else {
                newChildren.append(child)
            }
        }

        guard didDeduct else {
            return (node, false)
        }

        newChildren.sort(by: Self.diskTreeChildrenSort)

        let updated = DiskTreeNode(
            url: node.url,
            name: node.name,
            isDirectory: node.isDirectory,
            isPackage: node.isPackage,
            isSymlink: node.isSymlink,
            bytes: node.bytes > deltaBytes ? (node.bytes - deltaBytes) : 0,
            fileCount: max(0, node.fileCount - deltaFiles),
            folderCount: max(0, node.folderCount - deltaFolders),
            modificationDate: node.modificationDate,
            accessDate: node.accessDate,
            children: newChildren,
            isTruncated: node.isTruncated,
            truncatedChildCount: node.truncatedChildCount,
            isAccessible: node.isAccessible,
            isProtected: node.isProtected,
            isUserImmutable: node.isUserImmutable,
            isHidden: node.isHidden,
            expectedCanonicalParent: node.expectedCanonicalParent
        )
        return (updated, true)
    }
}

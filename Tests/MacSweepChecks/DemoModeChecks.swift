import Foundation
import MacSweepCore

func runDemoModeChecks(_ runner: CheckRunner) {
    print("== DemoModeChecks ==")

    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    runner.run("demo_catalog_source_static_privacy_and_zero_swiftui") {
        let catalogURL = repoRoot.appendingPathComponent("Sources/MacSweepCore/Demo/DemoFixtureCatalog.swift")
        try runner.expect(FileManager.default.fileExists(atPath: catalogURL.path), "Missing DemoFixtureCatalog.swift")
        let source = try String(contentsOf: catalogURL, encoding: .utf8)

        let forbiddenTokens = [
            "import SwiftUI",
            "import AppKit",
            "NSUserName",
            "NSFullUserName",
            "NSHomeDirectory",
            "homeDirectoryForCurrentUser",
            "processInfo.userName",
            "fullUserName",
            "URLSession",
            "getpwuid",
            "FileManager.default",
            "NSWorkspace",
        ]
        for token in forbiddenTokens {
            try runner.expect(!source.contains(token), "Forbidden token '\(token)' found in DemoFixtureCatalog.swift")
        }

        let hostUser = NSUserName()
        if hostUser.count >= 3 && hostUser != "alex" {
            try runner.expect(!source.contains(hostUser), "Host username leaked in DemoFixtureCatalog.swift")
        }
    }

    runner.run("demo_exporter_source_static_privacy_and_required_shots") {
        let exporterURL = repoRoot.appendingPathComponent("Sources/MacSweepApp/State/DemoScreenshotExporter.swift")
        try runner.expect(FileManager.default.fileExists(atPath: exporterURL.path), "Missing DemoScreenshotExporter.swift")
        let source = try String(contentsOf: exporterURL, encoding: .utf8)

        let forbiddenTokens = [
            "NSUserName",
            "NSFullUserName",
            "NSHomeDirectory",
            "homeDirectoryForCurrentUser",
            "URLSession",
            "getpwuid",
            "userName",
            "fullUserName",
        ]
        for token in forbiddenTokens {
            try runner.expect(!source.contains(token), "Forbidden token '\(token)' found in DemoScreenshotExporter.swift")
        }

        let requiredShots = [
            "01-applications-dark-en.png",
            "02-file-manager-analyzer.png",
            "03-file-manager-browser.png",
            "04-junk-cleaner.png",
            "05-resource-release-duplicates.png",
            "06-resource-release-memory.png",
            "07-startup-extensions-leftovers.png",
            "08-settings-protection-light.png",
            "09-resource-release-large-files.png",
            "10-extensions.png",
            "11-leftovers.png",
            "12-showcase-zh-dark.png",
        ]
        for shot in requiredShots {
            try runner.expect(source.contains(shot), "Missing required screenshot '\(shot)' in DemoScreenshotExporter.swift")
            let diskURL = repoRoot.appendingPathComponent("docs/screenshots").appendingPathComponent(shot)
            try runner.expect(FileManager.default.fileExists(atPath: diskURL.path), "Missing committed screenshot on disk: docs/screenshots/\(shot)")
        }

        try runner.expect(source.contains("ignoresMouseEvents = true"), "DemoScreenshotExporter must disable mouse events to prevent hover nondeterminism")
        try runner.expect(source.contains(".allowsHitTesting(false)"), "DemoScreenshotExporter must disable SwiftUI hit testing to prevent hover nondeterminism")

        let hostUser = NSUserName()
        if hostUser.count >= 3 && hostUser != "alex" {
            try runner.expect(!source.contains(hostUser), "Host username leaked in DemoScreenshotExporter.swift")
        }
    }

    runner.run("demo_catalog_populates_all_seven_tabs") {
        let catalog = DemoFixtureCatalog.default
        try runner.expect(catalog.applications.count >= 5, "Expected >= 5 demo applications")
        try runner.expect(catalog.applications.contains(where: { $0.name == "NovaNote" }), "Expected NovaNote demo app")
        try runner.expect(catalog.startupItems.contains(where: { $0.scope == .userAgent && $0.isEnabled }), "Expected enabled userAgent")
        try runner.expect(catalog.startupItems.contains(where: { $0.scope == .userAgent && !$0.isEnabled }), "Expected disabled userAgent")
        try runner.expect(catalog.startupItems.contains(where: { $0.isOrphanedBinary }), "Expected orphaned startup item")
        try runner.expect(catalog.startupItems.contains(where: { $0.scope == .systemDaemon }), "Expected systemDaemon item")
        try runner.expect(catalog.startupItems.contains(where: { $0.scope == .appLoginItem }), "Expected appLoginItem")
        try runner.expect(catalog.extensionItems.contains(where: { $0.category.isBrowser }), "Expected browser extension")
        try runner.expect(catalog.extensionItems.contains(where: { !$0.category.isBrowser }), "Expected system extension")
        try runner.expect(catalog.leftoverGroups.contains(where: { $0.confidence == .high }), "Expected high-confidence leftovers")
        try runner.expect(catalog.leftoverGroups.contains(where: { $0.confidence == .medium }), "Expected medium-confidence leftovers")
        try runner.expect(!catalog.diskTree.children.isEmpty, "Expected diskTree children")
        try runner.expect(!catalog.favorites.isEmpty, "Expected file browser favorites")
        try runner.expect(!catalog.fileBrowserEntries.isEmpty, "Expected default fileBrowserEntries")
        try runner.expectEqual(Set(catalog.junkCategories.map(\.category)), Set(JunkCategory.allCases), "Expected all 5 junk categories")
        for cat in catalog.junkCategories {
            try runner.expect(!cat.entries.isEmpty, "Expected non-empty junk category \(cat.category.rawValue)")
        }
        try runner.expect(catalog.largeFiles.count >= 4, "Expected >= 4 demo large files")
        try runner.expect(catalog.duplicateGroups.count >= 3, "Expected >= 3 demo duplicate groups")
        try runner.expect(catalog.memorySnapshot.totalBytes > 0, "Expected non-zero demo memory totalBytes")
        try runner.expect(!catalog.cleanupHistory.isEmpty, "Expected demo cleanup history")
        try runner.expect(!catalog.defaultPreferences.protectedPaths.isEmpty, "Expected demo protectedPaths")
    }

    runner.run("demo_catalog_strict_alex_sanitization_and_zero_host_pii") {
        let catalog = DemoFixtureCatalog.default
        let hostUser = NSUserName()
        let hostHome = NSHomeDirectory()

        func collectDiskPaths(_ node: DiskTreeNode) -> [String] {
            [node.url.path] + node.children.flatMap(collectDiskPaths)
        }
        func collectDiskNames(_ node: DiskTreeNode) -> [String] {
            [node.name] + node.children.flatMap(collectDiskNames)
        }

        var allPaths: [String] = []
        for app in catalog.applications {
            allPaths.append(app.url.path)
            allPaths.append(contentsOf: app.serviceFiles.map(\.url.path))
        }
        for item in catalog.startupItems {
            allPaths.append(item.plistURL.path)
            if let prog = item.programPath { allPaths.append(prog) }
            if let assoc = item.associatedAppPath { allPaths.append(assoc) }
        }
        for ext in catalog.extensionItems {
            allPaths.append(ext.path.path)
            if let host = ext.hostAppPath { allPaths.append(host.path) }
        }
        allPaths.append(contentsOf: catalog.leftoverGroups.flatMap { $0.files.map(\.url.path) })
        allPaths.append(contentsOf: collectDiskPaths(catalog.diskTree))
        allPaths.append(contentsOf: catalog.favorites.map(\.url.path))
        allPaths.append(contentsOf: catalog.browserDirectories.values.flatMap { $0.map(\.url.path) })
        allPaths.append(contentsOf: catalog.junkCategories.flatMap { $0.entries.map(\.url.path) })
        allPaths.append(contentsOf: catalog.largeFiles.map(\.url.path))
        allPaths.append(contentsOf: catalog.duplicateGroups.flatMap { $0.files.map(\.url.path) })
        allPaths.append(contentsOf: catalog.defaultPreferences.protectedPaths)
        allPaths.append(contentsOf: catalog.cleanupHistory.flatMap(\.removedPaths))

        for path in allPaths where path.hasPrefix("/Users/") {
            let valid = path == "/Users/alex" || path.hasPrefix("/Users/alex/")
            try runner.expect(valid, "User-scoped path must belong to /Users/alex, got: \(path)")
        }

        var allStrings: [String] = allPaths
        allStrings.append(contentsOf: collectDiskNames(catalog.diskTree))
        for app in catalog.applications {
            allStrings.append(app.name)
            allStrings.append(app.localizedName)
            allStrings.append(app.bundleID)
            if let dev = app.developerName { allStrings.append(dev) }
        }
        for cat in catalog.junkCategories {
            allStrings.append(cat.title)
            allStrings.append(cat.description)
            allStrings.append(contentsOf: cat.entries.map(\.name))
        }
        allStrings.append(contentsOf: catalog.cleanupHistory.map(\.actionTitle))

        for str in allStrings where !str.isEmpty {
            try runner.expect(!str.contains(hostHome), "Leaked real host home in demo string: \(str)")
            if hostUser.count >= 3 && hostUser != "alex" {
                try runner.expect(!str.contains("/Users/\(hostUser)"), "Leaked real username in demo string: \(str)")
            }
        }

        for app in catalog.applications {
            try runner.expect(app.bundleID != "local.macsweep", "Demo app must not expose MacSweep bundle ID")
            try runner.expect(!app.bundleID.hasPrefix("com.apple."), "Demo app must not expose Apple system bundle ID")
        }
    }

    runner.run("demo_catalog_deterministic_across_repeated_calls") {
        let first = DemoFixtureCatalog.makeDefault()
        let second = DemoFixtureCatalog.makeDefault()
        try runner.expectEqual(first, second, "DemoFixtureCatalog.makeDefault() must be deterministic")
        try runner.expectEqual(first.applications, second.applications)
        try runner.expectEqual(first.startupItems, second.startupItems)
        try runner.expectEqual(first.extensionItems, second.extensionItems)
        try runner.expectEqual(first.leftoverGroups, second.leftoverGroups)
        try runner.expectEqual(first.diskTree, second.diskTree)
        try runner.expectEqual(first.junkScanResult, second.junkScanResult)
        try runner.expectEqual(first.largeFiles, second.largeFiles)
        try runner.expectEqual(first.duplicateGroups, second.duplicateGroups)
        try runner.expectEqual(first.memorySnapshot, second.memorySnapshot)
        try runner.expectEqual(first.cleanupHistory, second.cleanupHistory)
    }

    runner.run("demo_catalog_explicit_canonical_parents_and_ids") {
        let catalog = DemoFixtureCatalog.default

        func expectedParent(_ url: URL) -> String {
            let p = url.standardizedFileURL.deletingLastPathComponent().path
            return p.isEmpty ? "/" : p
        }

        for app in catalog.applications {
            try runner.expect(!app.id.isEmpty)
            try runner.expectEqual(app.expectedCanonicalParent, expectedParent(app.url))
            for sf in app.serviceFiles {
                try runner.expect(!sf.id.isEmpty)
                try runner.expectEqual(sf.expectedCanonicalParent, expectedParent(sf.url))
            }
        }
        for item in catalog.startupItems {
            try runner.expect(!item.id.isEmpty)
            try runner.expectEqual(item.expectedCanonicalParent, expectedParent(item.plistURL))
        }
        for ext in catalog.extensionItems {
            try runner.expect(!ext.id.isEmpty)
            try runner.expectEqual(ext.expectedCanonicalParent, expectedParent(ext.path))
        }
        for cat in catalog.junkCategories {
            for entry in cat.entries {
                try runner.expect(!entry.id.isEmpty)
                try runner.expectEqual(entry.expectedCanonicalParent, expectedParent(entry.url))
            }
        }
        for item in catalog.largeFiles {
            try runner.expect(!item.id.isEmpty)
            try runner.expectEqual(item.expectedCanonicalParent, expectedParent(item.url))
        }
        for group in catalog.duplicateGroups {
            for file in group.files {
                try runner.expect(!file.id.isEmpty)
                try runner.expectEqual(file.expectedCanonicalParent, expectedParent(file.url))
            }
        }
    }

    runner.run("demo_catalog_safety_guard_compatibility") {
        let catalog = DemoFixtureCatalog.default
        let sg = DemoFixtureCatalog.demoSafetyGuard

        for cat in catalog.junkCategories where cat.category == .userCaches || cat.category == .browserCaches {
            for entry in cat.entries {
                let res = sg.validateCacheSubpath(entry.url)
                try runner.expect(res.isAllowed, "Cache entry blocked by validateCacheSubpath: \(entry.url.path) -> \(res)")
            }
        }

        for app in catalog.applications {
            let pathRes = sg.validateForRemoval(app.url)
            let isUserProt = sg.isUserProtected(bundleID: app.bundleID, url: app.url)
            if app.canUninstall {
                try runner.expect(pathRes.isAllowed && !isUserProt, "Uninstallable demo app blocked: \(app.url.path)")
            } else {
                try runner.expect(isUserProt || !pathRes.isAllowed, "Protected demo app should be blocked: \(app.url.path)")
            }
        }

        for protectedPath in catalog.defaultPreferences.protectedPaths {
            let res = sg.validateForRemoval(URL(fileURLWithPath: protectedPath))
            try runner.expect(!res.isAllowed, "Protected path should be blocked: \(protectedPath)")
        }
    }

    runner.run("demo_catalog_disk_tree_and_filter_compatibility") {
        let catalog = DemoFixtureCatalog.default
        let children = catalog.diskTree.children
        try runner.expect(children.count >= 4, "Expected >= 4 top-level folders in diskTree")
        for i in 0..<(children.count - 1) {
            try runner.expect(children[i].bytes >= children[i + 1].bytes, "diskTree children must be sorted descending")
        }
        let childSum = children.reduce(UInt64(0)) { $0 &+ $1.bytes }
        try runner.expect(catalog.diskTree.bytes >= childSum, "Root diskTree bytes must >= sum of direct children")
        try runner.expectEqual(catalog.volumeInfo.usedBytes + catalog.volumeInfo.availableBytes, catalog.volumeInfo.totalBytes)

        func normPath(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        }

        let normalizedBrowserDirs: [String: [FileBrowserEntry]] = Dictionary(
            catalog.browserDirectories.map { (normPath($0.key), $0.value) },
            uniquingKeysWith: { _, latest in latest }
        )

        func verifyDiskTreeRollups(_ node: DiskTreeNode) throws {
            if node.children.count > 1 {
                for i in 0..<(node.children.count - 1) {
                    try runner.expect(
                        node.children[i].bytes >= node.children[i + 1].bytes,
                        "DiskTreeNode \(node.url.path) children must be sorted descending"
                    )
                }
            }

            let explicitBytes = node.children.reduce(UInt64(0)) { $0 &+ $1.bytes }
            let explicitFiles = node.children.reduce(0) { $0 + $1.fileCount }
            let explicitFolders = node.children.reduce(0) { acc, child in
                acc + ((child.isDirectory && !child.isSymlink) ? (1 + child.folderCount) : 0)
            }

            let nodeNorm = normPath(node.url.path)
            let browserEntries = normalizedBrowserDirs[nodeNorm] ?? []
            let explicitByNorm: [String: DiskTreeNode] = Dictionary(
                node.children.map { (normPath($0.url.path), $0) },
                uniquingKeysWith: { first, _ in first }
            )

            for entry in browserEntries {
                if let explicitChild = explicitByNorm[normPath(entry.url.path)] {
                    try runner.expectEqual(
                        UInt64(max(0, entry.sizeBytes)),
                        explicitChild.bytes,
                        "Browser entry \(entry.url.path) bytes must match explicit DiskTreeNode child"
                    )
                }
            }

            let unlistedNonSymlink = browserEntries.filter { entry in
                !entry.isSymbolicLink && explicitByNorm[normPath(entry.url.path)] == nil
            }
            let unlistedBytes = unlistedNonSymlink.reduce(UInt64(0)) { $0 &+ UInt64(max(0, $1.sizeBytes)) }
            let unlistedFiles = unlistedNonSymlink.filter { !$0.isDirectory }.count
            let unlistedFolders = unlistedNonSymlink.filter(\.isDirectory).count

            let minBytes = explicitBytes &+ unlistedBytes
            let minFiles = explicitFiles + unlistedFiles
            let minFolders = explicitFolders + unlistedFolders

            try runner.expect(
                node.bytes >= minBytes,
                "DiskTreeNode \(node.url.path) bytes (\(node.bytes)) must >= explicit (\(explicitBytes)) + unlisted (\(unlistedBytes)) = \(minBytes)"
            )
            try runner.expect(
                node.fileCount >= minFiles,
                "DiskTreeNode \(node.url.path) fileCount (\(node.fileCount)) must >= explicit (\(explicitFiles)) + unlisted (\(unlistedFiles)) = \(minFiles)"
            )
            try runner.expect(
                node.folderCount >= minFolders,
                "DiskTreeNode \(node.url.path) folderCount (\(node.folderCount)) must >= explicit (\(explicitFolders)) + unlisted (\(unlistedFolders)) = \(minFolders)"
            )

            for child in node.children {
                try verifyDiskTreeRollups(child)
            }
        }
        try verifyDiskTreeRollups(catalog.diskTree)
        try verifyDiskTreeRollups(catalog.applicationsDiskTree)

        let largeFiltered = DiskSpaceAnalyzer.filterNodes(
            in: catalog.diskTree,
            filter: DiskEntryFilter(minBytes: 100_000_000),
            referenceDate: DemoFixtureCatalog.referenceDate
        )
        try runner.expect(!largeFiltered.isEmpty, "Expected DiskSpaceAnalyzer.filterNodes to find large demo items")
    }

    runner.run("demo_catalog_file_browser_hidden_sort_search_and_previews") {
        let catalog = DemoFixtureCatalog.default
        let docsURL = URL(fileURLWithPath: "/Users/alex/Documents")

        let visibleOnly = catalog.fileBrowserEntries(at: docsURL, showHidden: false, sortBy: .name, ascending: true)
        let withHidden = catalog.fileBrowserEntries(at: docsURL, showHidden: true, sortBy: .name, ascending: true)
        try runner.expect(withHidden.count > visibleOnly.count, "showHidden=true must reveal hidden demo items")
        try runner.expect(!visibleOnly.contains(where: { $0.isHidden }), "showHidden=false must hide dotfiles")

        let searched = catalog.fileBrowserEntries(at: docsURL, showHidden: true, sortBy: .name, ascending: true, searchQuery: "Release")
        try runner.expect(searched.contains(where: { $0.name == "Q4-Release-Notes.md" }), "Search query must match Q4-Release-Notes.md")

        let textPayload = catalog.previewPayload(for: URL(fileURLWithPath: "/Users/alex/Documents/Q4-Release-Notes.md"))
        if case .text = textPayload.content {} else {
            try runner.expect(false, "Expected .text preview for Q4-Release-Notes.md")
        }

        let hexPayload = catalog.previewPayload(for: URL(fileURLWithPath: "/Users/alex/Downloads/macOS-15-Installer.dmg"))
        if case .hexDump = hexPayload.content {} else {
            try runner.expect(false, "Expected .hexDump preview for macOS-15-Installer.dmg")
        }

        let dirPayload = catalog.previewPayload(for: URL(fileURLWithPath: "/Users/alex/Documents/Architecture-RFCs"))
        if case .unavailable(.directory) = dirPayload.content {} else {
            try runner.expect(false, "Expected .unavailable(.directory) for Architecture-RFCs")
        }

        let symPayload = catalog.previewPayload(for: URL(fileURLWithPath: "/Users/alex/Documents/latest-rfc-link"))
        if case .unavailable(.symbolicLink) = symPayload.content {} else {
            try runner.expect(false, "Expected .unavailable(.symbolicLink) for latest-rfc-link")
        }
    }

    runner.run("demo_catalog_startup_plist_xml_valid") {
        let catalog = DemoFixtureCatalog.default
        for item in catalog.startupItems where item.plistURL.pathExtension.lowercased() == "plist" {
            let xml = catalog.plistPreview(for: item.plistURL)
            try runner.expect(xml != nil, "Missing demo plist preview for \(item.plistURL.path)")
            let data = Data((xml ?? "").utf8)
            let parsed = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            try runner.expect(parsed != nil, "Demo plist preview must parse cleanly: \(item.plistURL.path)")
            try runner.expectEqual(parsed?["Label"] as? String, item.label)
        }
    }

    runner.run("demo_catalog_duplicates_and_memory_invariants") {
        let catalog = DemoFixtureCatalog.default
        for group in catalog.duplicateGroups {
            try runner.expect(group.files.count >= 2, "DuplicateGroup must have >= 2 copies")
            try runner.expectEqual(group.sha256Hex.count, 64, "SHA-256 hex must be 64 characters")
            try runner.expectEqual(group.reclaimableBytes, group.fileSize * UInt64(group.files.count - 1))
            try runner.expect(!group.allCopiesSelected, "Default duplicate group must keep >= 1 copy unselected")
        }

        let snap = catalog.memorySnapshot
        try runner.expect(snap.usedBytes <= snap.totalBytes, "MemorySnapshot usedBytes <= totalBytes")
        try runner.expect(snap.swapUsedBytes <= snap.swapTotalBytes, "MemorySnapshot swapUsed <= swapTotal")

        let stdRel = catalog.memoryReleaseResult(from: snap, elevated: false)
        try runner.expectEqual(stdRel.after.totalBytes, snap.totalBytes)
        try runner.expect(!stdRel.usedElevation)
        try runner.expect(stdRel.reclaimedEstimateBytes > 0)

        let elevRel = catalog.memoryReleaseResult(from: snap, elevated: true)
        try runner.expectEqual(elevRel.after.totalBytes, snap.totalBytes)
        try runner.expect(elevRel.usedElevation)
        try runner.expect(elevRel.reclaimedEstimateBytes > stdRel.reclaimedEstimateBytes)
    }

    runner.run("demo_mode_isolation_and_sort_stability") {
        let catalog = DemoFixtureCatalog.default
        let docsURL = URL(fileURLWithPath: "/Users/alex/Documents")
        for sort in FileBrowserSort.allCases {
            let asc = catalog.fileBrowserEntries(at: docsURL, showHidden: true, sortBy: sort, ascending: true)
            let desc = catalog.fileBrowserEntries(at: docsURL, showHidden: true, sortBy: sort, ascending: false)
            try runner.expectEqual(asc.count, desc.count, "Ascending and descending sorts must preserve item count for \(sort.rawValue)")
            try runner.expectEqual(Set(asc.map(\.id)), Set(desc.map(\.id)), "Ascending and descending sorts must preserve item set for \(sort.rawValue)")
        }

        let appStateURL = repoRoot.appendingPathComponent("Sources/MacSweepApp/State/AppState.swift")
        let appStateSrc = try String(contentsOf: appStateURL, encoding: .utf8)
        try runner.expect(
            !appStateSrc.contains("private let prefsStore = PreferencesStore()")
                && !appStateSrc.contains("private let historyStore = CleanupHistoryStore()"),
            "PreferencesStore and CleanupHistoryStore must be deferred/optional so Demo Mode init never resolves real AppSupport"
        )
        let lines = appStateSrc.components(separatedBy: .newlines)
        for (idx, line) in lines.enumerated() {
            if line.contains(".isUserImmutable(") {
                try runner.expect(line.contains("isDemoMode ? false :"), "Unguarded isUserImmutable call at AppState.swift:\(idx + 1)")
            }
            if line.contains(".requiresAdmin(for:") {
                try runner.expect(line.contains("isDemoMode ?"), "Unguarded requiresAdmin(for:) call at AppState.swift:\(idx + 1)")
            }
        }

        let fmStoreURL = repoRoot.appendingPathComponent("Sources/MacSweepApp/State/FileManagerStore.swift")
        let fmStoreSrc = try String(contentsOf: fmStoreURL, encoding: .utf8)
        let fmLines = fmStoreSrc.components(separatedBy: .newlines)
        for (idx, line) in fmLines.enumerated() where line.contains(".requiresAdmin(for:") {
            try runner.expect(line.contains("isDemo ?"), "Unguarded requiresAdmin(for:) call at FileManagerStore.swift:\(idx + 1)")
        }
        try runner.expect(fmStoreSrc.contains("migratedPreviewPayload"), "FileManagerStore demo move/rename must migrate demoPreviews")
    }
}

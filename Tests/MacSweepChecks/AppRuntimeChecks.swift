import Foundation
import MacSweepCore
import MacSweepUI

private func check(_ condition: Bool, _ message: String = "Assertion failed", file: String = #fileID, line: Int = #line) throws {
    if !condition {
        throw CheckFailure(message: "\(message) (\(file):\(line))")
    }
}

private func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String = "", file: String = #fileID, line: Int = #line) throws {
    if lhs != rhs {
        let prefix = message.isEmpty ? "" : "\(message) — "
        throw CheckFailure(message: "\(prefix)expected '\(rhs)', got '\(lhs)' (\(file):\(line))")
    }
}

@MainActor
private func runOnMainActorAsync(_ work: @escaping @MainActor () async throws -> Void) throws {
    var finished = false
    var capturedError: Error?
    Task { @MainActor in
        do {
            try await work()
        } catch {
            capturedError = error
        }
        finished = true
    }
    let deadline = Date().addingTimeInterval(15)
    while !finished && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
    }
    if !finished {
        throw CheckFailure(message: "Timed out waiting for @MainActor async block")
    }
    if let capturedError {
        throw capturedError
    }
}

func runAppRuntimeChecks(_ runner: CheckRunner) {
    print("== AppRuntimeChecks (MacSweepUI Stores & Gaps 1-5, 7) ==")

    runner.run("Gap 1: Cross-tab applyIncrementalRemoval removes descendant entries across all tabs when parent folder is deleted") {
        try MainActor.assumeIsolated {
            try runOnMainActorAsync {
                let state = AppState(launchOptions: DemoLaunchOptions(isDemoMode: true))
                let mlDir = URL(fileURLWithPath: "/Users/alex/Projects/ml-datasets")
                let mockupsDir = URL(fileURLWithPath: "/Users/alex/Desktop/Demo-Mockups")
                let vendorDir = URL(fileURLWithPath: "/Users/alex/Projects/swift-studio/vendor")
                let libCacheDir = URL(fileURLWithPath: "/Users/alex/Library/Caches")
                let appSupportDir = URL(fileURLWithPath: "/Users/alex/Library/Application Support")

                try check(state.cleanupCenterStore.largeFiles.contains(where: { $0.url.path.hasPrefix(mlDir.path + "/") }))
                try check(state.cleanupCenterStore.duplicateGroups.flatMap(\.files).contains(where: {
                    $0.url.path.hasPrefix(mockupsDir.path + "/") || $0.url.path.hasPrefix(vendorDir.path + "/")
                }))

                let items: [(url: URL, size: Int64, requiresAdmin: Bool, expectedCanonicalParent: String)] = [
                    (mlDir, 1024, false, mlDir.deletingLastPathComponent().path),
                    (mockupsDir, 1024, false, mockupsDir.deletingLastPathComponent().path),
                    (vendorDir, 1024, false, vendorDir.deletingLastPathComponent().path),
                ]
                state.prepareRemovalForFileManagerItems(items, title: "Remove parent folders")
                try check(state.pendingConfirmation != nil, "Expected pendingConfirmation for parent folders")
                await state.executePendingConfirmation(mode: .trash)

                try check(!state.cleanupCenterStore.largeFiles.contains(where: { $0.url.path.hasPrefix(mlDir.path + "/") }), "Zombie large file remained after parent folder deletion")
                try check(!state.cleanupCenterStore.duplicateGroups.flatMap(\.files).contains(where: {
                    $0.url.path.hasPrefix(mockupsDir.path + "/") || $0.url.path.hasPrefix(vendorDir.path + "/")
                }), "Zombie duplicate copy remained after parent folder deletion")

                let parentSubdirs = Set([
                    libCacheDir.appendingPathComponent("com.novanote.desktop").path,
                ])
                state.cleanupCenterStore.applyIncrementalRemoval(removedPaths: parentSubdirs)
                try check(!state.cleanupCenterStore.junkCategories.flatMap(\.entries).contains(where: {
                    $0.url.path.hasPrefix(libCacheDir.appendingPathComponent("com.novanote.desktop").path)
                }))

                let extSubdir = URL(fileURLWithPath: "/Users/alex/Library/Application Support/Google/Chrome/Default/Extensions")
                let leftoverSubdir = URL(fileURLWithPath: "/Users/alex/Library/Application Support/VeloxVPN")
                let novaSupport = URL(fileURLWithPath: "/Users/alex/Library/Application Support/NovaNote")
                state.prepareRemovalForFileManagerItems(
                    [
                        (extSubdir, 100, false, extSubdir.deletingLastPathComponent().path),
                        (leftoverSubdir, 100, false, appSupportDir.path),
                        (novaSupport, 100, false, appSupportDir.path),
                    ],
                    title: "Remove parent app support subdirs"
                )
                await state.executePendingConfirmation(mode: .trash)

                try check(!state.extensionItems.contains(where: { $0.path.path.hasPrefix(extSubdir.path + "/") }), "Extension descendant should be cleared")
                try check(!state.leftoverGroups.flatMap(\.files).contains(where: { $0.url.path.hasPrefix(leftoverSubdir.path) }), "Leftover descendant should be cleared")
                let novaServices = state.apps.first(where: { $0.name == "NovaNote" })?.serviceFiles ?? []
                try check(!novaServices.contains(where: { $0.url.path.hasPrefix(novaSupport.path) }), "App serviceFile descendant should be cleared")
            }
        }
    }

    runner.run("Gap 2: savePreferences protection blocks Startup, Extension, and Leftover targets and Demo executePendingConfirmation refuses protected targets") {
        try MainActor.assumeIsolated {
            try runOnMainActorAsync {
                let state = AppState(launchOptions: DemoLaunchOptions(isDemoMode: true))
                guard let startup = state.startupItems.first(where: \.canRemove),
                      let ext = state.extensionItems.first(where: \.canRemove),
                      let leftoverGroup = state.leftoverGroups.first(where: { $0.isChecked && !$0.files.isEmpty }),
                      let leftoverFile = leftoverGroup.files.first(where: \.isSelected) else {
                    try check(false, "Missing demo startup/extension/leftover fixtures")
                    return
                }

                state.preferences.protectedPaths.append(contentsOf: [
                    startup.plistURL.path,
                    ext.path.path,
                    leftoverFile.url.path,
                ])
                try check(state.savePreferences())

                state.pendingConfirmation = nil
                state.prepareRemovalForStartupItem(startup)
                try check(state.pendingConfirmation == nil, "Protected startup item must not open confirmation")
                try checkEqual(state.banner?.isError, true)

                state.pendingConfirmation = nil
                state.banner = nil
                state.prepareRemovalForExtension(ext)
                try check(state.pendingConfirmation == nil, "Protected extension must not open confirmation")
                try checkEqual(state.banner?.isError, true)

                if let updatedGroupIdx = state.leftoverGroups.firstIndex(where: { $0.id == leftoverGroup.id }),
                   let updatedFileIdx = state.leftoverGroups[updatedGroupIdx].files.firstIndex(where: { $0.id == leftoverFile.id }) {
                    try check(!state.leftoverGroups[updatedGroupIdx].files[updatedFileIdx].isSelected, "savePreferences must uncheck protected leftover file")
                    state.leftoverGroups[updatedGroupIdx].files[updatedFileIdx].isSelected = true
                    state.leftoverGroups[updatedGroupIdx].isChecked = true
                }
                state.pendingConfirmation = nil
                state.prepareRemovalForCheckedLeftovers()
                let queuedPaths = Set(state.pendingConfirmation?.targets.map(\.url.path) ?? [])
                try check(!queuedPaths.contains(leftoverFile.url.path), "Protected leftover file must never be queued in pendingConfirmation")

                let beforeCount = state.startupItems.count
                state.pendingConfirmation = PendingConfirmation(
                    title: "Direct protected probe",
                    isReset: false,
                    targets: [RemovalTarget(url: startup.plistURL, estimatedSize: 100, requiresAdmin: false, expectedCanonicalParent: startup.expectedCanonicalParent)],
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
                    affectedStartupIDs: [startup.id],
                    affectedExtensionIDs: [],
                    affectedLeftoverIDs: []
                )
                await state.executePendingConfirmation(mode: .trash)
                try checkEqual(state.startupItems.count, beforeCount, "Demo executePendingConfirmation must refuse protected targets")
                try checkEqual(state.banner?.isError, true)
            }
        }
    }

    runner.run("Gap 3 & 4: FileManagerStore syncs demo canonicalPath, clears stale inspector on goUp/moveEntries, prunes protected selection, and blocks analyzer symlink delete") {
        try MainActor.assumeIsolated {
            try runOnMainActorAsync {
                let state = AppState(launchOptions: DemoLaunchOptions(isDemoMode: true))
                let fmStore = state.fileManagerStore

                try checkEqual(fmStore.currentDirectoryCanonicalPath, fmStore.currentDirectoryURL.standardizedFileURL.path)

                let rfcLink = URL(fileURLWithPath: "/Users/alex/Documents/latest-rfc-link")
                fmStore.inspectAndPreview(url: rfcLink)
                try checkEqual(fmStore.inspectedURL?.path, rfcLink.path)
                fmStore.goUp()
                try checkEqual(fmStore.currentDirectoryURL.path, "/Users/alex")
                try checkEqual(fmStore.currentDirectoryCanonicalPath, "/Users/alex")
                try check(fmStore.inspectedURL == nil, "goUp() must clear stale inspectedURL")
                try check(fmStore.inspectedMetadata == nil, "goUp() must clear stale inspectedMetadata")
                try checkEqual(fmStore.previewState, .none, "goUp() must clear stale previewState")

                let docsURL = URL(fileURLWithPath: "/Users/alex/Documents")
                await fmStore.loadDirectory(docsURL, pushHistory: false)
                guard let deckEntry = fmStore.browserEntries.first(where: { $0.name == "Q3-Product-Deck.pdf" }) else {
                    try check(false, "Missing Q3-Product-Deck.pdf demo entry")
                    return
                }
                fmStore.inspectAndPreview(url: deckEntry.url)
                try checkEqual(fmStore.inspectedURL?.path, deckEntry.url.path)
                await fmStore.moveEntries([deckEntry], to: URL(fileURLWithPath: "/Users/alex/Downloads"))
                try check(fmStore.inspectedURL == nil, "moveEntries must clear stale inspectedURL for moved file")

                guard let archEntry = fmStore.browserEntries.first(where: { $0.name == "Architecture-RFCs" }) else {
                    try check(false, "Missing Architecture-RFCs demo entry")
                    return
                }
                fmStore.selectedBrowserEntryIDs = [archEntry.id]
                try check(fmStore.selectedBrowserBytes > 0)
                fmStore.protectURLs([archEntry.url])
                try check(!fmStore.selectedBrowserEntryIDs.contains(archEntry.id), "protectURLs must prune protected item from selectedBrowserEntryIDs")
                try checkEqual(fmStore.selectedBrowserBytes, 0, "selectedBrowserBytes must drop to 0 after protecting selected item")

                if let currentNode = fmStore.currentAnalyzerNode {
                    let symNode = DiskTreeNode(
                        url: URL(fileURLWithPath: "/Users/alex/sym-node"),
                        name: "sym-node",
                        isDirectory: false,
                        isPackage: false,
                        isSymlink: true,
                        bytes: 0,
                        fileCount: 0,
                        folderCount: 0,
                        modificationDate: nil,
                        accessDate: nil,
                        children: [],
                        isTruncated: false,
                        truncatedChildCount: 0,
                        isAccessible: true,
                        isProtected: false,
                        isUserImmutable: false,
                        expectedCanonicalParent: "/Users/alex"
                    )
                    fmStore.analyzerRootNode = DiskTreeNode(
                        url: currentNode.url,
                        name: currentNode.name,
                        isDirectory: true,
                        isPackage: false,
                        isSymlink: false,
                        bytes: currentNode.bytes,
                        fileCount: currentNode.fileCount,
                        folderCount: currentNode.folderCount,
                        modificationDate: currentNode.modificationDate,
                        accessDate: currentNode.accessDate,
                        children: [symNode] + currentNode.children,
                        isTruncated: currentNode.isTruncated,
                        truncatedChildCount: currentNode.truncatedChildCount,
                        isAccessible: currentNode.isAccessible,
                        isProtected: currentNode.isProtected,
                        isUserImmutable: currentNode.isUserImmutable,
                        expectedCanonicalParent: currentNode.expectedCanonicalParent
                    )
                    fmStore.analyzerBreadcrumbIDs = []
                    fmStore.selectedAnalyzerNodeIDs = [symNode.id]
                    state.pendingConfirmation = nil
                    state.banner = nil
                    fmStore.requestRemovalForAnalyzerSelection(preferredMode: .trash)
                    try check(state.pendingConfirmation == nil)
                    try checkEqual(state.banner?.isError, true, "Symlink-only analyzer removal must surface explicit error banner")
                }
            }
        }
    }

    runner.run("Gap 5 & 7: duplicateMinSizePreset updates filteredDuplicateGroups/scanDuplicates and DemoLaunchOptions catches invalid CLI combinations") {
        try MainActor.assumeIsolated {
            let state = AppState(launchOptions: DemoLaunchOptions(isDemoMode: true))
            let store = state.cleanupCenterStore
            let beforeCount = store.filteredDuplicateGroups.count
            try check(beforeCount > 0)

            store.duplicateMinSizePreset = .mb100
            try check(store.filteredDuplicateGroups.count < beforeCount, "Raising duplicateMinSizePreset to 100MB must filter smaller demo groups")
            store.scanDuplicates()
            try checkEqual(store.duplicateGroups.count, store.filteredDuplicateGroups.count)
            try check(store.duplicateGroups.allSatisfy { $0.fileSize >= DuplicateMinSizePreset.mb100.rawValue })

            let noDemoExport = DemoLaunchOptions.fromProcessInfo(
                arguments: ["MacSweepApp", "--export-screenshots", "/tmp/out"],
                environment: [:]
            )
            try check(noDemoExport.parseError != nil, "--export-screenshots without --demo-mode must set parseError")

            let badTab = DemoLaunchOptions.fromProcessInfo(
                arguments: ["MacSweepApp", "--demo-mode", "--demo-tab", "nonexistent"],
                environment: [:]
            )
            try check(badTab.parseError != nil, "Unknown --demo-tab must set parseError")

            let validOpts = DemoLaunchOptions.fromProcessInfo(
                arguments: ["MacSweepApp", "--demo-mode", "--demo-tab", "fileManager", "--export-screenshots", "/tmp/out"],
                environment: [:]
            )
            try checkEqual(validOpts.parseError, nil)
            try checkEqual(validOpts.initialTab, .fileManager)
            try checkEqual(validOpts.isDemoMode, true)
        }
    }

    runner.run("Real-mode FileManagerStore.applyIncrementalRemoval prunes stale analyzerBreadcrumbIDs") {
        try MainActor.assumeIsolated {
            let rootURL = URL(fileURLWithPath: "/tmp/ProbeWork")
            let folderAURL = rootURL.appendingPathComponent("FolderA")
            let subBURL = folderAURL.appendingPathComponent("SubB")
            let subBNode = DiskTreeNode(
                url: subBURL,
                name: "SubB",
                isDirectory: true,
                isPackage: false,
                isSymlink: false,
                bytes: 512,
                fileCount: 1,
                folderCount: 0,
                modificationDate: nil,
                accessDate: nil,
                children: [],
                isTruncated: false,
                truncatedChildCount: 0,
                isAccessible: true,
                isProtected: false,
                isUserImmutable: false,
                expectedCanonicalParent: folderAURL.path
            )
            let folderANode = DiskTreeNode(
                url: folderAURL,
                name: "FolderA",
                isDirectory: true,
                isPackage: false,
                isSymlink: false,
                bytes: 512,
                fileCount: 1,
                folderCount: 1,
                modificationDate: nil,
                accessDate: nil,
                children: [subBNode],
                isTruncated: false,
                truncatedChildCount: 0,
                isAccessible: true,
                isProtected: false,
                isUserImmutable: false,
                expectedCanonicalParent: rootURL.path
            )
            let rootNode = DiskTreeNode(
                url: rootURL,
                name: "ProbeWork",
                isDirectory: true,
                isPackage: false,
                isSymlink: false,
                bytes: 512,
                fileCount: 1,
                folderCount: 2,
                modificationDate: nil,
                accessDate: nil,
                children: [folderANode],
                isTruncated: false,
                truncatedChildCount: 0,
                isAccessible: true,
                isProtected: false,
                isUserImmutable: false,
                expectedCanonicalParent: "/tmp"
            )

            let store = FileManagerStore(initialDirectory: rootURL)
            store.analyzerRootNode = rootNode
            store.drillIntoAnalyzerNode(folderANode)
            store.drillIntoAnalyzerNode(subBNode)
            try checkEqual(store.analyzerBreadcrumbIDs, [folderANode.id, subBNode.id])

            // Removing SubB truncates breadcrumb stack to [FolderA]
            store.applyIncrementalRemoval(removedPaths: [subBURL.path])
            try checkEqual(store.analyzerBreadcrumbIDs, [folderANode.id])
            try checkEqual(store.currentAnalyzerNode?.id, folderANode.id)

            // Removing FolderA empties analyzerBreadcrumbIDs completely
            store.applyIncrementalRemoval(removedPaths: [folderAURL.path])
            try checkEqual(store.analyzerBreadcrumbIDs, [])
            try checkEqual(store.currentAnalyzerNode?.id, rootNode.id)
        }
    }

    runner.run("Audit regression: Mixed Junk+Trash preserves Trash-first for caches while emptying Trash permanently, and FileManager Trash-only forces permanent") {
        try MainActor.assumeIsolated {
            try runOnMainActorAsync {
                let state = AppState(launchOptions: DemoLaunchOptions(isDemoMode: true))
                state.pendingConfirmation = nil
                let initialHistoryCount = state.cleanupHistory.count

                // Demo Mode has both normal caches/logs and ~/.Trash entries selected by default.
                state.cleanupCenterStore.requestRemovalForSelectedJunk()
                guard let conf = state.pendingConfirmation else {
                    try check(false, "Expected pendingConfirmation for selected junk")
                    return
                }
                try check(conf.hasTrashItems, "Mixed junk selection must set hasTrashItems == true")
                try check(!conf.forcePermanentMode, "Mixed junk+Trash selection must NOT force permanent mode on non-Trash caches")
                try check(conf.preferredRemovalModeOverride == nil, "Mixed selection must preserve user's Trash-first default mode")

                await state.executePendingConfirmation(mode: .trash)
                try checkEqual(state.cleanupHistory.count, initialHistoryCount + 2, "Mixed execution must record separate .trash and .permanent history entries")
                let recentTwo = Array(state.cleanupHistory.prefix(2))
                try check(recentTwo.contains(where: { $0.mode == .trash }), "Non-Trash caches must be recorded with .trash mode")
                try check(recentTwo.contains(where: { $0.mode == .permanent }), "Trash items must be recorded with .permanent mode")

                // Trash-only File Manager deletion MUST force permanent mode.
                state.pendingConfirmation = nil
                state.prepareRemovalForFileManagerItems(
                    [(
                        url: URL(fileURLWithPath: "/Users/alex/.Trash/solo-item.zip"),
                        size: 512,
                        requiresAdmin: false,
                        expectedCanonicalParent: "/Users/alex/.Trash"
                    )],
                    title: "Empty Single Trash File",
                    preferredRemovalModeOverride: .trash
                )
                guard let trashOnlyConf = state.pendingConfirmation else {
                    try check(false, "Expected pendingConfirmation for Trash-only File Manager item")
                    return
                }
                try check(trashOnlyConf.hasTrashItems)
                try check(trashOnlyConf.forcePermanentMode, "Trash-only File Manager deletion must set forcePermanentMode == true")
                try checkEqual(trashOnlyConf.preferredRemovalModeOverride, .permanent)
            }
        }
    }

    runner.run("Audit regression: ByteFormatter.formatMemory uses binary units and FileManagerStore searches in-memory while skipping protected single-click selection") {
        let sandbox = try runner.makeTempSandbox(prefix: "fm-inmem-search")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        try MainActor.assumeIsolated {
            try runOnMainActorAsync {
                try checkEqual(ByteFormatter.formatMemory(UInt64(32) * 1024 * 1024 * 1024), "32 GB")
                try checkEqual(ByteFormatter.formatMemory(UInt64(16) * 1024 * 1024 * 1024), "16 GB")

                let alphaFile = sandbox.appendingPathComponent("alpha-notes.txt")
                let betaFile = sandbox.appendingPathComponent("beta-data.bin")
                try Data("alpha".utf8).write(to: alphaFile)
                try Data("beta".utf8).write(to: betaFile)

                let store = FileManagerStore(initialDirectory: sandbox)
                await store.loadDirectory(sandbox, pushHistory: false)
                try checkEqual(store.browserEntries.count, 2)

                // In-memory search must update browserEntries synchronously without re-reading disk.
                store.updateBrowserSearchText("alpha")
                try checkEqual(store.browserEntries.map(\.name), ["alpha-notes.txt"])
                store.updateBrowserSearchText("")
                try checkEqual(store.browserEntries.count, 2)

                // Demo protected entry clicked via selectSingleBrowserEntry must focus/inspect without selecting for bulk actions.
                let demoState = AppState(launchOptions: DemoLaunchOptions(isDemoMode: true))
                let demoFM = demoState.fileManagerStore
                await demoFM.loadDirectory(URL(fileURLWithPath: "/Users/alex/Documents"), pushHistory: false)
                guard let protectedEntry = demoFM.browserEntries.first(where: { $0.isProtected }) else {
                    try check(false, "Expected at least one protected demo entry in /Users/alex/Documents")
                    return
                }
                demoFM.selectSingleBrowserEntry(protectedEntry)
                try checkEqual(demoFM.focusedBrowserEntryID, protectedEntry.id)
                try checkEqual(demoFM.inspectedURL?.path, protectedEntry.url.path)
                try check(!demoFM.selectedBrowserEntryIDs.contains(protectedEntry.id), "Protected entry must not be added to selectedBrowserEntryIDs on click")
            }
        }
    }

    runner.run("Audit regression: Tab-specific confirmation titles, SidebarRail CleanupCenterStore binding, and shared QLPreviewPanelBridge") {
        let en = L10n(language: .en)
        let zh = L10n(language: .zhHans)
        try checkEqual(en.confirmRemovalTitle(for: .applications, isReset: true), en.confirmResetTitle)
        try check(en.confirmRemovalTitle(for: .junkCleaner, isReset: false) != en.confirmRemovalTitle(for: .applications, isReset: false))
        try check(en.confirmRemovalTitle(for: .fileManager, isReset: false) != en.confirmRemovalTitle(for: .resourceRelease, isReset: false))
        try check(zh.confirmRemovalTitle(for: .junkCleaner, isReset: false) != zh.confirmRemovalTitle(for: .fileManager, isReset: false))

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sidebarSrc = try String(contentsOf: repoRoot.appendingPathComponent("Sources/MacSweepApp/Components/SidebarRail.swift"), encoding: .utf8)
        try check(sidebarSrc.contains("@ObservedObject var cleanupStore: CleanupCenterStore"), "SidebarRail must directly observe CleanupCenterStore for reactive badge updates")

        let mainSplitSrc = try String(contentsOf: repoRoot.appendingPathComponent("Sources/MacSweepApp/Views/MainSplitView.swift"), encoding: .utf8)
        try check(mainSplitSrc.contains("@StateObject private var qlBridge = QLPreviewPanelBridge()"), "MainSplitView must own a single shared QLPreviewPanelBridge")

        for viewRel in [
            "Sources/MacSweepApp/Views/FileManagerView.swift",
            "Sources/MacSweepApp/Views/JunkCleanerView.swift",
            "Sources/MacSweepApp/Views/ResourceReleaseView.swift",
        ] {
            let src = try String(contentsOf: repoRoot.appendingPathComponent(viewRel), encoding: .utf8)
            try check(!src.contains("QuickLookPanelBridgeHost"), "\(viewRel) must not duplicate QuickLookPanelBridgeHost")
        }
    }

    runner.run("Hidden-file UI store toggles: FileManagerStore & CleanupCenterStore (Large, Duplicates, Junk deselect safety)") {
        try MainActor.assumeIsolated {
            let demoState = AppState(launchOptions: DemoLaunchOptions(isDemoMode: true))
            let fmStore = demoState.fileManagerStore
            let cleanupStore = demoState.cleanupCenterStore

            // 1. Space Analyzer hidden toggle in Demo Mode filters .build under swift-studio
            try checkEqual(fmStore.analyzerIncludeHiddenFiles, true)
            let swiftStudioWithHidden = fmStore.analyzerRootNode?
                .children.first(where: { $0.name == "Projects" })?
                .children.first(where: { $0.name == "swift-studio" })
            try check(swiftStudioWithHidden?.children.contains(where: { $0.name == ".build" && $0.isHidden }) == true, "Demo swift-studio must contain hidden .build when analyzerIncludeHiddenFiles is true")

            fmStore.toggleAnalyzerIncludeHiddenFiles()
            try checkEqual(fmStore.analyzerIncludeHiddenFiles, false)
            let swiftStudioNoHidden = fmStore.analyzerRootNode?
                .children.first(where: { $0.name == "Projects" })?
                .children.first(where: { $0.name == "swift-studio" })
            try check(swiftStudioNoHidden?.children.contains(where: { $0.name == ".build" }) == false, "Toggling analyzerIncludeHiddenFiles off must exclude hidden .build")

            fmStore.toggleAnalyzerIncludeHiddenFiles()
            try checkEqual(fmStore.analyzerIncludeHiddenFiles, true)

            // 2. Resource Release Large Files & Duplicate Files hidden toggles default to false and toggle cleanly
            try checkEqual(cleanupStore.largeFilesIncludeHidden, false)
            cleanupStore.toggleLargeFilesIncludeHidden()
            try checkEqual(cleanupStore.largeFilesIncludeHidden, true)

            try checkEqual(cleanupStore.duplicateIncludeHidden, false)
            cleanupStore.toggleDuplicateIncludeHidden()
            try checkEqual(cleanupStore.duplicateIncludeHidden, true)

            // 3. Junk Cleaner hidden toggle defaults to true; turning it OFF deselects hidden items so hidden items can never be silently removed
            try checkEqual(cleanupStore.junkIncludeHidden, true)
            let hiddenTrashEntry = JunkEntry(
                url: URL(fileURLWithPath: "/Users/alex/.Trash/.hidden-cache-item"),
                name: ".hidden-cache-item",
                category: .trash,
                bytes: 4096,
                isDirectory: false,
                isSelected: true,
                isHidden: true,
                expectedCanonicalParent: "/Users/alex/.Trash",
                isRecommendedSafe: true
            )
            if let trashIdx = cleanupStore.junkCategories.firstIndex(where: { $0.category == .trash }) {
                cleanupStore.junkCategories[trashIdx].entries.append(hiddenTrashEntry)
                cleanupStore.junkCategories[trashIdx].recalculateTotalBytes()

                cleanupStore.toggleJunkIncludeHidden()
                try checkEqual(cleanupStore.junkIncludeHidden, false)
                let updatedHidden = cleanupStore.junkCategories[trashIdx].entries.first(where: { $0.id == hiddenTrashEntry.id })
                try checkEqual(updatedHidden?.isSelected, false, "Turning junkIncludeHidden OFF must deselect hidden junk items")
            } else {
                try check(false, "Expected .trash category in demo junkCategories")
            }
        }
    }
}

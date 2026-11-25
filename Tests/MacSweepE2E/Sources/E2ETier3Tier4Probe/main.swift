import CryptoKit
import Darwin
import E2EHarness
import Foundation
import MacSweepCore

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    func set(_ newValue: Value) {
        lock.withLock { storage = newValue }
    }

    func get() -> Value {
        lock.withLock { storage }
    }

    func append<Element>(_ element: Element) where Value == [Element] {
        lock.withLock { storage.append(element) }
    }
}

private func allocatedBytesViaLstat(_ url: URL) throws -> UInt64 {
    var st = stat()
    guard Darwin.lstat(url.path, &st) == 0 else {
        throw E2EAssertionFailure("lstat failed for \(url.path): errno=\(errno)")
    }
    if st.st_blocks > 0 {
        return UInt64(st.st_blocks) * 512
    }
    return UInt64(max(0, st.st_size))
}

private func inodeViaLstat(_ url: URL) throws -> UInt64 {
    var st = stat()
    guard Darwin.lstat(url.path, &st) == 0 else {
        throw E2EAssertionFailure("lstat failed for \(url.path): errno=\(errno)")
    }
    return UInt64(st.st_ino)
}

private func makeMockTrashHandler(trashDir: URL) -> RemovalEngine.LocalTrashHandler {
    { itemURL in
        let dst = trashDir.appendingPathComponent("\(UUID().uuidString)-\(itemURL.lastPathComponent)")
        try FileManager.default.moveItem(at: itemURL, to: dst)
    }
}

private func setFileTimes(at url: URL, accessDate: Date, modificationDate: Date) throws {
    let atimeSec = accessDate.timeIntervalSince1970
    let mtimeSec = modificationDate.timeIntervalSince1970
    var times = [
        timeval(tv_sec: Int(atimeSec), tv_usec: 0),
        timeval(tv_sec: Int(mtimeSec), tv_usec: 0),
    ]
    guard Darwin.utimes(url.path, &times) == 0 else {
        throw E2EAssertionFailure("utimes failed for \(url.path): errno=\(errno)")
    }
}

private func sha256Hex(of url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func minimalValidPNGData() -> Data {
    Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x03, 0x01, 0x01, 0x00, 0xC9, 0xFE, 0x92,
        0xEF, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    ])
}

let runner = E2ERunner(probeName: "E2ETier3Tier4Probe")

// MARK: - Tier 3: Cross-Feature Combination Cases (8 Cases)

runner.register(
    id: "t3-analyzer-move-trash-history",
    tier: 3,
    feature: "F-2,F-4,F-5",
    name: "DiskSpaceAnalyzer filter -> FileOperationsEngine move -> stale TOCTOU reject -> RemovalEngine trash + rescan parity"
) {
    let sandbox = try E2ESandbox(prefix: "t3-amt")
    defer { sandbox.cleanup() }

    let workDir = try sandbox.createDirectory("Work")
    let inboxDir = try sandbox.createDirectory("Work/Inbox")
    let stagingDir = try sandbox.createDirectory("Work/Staging")
    let mockTrash = try sandbox.createDirectory("MockTrash")

    let oldFile = try sandbox.createExactSizeFile("Work/Inbox/old_archive.dmg", byteCount: 65_536, fillByte: 0x1A, sparse: false)
    let freshFile = try sandbox.createExactSizeFile("Work/Inbox/fresh_small.txt", byteCount: 4_096, fillByte: 0x2B, sparse: false)
    let keepFile = try sandbox.createExactSizeFile("Work/Keep/untouched.bin", byteCount: 16_384, fillByte: 0x3C, sparse: false)

    let now = Date()
    try setFileTimes(at: oldFile, accessDate: now.addingTimeInterval(-120 * 86_400), modificationDate: now.addingTimeInterval(-120 * 86_400))
    try setFileTimes(at: freshFile, accessDate: now.addingTimeInterval(-2 * 86_400), modificationDate: now.addingTimeInterval(-2 * 86_400))

    let oldAlloc = try allocatedBytesViaLstat(oldFile)
    let freshAlloc = try allocatedBytesViaLstat(freshFile)
    let keepAlloc = try allocatedBytesViaLstat(keepFile)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let analyzer = DiskSpaceAnalyzer(safetyGuard: sg)
    let fileOps = FileOperationsEngine(safetyGuard: sg)
    let historyStore = CleanupHistoryStore(fileURL: sandbox.url("State/history.json"))
    let removalEngine = RemovalEngine(
        safetyGuard: sg,
        historyStore: historyStore,
        localTrashHandler: makeMockTrashHandler(trashDir: mockTrash)
    )

    let treeBefore = try await analyzer.analyze(root: workDir, maxDepth: 4)
    try E2ERunner.expectEqual(treeBefore.bytes, oldAlloc + freshAlloc + keepAlloc)

    let filter = DiskEntryFilter(
        minBytes: 32_768,
        olderThanDays: 60,
        ageBasis: .modificationDate,
        scope: .filesOnly,
        excludeProtected: true
    )
    let fromTree = DiskSpaceAnalyzer.filterNodes(in: treeBefore, filter: filter, referenceDate: now)
    let fromSearch = try await analyzer.findMatchingFiles(under: workDir, filter: filter, referenceDate: now)
    try E2ERunner.expectEqual(fromTree.map(\.name), ["old_archive.dmg"])
    try E2ERunner.expectEqual(fromSearch.map(\.name), ["old_archive.dmg"])

    let matched = fromSearch[0]
    let movedURL = try await fileOps.moveItem(
        from: matched.url,
        to: stagingDir,
        expectedSourceCanonicalParent: matched.expectedCanonicalParent,
        expectedDestinationCanonicalParent: sandbox.canonicalPath(for: stagingDir)
    )
    let movedMeta = try fileOps.inspectMetadata(at: movedURL)
    try E2ERunner.expectEqual(movedMeta.expectedCanonicalParent, sandbox.canonicalPath(for: stagingDir))
    try E2ERunner.expectNotEqual(movedMeta.expectedCanonicalParent, sandbox.canonicalPath(for: inboxDir))

    let staleReport = removalEngine.remove(
        targets: [RemovalTarget(url: movedURL, estimatedSize: Int64(oldAlloc), expectedCanonicalParent: matched.expectedCanonicalParent)],
        mode: .trash,
        actionTitle: "Stale Parent Check",
        allowElevation: false
    )
    try E2ERunner.expect(!staleReport.isFullSuccess)
    try E2ERunner.expectEqual(staleReport.failures.count, 1)
    try E2ERunner.expectContains(staleReport.failures[0].reason, "TOCTOU")
    try E2ERunner.expect(RemovalEngine.entryExists(movedURL))
    try E2ERunner.expect(historyStore.load().isEmpty)

    let expectedMovedPath = movedURL.standardizedFileURL.path
    let freshAllocSize = Int64(movedMeta.allocatedSizeBytes ?? movedMeta.sizeBytes)
    let freshReport = removalEngine.remove(
        targets: [RemovalTarget(url: movedURL, estimatedSize: freshAllocSize, expectedCanonicalParent: movedMeta.expectedCanonicalParent)],
        mode: .trash,
        actionTitle: "Analyzer Move & Trash",
        allowElevation: false
    )
    try E2ERunner.expect(freshReport.isFullSuccess, "Fresh move-then-trash failed: \(freshReport.failures)")
    try E2ERunner.expect(!RemovalEngine.entryExists(movedURL))
    let trashedFiles = try FileManager.default.contentsOfDirectory(at: mockTrash, includingPropertiesForKeys: nil)
    try E2ERunner.expect(trashedFiles.contains(where: { $0.lastPathComponent.hasSuffix("old_archive.dmg") }))

    let records = historyStore.load()
    try E2ERunner.expectEqual(records.count, 1)
    try E2ERunner.expectEqual(records[0].mode, .trash)
    try E2ERunner.expectEqual(records[0].freedBytes, Int64(oldAlloc))
    try E2ERunner.expectEqual(records[0].removedPaths, [expectedMovedPath])

    let treeAfter = try await analyzer.analyze(root: workDir, maxDepth: 4)
    try E2ERunner.expectEqual(treeBefore.bytes - treeAfter.bytes, oldAlloc)
    try E2ERunner.expectEqual(treeAfter.bytes, freshAlloc + keepAlloc)
    try E2ERunner.expect(RemovalEngine.entryExists(freshFile))
    try E2ERunner.expect(RemovalEngine.entryExists(keepFile))
}

runner.register(
    id: "t3-browser-ops-analyzer-rescan",
    tier: 3,
    feature: "F-2,F-4,F-5",
    name: "FileBrowserService preview + create/rename/move + ProtectedVault block + permanent delete + Analyzer rescan"
) {
    let sandbox = try E2ESandbox(prefix: "t3-boa")
    defer { sandbox.cleanup() }

    let workspaceURL = try sandbox.createDirectory("Workspace")
    let draftsDir = try sandbox.createDirectory("Workspace/Drafts")
    let vaultDir = try sandbox.createDirectory("Workspace/ProtectedVault")

    let notesPayload = String(repeating: "MacSweep E2E Markdown Content\n", count: 256) + String(repeating: "x", count: 8_192 - 256 * 30)
    let notesFile = try sandbox.createFile("Workspace/Drafts/notes.md", utf8: notesPayload)
    let tempFile = try sandbox.createExactSizeFile("Workspace/Drafts/temp.bin", byteCount: 16_384, fillByte: 0x44, sparse: false)
    let secretFile = try sandbox.createExactSizeFile("Workspace/ProtectedVault/secret.dat", byteCount: 4_096, fillByte: 0x55, sparse: false)

    let tempAlloc = try allocatedBytesViaLstat(tempFile)
    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil, protectedPaths: [vaultDir.path])
    let service = FileBrowserService(safetyGuard: sg, homeDirectory: sandbox.rootURL)
    let analyzer = DiskSpaceAnalyzer(safetyGuard: sg)
    let historyStore = CleanupHistoryStore(fileURL: sandbox.url("State/history.json"))
    let removalEngine = RemovalEngine(safetyGuard: sg, historyStore: historyStore)

    let treeBefore = try await analyzer.analyze(root: workspaceURL, maxDepth: 4)
    let drafts = try service.listDirectory(at: draftsDir, showHidden: false, sortBy: .name, ascending: true)
    try E2ERunner.expectEqual(drafts.map(\.name), ["notes.md", "temp.bin"])

    let notesEntry = try E2ERunner.expectNotNil(drafts.first(where: { $0.name == "notes.md" }))
    let tempEntry = try E2ERunner.expectNotNil(drafts.first(where: { $0.name == "temp.bin" }))

    let preview = try service.loadPreview(at: notesEntry.url)
    switch preview.content {
    case let .text(text, _, _, totalBytes):
        try E2ERunner.expectEqual(totalBytes, Int64(8_192))
        try E2ERunner.expectContains(text, "MacSweep E2E Markdown Content")
    default:
        throw E2EAssertionFailure("Expected text preview for notes.md, got \(preview.content)")
    }

    let pubDir = try await service.fileOperationsEngine.createDirectory(
        named: "Published",
        in: workspaceURL,
        expectedParentCanonicalParent: sandbox.canonicalPath(for: workspaceURL)
    )
    let renamed = try await service.fileOperationsEngine.renameItem(
        at: notesEntry.url,
        toNewName: "published.md",
        expectedSourceCanonicalParent: notesEntry.expectedCanonicalParent
    )
    let moved = try await service.fileOperationsEngine.moveItem(
        from: renamed,
        to: pubDir,
        expectedSourceCanonicalParent: notesEntry.expectedCanonicalParent,
        expectedDestinationCanonicalParent: sandbox.canonicalPath(for: pubDir)
    )
    try E2ERunner.expect(RemovalEngine.entryExists(moved))
    try E2ERunner.expect(!RemovalEngine.entryExists(notesFile))

    let vaultEntries = try service.listDirectory(at: vaultDir, showHidden: false)
    try E2ERunner.expectEqual(vaultEntries.count, 1)
    let secretEntry = vaultEntries[0]
    let blockedErr = try await E2ERunner.expectThrowsAsync("ProtectedVault rename must be blocked") {
        _ = try await service.fileOperationsEngine.renameItem(
            at: secretEntry.url,
            toNewName: "leaked.dat",
            expectedSourceCanonicalParent: secretEntry.expectedCanonicalParent
        )
    }
    guard case .blockedBySafetyGuard = blockedErr as? FileOperationError else {
        throw E2EAssertionFailure("Expected FileOperationError.blockedBySafetyGuard, got \(blockedErr)")
    }

    let workspaceEntries = try service.listDirectory(at: workspaceURL, showHidden: false)
    let vaultRow = try E2ERunner.expectNotNil(workspaceEntries.first(where: { $0.name == "ProtectedVault" }))
    try E2ERunner.expect(vaultRow.isProtected && vaultRow.isMutationLocked)

    let delReport = removalEngine.remove(
        targets: [RemovalTarget(url: tempEntry.url, estimatedSize: Int64(tempAlloc), expectedCanonicalParent: tempEntry.expectedCanonicalParent)],
        mode: .permanent,
        actionTitle: "Delete Temp Bin",
        allowElevation: false
    )
    try E2ERunner.expect(delReport.isFullSuccess)
    try E2ERunner.expect(try service.listDirectory(at: draftsDir, showHidden: false).isEmpty)
    try E2ERunner.expectEqual(try service.listDirectory(at: pubDir, showHidden: false).map(\.name), ["published.md"])

    let treeAfter = try await analyzer.analyze(root: workspaceURL, maxDepth: 4)
    try E2ERunner.expectEqual(treeBefore.bytes - treeAfter.bytes, tempAlloc)
    try E2ERunner.expect(RemovalEngine.entryExists(secretFile))
    try E2ERunner.expect(RemovalEngine.entryExists(moved))
}

runner.register(
    id: "t3-junk-scan-protected-paths",
    tier: 3,
    feature: "F-3,F-6",
    name: "PreferencesStore protectedPaths & protectedBundleIDs filter JunkCacheScanner and block RemovalEngine"
) {
    let sandbox = try E2ESandbox(prefix: "t3-jsp")
    defer { sandbox.cleanup() }

    let keepByPathFile = try sandbox.createExactSizeFile("Library/Caches/com.keep.ByPath/data.bin", byteCount: 4_096, fillByte: 0x11, sparse: false)
    let keepByBundleFile = try sandbox.createExactSizeFile("Library/Caches/com.keep.ByBundle/data.bin", byteCount: 4_096, fillByte: 0x22, sparse: false)
    _ = try sandbox.createExactSizeFile("Library/Caches/Google/Chrome/Cache/c.bin", byteCount: 8_192, fillByte: 0x33, sparse: false)
    _ = try sandbox.createExactSizeFile("Library/Caches/Google/Earth/e.bin", byteCount: 4_096, fillByte: 0x44, sparse: false)
    _ = try sandbox.createExactSizeFile("Library/Caches/com.clean.Temp/t.bin", byteCount: 4_096, fillByte: 0x55, sparse: false)
    let safariFile = try sandbox.createExactSizeFile("Library/Caches/com.apple.Safari/s.bin", byteCount: 4_096, fillByte: 0x66, sparse: false)
    _ = try sandbox.createExactSizeFile("Library/Logs/com.clean.Temp/app.log", byteCount: 4_096, fillByte: 0x77, sparse: false)
    _ = try sandbox.createExactSizeFile(".Trash/stale.zip", byteCount: 4_096, fillByte: 0x88, sparse: false)
    let mockTrash = try sandbox.createDirectory("MockTrash")

    let keepByPathDir = sandbox.url("Library/Caches/com.keep.ByPath")
    let keepByBundleDir = sandbox.url("Library/Caches/com.keep.ByBundle")
    let safariDir = sandbox.url("Library/Caches/com.apple.Safari")
    let googleBareDir = sandbox.url("Library/Caches/Google")

    let prefsURL = sandbox.url("Config/preferences.json")
    let prefsStore = PreferencesStore(fileURL: prefsURL)
    let saved = prefsStore.save(SweepPreferences(
        protectedBundleIDs: ["com.keep.ByBundle"],
        protectedPaths: [keepByPathDir.path]
    ))
    try E2ERunner.expect(saved)
    let reloaded = PreferencesStore(fileURL: prefsURL).load()

    let sg = SafetyGuard(
        homeDirectory: sandbox.rootURL,
        selfBundlePath: nil,
        protectedPaths: reloaded.protectedPaths,
        protectedBundleIDs: reloaded.protectedBundleIDs
    )
    let env = JunkScannerEnvironment(
        homeDirectory: sandbox.rootURL,
        trashDirectory: sandbox.url(".Trash"),
        runningBundleIDs: [],
        runningAppNames: [],
        includeSystemLogs: false
    )
    let scanner = JunkCacheScanner(safetyGuard: sg, environment: env)
    let scanResult = try await scanner.scanAll()
    let allEntries = scanResult.categories.flatMap(\.entries)
    let discoveredPaths = Set(allEntries.map { $0.url.standardizedFileURL.path })

    try E2ERunner.expect(!discoveredPaths.contains(keepByPathDir.standardizedFileURL.path))
    try E2ERunner.expect(!discoveredPaths.contains(keepByBundleDir.standardizedFileURL.path))
    try E2ERunner.expect(!discoveredPaths.contains(safariDir.standardizedFileURL.path))
    try E2ERunner.expect(!discoveredPaths.contains(googleBareDir.standardizedFileURL.path))
    try E2ERunner.expect(!sg.validateCacheSubpath(safariDir).isAllowed)
    try E2ERunner.expect(!sg.validateCacheSubpath(googleBareDir).isAllowed)

    try E2ERunner.expect(allEntries.contains(where: { $0.category == .browserCaches && $0.url.path.contains("Google/Chrome") }))
    try E2ERunner.expect(allEntries.contains(where: { $0.category == .userCaches && $0.name == "Earth" && $0.subgroup == "Google" }))
    try E2ERunner.expect(allEntries.contains(where: { $0.category == .userCaches && $0.name == "com.clean.Temp" }))
    try E2ERunner.expect(allEntries.contains(where: { $0.category == .logs && $0.name == "com.clean.Temp" }))
    try E2ERunner.expect(allEntries.contains(where: { $0.category == .trash && $0.name == "stale.zip" }))

    let historyStore = CleanupHistoryStore(fileURL: sandbox.url("State/history.json"))
    let removalEngine = RemovalEngine(
        safetyGuard: sg,
        historyStore: historyStore,
        localTrashHandler: makeMockTrashHandler(trashDir: mockTrash)
    )

    let protectedTargets = [keepByPathDir, keepByBundleDir, googleBareDir].map {
        RemovalTarget(url: $0, estimatedSize: 4_096, expectedCanonicalParent: SandboxBuilder.canonicalParentPath(for: $0))
    }
    let nonTrashCleanable = allEntries
        .filter { $0.isSelected && $0.category != .trash }
        .map { RemovalTarget(url: $0.url, estimatedSize: Int64($0.bytes), requiresAdmin: $0.requiresAdmin, expectedCanonicalParent: $0.expectedCanonicalParent) }
    let trashCleanable = allEntries
        .filter { $0.isSelected && $0.category == .trash }
        .map { RemovalTarget(url: $0.url, estimatedSize: Int64($0.bytes), requiresAdmin: $0.requiresAdmin, expectedCanonicalParent: $0.expectedCanonicalParent) }

    let mixedReport = removalEngine.remove(
        targets: protectedTargets + nonTrashCleanable,
        mode: .trash,
        actionTitle: "Mixed Junk & Protected",
        allowElevation: false
    )
    try E2ERunner.expectEqual(mixedReport.failures.count, 3)
    try E2ERunner.expectEqual(Set(mixedReport.succeededURLs.map { $0.standardizedFileURL.path }), Set(nonTrashCleanable.map { $0.url.standardizedFileURL.path }))

    let emptyTrashReport = removalEngine.remove(
        targets: trashCleanable,
        mode: .permanent,
        actionTitle: "Empty Trash",
        allowElevation: false
    )
    try E2ERunner.expect(emptyTrashReport.isFullSuccess)

    try E2ERunner.expect(RemovalEngine.entryExists(keepByPathFile))
    try E2ERunner.expect(RemovalEngine.entryExists(keepByBundleFile))
    try E2ERunner.expect(RemovalEngine.entryExists(safariFile))
    try E2ERunner.expect(RemovalEngine.entryExists(googleBareDir))
}

runner.register(
    id: "t3-large-files-protected-toctou",
    tier: 3,
    feature: "F-2,F-3,F-7",
    name: "LargeAndDuplicateScanner protection pruning + FileBrowserService hex preview + TOCTOU parent-swap block"
) {
    let sandbox = try E2ESandbox(prefix: "t3-lft")
    defer { sandbox.cleanup() }

    let homeDir = try sandbox.createDirectory("Home")
    let protDocsDir = try sandbox.createDirectory("Home/Documents")
    let bigProtected = try sandbox.createExactSizeFile("Home/Documents/big_protected.dmg", byteCount: 60_000_000, sparse: true)
    let keepApp = try sandbox.createMockAppBundle(atRelativePath: "Home/Applications/KeepApp.app", bundleID: "com.keep.app", name: "KeepApp")
    _ = try sandbox.createExactSizeFile("Home/Applications/KeepApp.app/Contents/Resources/big.bin", byteCount: 60_000_000, sparse: true)
    let swapParent = try sandbox.createDirectory("Home/Downloads/SwapParent")
    _ = try sandbox.createExactSizeFile("Home/Downloads/SwapParent/big_swap.iso", byteCount: 60_000_000, sparse: true, sparseDistinctTag: 0x11)
    let externalSafeDir = try sandbox.createDirectory("ExternalSafeTarget")
    let decoyFile = try sandbox.createExactSizeFile("ExternalSafeTarget/big_swap.iso", byteCount: 60_000_000, sparse: true, sparseDistinctTag: 0x55)
    let cleanFile = try sandbox.createExactSizeFile("Home/Downloads/clean_me.bin", byteCount: 60_000_000, sparse: true)

    _ = keepApp
    let sg = SafetyGuard(
        homeDirectory: homeDir,
        selfBundlePath: nil,
        protectedPaths: [protDocsDir.path],
        protectedBundleIDs: ["com.keep.app"]
    )
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let browser = FileBrowserService(safetyGuard: sg, homeDirectory: homeDir)
    let historyStore = CleanupHistoryStore(fileURL: sandbox.url("State/history.json"))
    let removalEngine = RemovalEngine(safetyGuard: sg, historyStore: historyStore)

    let items = try await scanner.scanLargeFiles(under: homeDir, minBytes: LargeFileSizeThreshold.mb50.rawValue)
    try E2ERunner.expectEqual(items.count, 2)
    try E2ERunner.expectEqual(Set(items.map(\.name)), Set(["clean_me.bin", "big_swap.iso"]))

    let cleanItem = try E2ERunner.expectNotNil(items.first(where: { $0.name == "clean_me.bin" }))
    let swapItem = try E2ERunner.expectNotNil(items.first(where: { $0.url.path.contains("/SwapParent/") }))

    let preview = try browser.loadPreview(at: cleanItem.url)
    switch preview.content {
    case let .hexDump(_, _, isTruncated, totalBytes):
        try E2ERunner.expect(isTruncated)
        try E2ERunner.expectEqual(totalBytes, Int64(60_000_000))
    default:
        throw E2EAssertionFailure("Expected truncated hexDump preview for 60MB clean_me.bin, got \(preview.content)")
    }

    try FileManager.default.removeItem(at: swapParent)
    try sandbox.createSymlink(atRelativePath: "Home/Downloads/SwapParent", targetURL: externalSafeDir)

    let expectedCleanURL = cleanItem.url.standardizedFileURL
    let expectedCleanPath = expectedCleanURL.path
    let report = removalEngine.remove(
        targets: [
            RemovalTarget(url: swapItem.url, estimatedSize: Int64(swapItem.bytes), expectedCanonicalParent: swapItem.expectedCanonicalParent),
            RemovalTarget(url: cleanItem.url, estimatedSize: Int64(cleanItem.bytes), expectedCanonicalParent: cleanItem.expectedCanonicalParent),
        ],
        mode: .permanent,
        actionTitle: "Large File Cleanup",
        allowElevation: false
    )
    try E2ERunner.expectEqual(report.succeededURLs, [expectedCleanURL])
    try E2ERunner.expectEqual(report.failures.count, 1)
    try E2ERunner.expectContains(report.failures[0].reason, "TOCTOU")

    try E2ERunner.expect(RemovalEngine.entryExists(decoyFile))
    try E2ERunner.expect(RemovalEngine.entryExists(bigProtected))
    try E2ERunner.expect(!RemovalEngine.entryExists(cleanFile))

    let records = historyStore.load()
    try E2ERunner.expectEqual(records.count, 1)
    try E2ERunner.expectEqual(records[0].removedPaths, [expectedCleanPath])
}

runner.register(
    id: "t3-duplicate-browser-preview-removal",
    tier: 3,
    feature: "F-5,F-8",
    name: "Duplicate scan -> preferNonDownloads -> keep-one guard -> FileBrowserService preview -> Trash + rescan"
) {
    let sandbox = try E2ESandbox(prefix: "t3-dbp")
    defer { sandbox.cleanup() }

    let homeDir = try sandbox.createDirectory("Home")
    let mockTrash = try sandbox.createDirectory("MockTrash")
    let dupText = String(repeating: "DUPLICATE_CONTENT_ROW_0123456789", count: 1_024) // 32,768 bytes
    let uniqText = String(repeating: "UNIQUE_CONTENT_ROW_9876543210___", count: 1_024)

    _ = try sandbox.createFile("Home/Downloads/copy_dl.txt", utf8: dupText)
    let keeperFile = try sandbox.createFile("Home/Work/copy_work.txt", utf8: dupText)
    _ = try sandbox.createFile("Home/Work/copy_work_2.txt", utf8: dupText)
    let uniqueFile = try sandbox.createFile("Home/Work/unique.txt", utf8: uniqText)

    let keeperHash = try sha256Hex(of: keeperFile)
    let sg = SafetyGuard(homeDirectory: homeDir, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let browser = FileBrowserService(safetyGuard: sg, homeDirectory: homeDir)
    let historyStore = CleanupHistoryStore(fileURL: sandbox.url("State/history.json"))
    let removalEngine = RemovalEngine(
        safetyGuard: sg,
        historyStore: historyStore,
        localTrashHandler: makeMockTrashHandler(trashDir: mockTrash)
    )

    let groups = try await scanner.scanDuplicates(under: homeDir, minBytes: 1_024)
    try E2ERunner.expectEqual(groups.count, 1)
    let selectedGroups = scanner.applySmartSelection(to: groups, preset: .preferNonDownloads)
    let group = selectedGroups[0]
    try E2ERunner.expectEqual(group.files.count, 3)
    try E2ERunner.expectEqual(group.selectedCount, 2)
    try E2ERunner.expectEqual(group.selectedReclaimableBytes, UInt64(65_536))

    let keeperEntry = try E2ERunner.expectNotNil(group.files.first(where: { !$0.isSelected }))
    try E2ERunner.expect(!keeperEntry.url.path.contains("/Downloads/"))

    let guarded = group.settingSelection(true, forEntryID: keeperEntry.id, enforceKeepOne: true)
    try E2ERunner.expect(!guarded.allCopiesSelected)
    try E2ERunner.expectEqual(guarded.selectedCount, 2)

    let selectedCopy = try E2ERunner.expectNotNil(group.files.first(where: \.isSelected))
    let keeperPreview = try browser.loadPreview(at: keeperEntry.url)
    let copyPreview = try browser.loadPreview(at: selectedCopy.url)
    guard case let .text(kText, _, _, _) = keeperPreview.content,
          case let .text(cText, _, _, _) = copyPreview.content else {
        throw E2EAssertionFailure("Expected text preview for duplicate copies")
    }
    try E2ERunner.expectEqual(kText, cText)

    let targets = group.files.filter(\.isSelected).map {
        RemovalTarget(url: $0.url, estimatedSize: Int64(group.fileSize), expectedCanonicalParent: $0.expectedCanonicalParent)
    }
    let report = removalEngine.remove(targets: targets, mode: .trash, actionTitle: "Duplicate Cleanup", allowElevation: false)
    try E2ERunner.expect(report.isFullSuccess)

    let rescan = try await scanner.scanDuplicates(under: homeDir, minBytes: 1_024)
    try E2ERunner.expect(rescan.isEmpty)
    try E2ERunner.expectEqual(try sha256Hex(of: keeperFile), keeperHash)
    try E2ERunner.expect(RemovalEngine.entryExists(uniqueFile))

    let records = historyStore.load()
    try E2ERunner.expectEqual(records.count, 1)
    try E2ERunner.expectEqual(records[0].itemCount, 2)
    try E2ERunner.expectEqual(records[0].freedBytes, Int64(65_536))
}

runner.register(
    id: "t3-combined-cleanup-and-memory-isolation",
    tier: 3,
    feature: "F-6,F-7,F-8,F-9",
    name: "Junk + Large + Duplicate cleanup records 3 history entries while MemoryReleaseService isolates disk & history"
) {
    let sandbox = try E2ESandbox(prefix: "t3-ccm")
    defer { sandbox.cleanup() }

    _ = try sandbox.createExactSizeFile("Library/Caches/com.acme.Widget/w.bin", byteCount: 8_192, fillByte: 0x12, sparse: false)
    let hugeFile = try sandbox.createExactSizeFile("Work/huge_old.dmg", byteCount: 60_000_000, sparse: true)
    let dupA = try sandbox.createExactSizeFile("Work/dup_a.dat", byteCount: 32_768, fillByte: 0x34, sparse: false)
    let dupB = try sandbox.createExactSizeFile("Work/dup_b.dat", byteCount: 32_768, fillByte: 0x34, sparse: false)
    let mockTrash = try sandbox.createDirectory("MockTrash")

    let now = Date()
    try setFileTimes(at: dupA, accessDate: now.addingTimeInterval(-30 * 86_400), modificationDate: now.addingTimeInterval(-30 * 86_400))
    try setFileTimes(at: dupB, accessDate: now.addingTimeInterval(-1 * 86_400), modificationDate: now.addingTimeInterval(-1 * 86_400))

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let junkScanner = JunkCacheScanner(
        safetyGuard: sg,
        environment: JunkScannerEnvironment(
            homeDirectory: sandbox.rootURL,
            trashDirectory: sandbox.url(".Trash"),
            runningBundleIDs: [],
            runningAppNames: [],
            includeSystemLogs: false
        )
    )
    let resourceScanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let historyStore = CleanupHistoryStore(fileURL: sandbox.url("State/history.json"))
    let removalEngine = RemovalEngine(
        safetyGuard: sg,
        historyStore: historyStore,
        localTrashHandler: makeMockTrashHandler(trashDir: mockTrash)
    )

    let junkCats = try await junkScanner.scan()
    let junkTargets = junkCats.flatMap(\.entries).filter(\.isSelected).map {
        RemovalTarget(url: $0.url, estimatedSize: Int64($0.bytes), expectedCanonicalParent: $0.expectedCanonicalParent)
    }
    try E2ERunner.expect(!junkTargets.isEmpty)
    try E2ERunner.expect(removalEngine.remove(targets: junkTargets, mode: .trash, actionTitle: "Junk", allowElevation: false).isFullSuccess)

    let largeItems = try await resourceScanner.scanLargeFiles(under: sandbox.url("Work"), minBytes: LargeFileSizeThreshold.mb50.rawValue)
    try E2ERunner.expectEqual(largeItems.map(\.name), ["huge_old.dmg"])
    let largeTargets = largeItems.map {
        RemovalTarget(url: $0.url, estimatedSize: Int64($0.bytes), expectedCanonicalParent: $0.expectedCanonicalParent)
    }
    try E2ERunner.expect(removalEngine.remove(targets: largeTargets, mode: .permanent, actionTitle: "Large", allowElevation: false).isFullSuccess)
    try E2ERunner.expect(!RemovalEngine.entryExists(hugeFile))

    let dupGroups = resourceScanner.applySmartSelection(
        to: try await resourceScanner.scanDuplicates(under: sandbox.url("Work"), minBytes: 1_024),
        preset: .keepOldest
    )
    try E2ERunner.expectEqual(dupGroups.count, 1)
    let dupTargets = dupGroups[0].files.filter(\.isSelected).map {
        RemovalTarget(url: $0.url, estimatedSize: Int64(dupGroups[0].fileSize), expectedCanonicalParent: $0.expectedCanonicalParent)
    }
    try E2ERunner.expectEqual(dupTargets.count, 1)
    try E2ERunner.expect(removalEngine.remove(targets: dupTargets, mode: .trash, actionTitle: "Dup", allowElevation: false).isFullSuccess)

    let historyAfterDisk = historyStore.load()
    try E2ERunner.expectEqual(historyAfterDisk.count, 3)

    let capturedScript = LockedBox<String?>(nil)
    let executor = PrivilegedExecutor(
        safetyGuard: sg,
        adminShellRunner: { script in
            capturedScript.set(script)
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    )
    let memService = MemoryReleaseService(privilegedExecutor: executor)
    let reliefStd = try await memService.releaseMemory(allowElevation: false)
    try E2ERunner.expect(!reliefStd.usedElevation)
    try E2ERunner.expectEqual(reliefStd.methodUsed, "standard_pressure_relief")
    try E2ERunner.expect(reliefStd.reclaimedEstimateBytes <= reliefStd.before.totalBytes)

    let reliefElev = try await memService.releaseMemory(allowElevation: true)
    try E2ERunner.expect(reliefElev.usedElevation)
    try E2ERunner.expectEqual(reliefElev.methodUsed, "purge")
    let script = try E2ERunner.expectNotNil(capturedScript.get())
    try E2ERunner.expectContains(script, "/usr/sbin/purge")

    try E2ERunner.expectEqual(historyStore.load(), historyAfterDisk)
    try E2ERunner.expect(RemovalEngine.entryExists(dupA))
    try E2ERunner.expect(!RemovalEngine.entryExists(dupB))
}

runner.register(
    id: "t3-analyzer-large-duplicate-reclaim-parity",
    tier: 3,
    feature: "F-4,F-7,F-8",
    name: "DiskSpaceAnalyzer, LargeAndDuplicateScanner, inspectMetadata, and RemovalEngine maintain exact byte reclaim parity"
) {
    let sandbox = try E2ESandbox(prefix: "t3-arp")
    defer { sandbox.cleanup() }

    let scanDir = try sandbox.createDirectory("Scan")
    let largeOnly = try sandbox.createExactSizeFile("Scan/large_only.bin", byteCount: 65_536, fillByte: 0x11, sparse: false)
    let dup1 = try sandbox.createExactSizeFile("Scan/dup_1.bin", byteCount: 32_768, fillByte: 0x22, sparse: false)
    let dup2 = try sandbox.createExactSizeFile("Scan/dup_2.bin", byteCount: 32_768, fillByte: 0x22, sparse: false)
    let hard1 = try sandbox.createExactSizeFile("Scan/hard_1.bin", byteCount: 32_768, fillByte: 0x33, sparse: false)
    let hard2 = try sandbox.createHardlink(atRelativePath: "Scan/hard_2.bin", to: hard1)
    let small = try sandbox.createExactSizeFile("Scan/small.bin", byteCount: 8_192, fillByte: 0x44, sparse: false)

    let now = Date()
    try setFileTimes(at: dup1, accessDate: now.addingTimeInterval(-10 * 86_400), modificationDate: now.addingTimeInterval(-10 * 86_400))
    try setFileTimes(at: dup2, accessDate: now.addingTimeInterval(-1 * 86_400), modificationDate: now.addingTimeInterval(-1 * 86_400))

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let analyzer = DiskSpaceAnalyzer(safetyGuard: sg)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let fileOps = FileOperationsEngine(safetyGuard: sg)
    let historyStore = CleanupHistoryStore(fileURL: sandbox.url("State/history.json"))
    let removalEngine = RemovalEngine(safetyGuard: sg, historyStore: historyStore)

    let treeBefore = try await analyzer.analyze(root: scanDir, maxDepth: 4)
    try E2ERunner.expectEqual(treeBefore.bytes, UInt64(172_032))

    let largeItems = try await scanner.scanLargeFiles(under: scanDir, minBytes: 49_152)
    try E2ERunner.expectEqual(largeItems.map(\.name), ["large_only.bin"])
    try E2ERunner.expectEqual(largeItems[0].bytes, UInt64(65_536))

    let dupGroups = scanner.applySmartSelection(
        to: try await scanner.scanDuplicates(under: scanDir, minBytes: 16_384),
        preset: .keepOldest
    )
    try E2ERunner.expectEqual(dupGroups.count, 1)
    try E2ERunner.expectEqual(dupGroups[0].reclaimableBytes, UInt64(32_768))

    let dupToRemove = try E2ERunner.expectNotNil(dupGroups[0].files.first(where: \.isSelected))
    let largeMeta = try fileOps.inspectMetadata(at: largeOnly)
    let dupMeta = try fileOps.inspectMetadata(at: dupToRemove.url)
    try E2ERunner.expectEqual(largeMeta.allocatedSizeBytes, Int64(65_536))
    try E2ERunner.expectEqual(dupMeta.allocatedSizeBytes, Int64(32_768))

    let report = removalEngine.remove(
        targets: [
            RemovalTarget(url: largeItems[0].url, estimatedSize: Int64(largeItems[0].bytes), expectedCanonicalParent: largeItems[0].expectedCanonicalParent),
            RemovalTarget(url: dupToRemove.url, estimatedSize: Int64(dupGroups[0].fileSize), expectedCanonicalParent: dupToRemove.expectedCanonicalParent),
        ],
        mode: .permanent,
        actionTitle: "Reclaim Parity",
        allowElevation: false
    )
    try E2ERunner.expect(report.isFullSuccess)
    try E2ERunner.expectEqual(report.freedBytes, Int64(98_304))

    let treeAfter = try await analyzer.analyze(root: scanDir, maxDepth: 4)
    try E2ERunner.expectEqual(treeBefore.bytes - treeAfter.bytes, UInt64(98_304))
    try E2ERunner.expectEqual(treeAfter.bytes, UInt64(73_728))
    try E2ERunner.expect(try await scanner.scanLargeFiles(under: scanDir, minBytes: 49_152).isEmpty)
    try E2ERunner.expect(try await scanner.scanDuplicates(under: scanDir, minBytes: 16_384).isEmpty)
    try E2ERunner.expect(RemovalEngine.entryExists(hard1))
    try E2ERunner.expect(RemovalEngine.entryExists(hard2))
    try E2ERunner.expect(RemovalEngine.entryExists(small))
    try E2ERunner.expect(RemovalEngine.entryExists(dup1))
}

runner.register(
    id: "t3-prefs-update-live-enforcement",
    tier: 3,
    feature: "F-2,F-3,F-5,F-6,F-8",
    name: "PreferencesStore update propagates live across all 6 subsystems and refuses overwrite after JSON corruption"
) {
    let sandbox = try E2ESandbox(prefix: "t3-pul")
    defer { sandbox.cleanup() }

    let workDir = try sandbox.createDirectory("Work")
    let vaultDir = try sandbox.createDirectory("Work/DynamicVault")
    let otherDir = try sandbox.createDirectory("Work/Other")
    _ = try sandbox.createExactSizeFile("Work/DynamicVault/payload.dat", byteCount: 32_768, fillByte: 0x7E, sparse: false)
    _ = try sandbox.createExactSizeFile("Work/Other/payload_copy.dat", byteCount: 32_768, fillByte: 0x7E, sparse: false)
    _ = try sandbox.createExactSizeFile("Library/Caches/com.dynamic.App/c.bin", byteCount: 4_096, fillByte: 0x8F, sparse: false)

    let prefsURL = sandbox.url("Config/preferences.json")
    let prefsStore = PreferencesStore(fileURL: prefsURL)
    let initialPrefs = prefsStore.load()
    let sg1 = SafetyGuard(
        homeDirectory: sandbox.rootURL,
        selfBundlePath: nil,
        protectedPaths: initialPrefs.protectedPaths,
        protectedBundleIDs: initialPrefs.protectedBundleIDs
    )
    try E2ERunner.expect(sg1.validateForRemoval(vaultDir).isAllowed)
    let junk1 = try await JunkCacheScanner(
        safetyGuard: sg1,
        environment: JunkScannerEnvironment(
            homeDirectory: sandbox.rootURL,
            trashDirectory: sandbox.url(".Trash"),
            runningBundleIDs: [],
            runningAppNames: [],
            includeSystemLogs: false
        )
    ).scan()
    try E2ERunner.expect(junk1.flatMap(\.entries).contains(where: { $0.name == "com.dynamic.App" }))
    let dups1 = try await LargeAndDuplicateScanner(safetyGuard: sg1).scanDuplicates(under: workDir, minBytes: 1_024)
    try E2ERunner.expectEqual(dups1.count, 1)
    let rows1 = try FileBrowserService(safetyGuard: sg1, homeDirectory: sandbox.rootURL).listDirectory(at: workDir)
    let vaultRow1 = try E2ERunner.expectNotNil(rows1.first(where: { $0.name == "DynamicVault" }))
    try E2ERunner.expect(!vaultRow1.isProtected)

    let updated = SweepPreferences(
        protectedBundleIDs: ["com.dynamic.App"],
        protectedPaths: [vaultDir.path]
    )
    try E2ERunner.expect(prefsStore.save(updated))
    let reloaded = PreferencesStore(fileURL: prefsURL).load()

    let sg2 = SafetyGuard(
        homeDirectory: sandbox.rootURL,
        selfBundlePath: nil,
        protectedPaths: reloaded.protectedPaths,
        protectedBundleIDs: reloaded.protectedBundleIDs
    )
    let fileOps2 = FileOperationsEngine(safetyGuard: sg2)
    let browser2 = FileBrowserService(safetyGuard: sg2, homeDirectory: sandbox.rootURL)
    let junk2 = JunkCacheScanner(
        safetyGuard: sg2,
        environment: JunkScannerEnvironment(
            homeDirectory: sandbox.rootURL,
            trashDirectory: sandbox.url(".Trash"),
            runningBundleIDs: [],
            runningAppNames: [],
            includeSystemLogs: false
        )
    )
    let res2 = LargeAndDuplicateScanner(safetyGuard: sg2)
    let removal2 = RemovalEngine(safetyGuard: sg2)

    let blockReport = removal2.remove(
        targets: [RemovalTarget(url: vaultDir, estimatedSize: 32_768, expectedCanonicalParent: sandbox.canonicalPath(for: workDir))],
        mode: .permanent,
        allowElevation: false
    )
    try E2ERunner.expect(!blockReport.isFullSuccess)
    try E2ERunner.expectEqual(blockReport.failures.count, 1)

    let renameErr = try await E2ERunner.expectThrowsAsync("Protected DynamicVault rename must fail") {
        _ = try await fileOps2.renameItem(
            at: vaultDir,
            toNewName: "RenamedVault",
            expectedSourceCanonicalParent: sandbox.canonicalPath(for: workDir)
        )
    }
    guard case .blockedBySafetyGuard = renameErr as? FileOperationError else {
        throw E2EAssertionFailure("Expected blockedBySafetyGuard, got \(renameErr)")
    }

    let rows2 = try browser2.listDirectory(at: workDir)
    let vaultRow2 = try E2ERunner.expectNotNil(rows2.first(where: { $0.name == "DynamicVault" }))
    let otherRow2 = try E2ERunner.expectNotNil(rows2.first(where: { $0.name == "Other" }))
    try E2ERunner.expect(vaultRow2.isProtected)
    try E2ERunner.expect(!otherRow2.isProtected)
    _ = otherDir

    let junkEntries2 = try await junk2.scan().flatMap(\.entries)
    try E2ERunner.expect(!junkEntries2.contains(where: { $0.name == "com.dynamic.App" }))
    try E2ERunner.expect(try await res2.scanDuplicates(under: workDir, minBytes: 1_024).isEmpty)

    try sandbox.createCorruptJSON(atRelativePath: "Config/preferences.json", variant: .truncated)
    let corruptBefore = try Data(contentsOf: prefsURL)
    let corruptStore = PreferencesStore(fileURL: prefsURL)
    _ = corruptStore.load()
    try E2ERunner.expect(corruptStore.isWriteBlockedDueToLoadError)
    try E2ERunner.expect(!corruptStore.save(SweepPreferences()))
    try E2ERunner.expectEqual(try Data(contentsOf: prefsURL), corruptBefore)
}

// MARK: - Tier 4: Real-World Application Scenarios (4 Cases)

runner.register(
    id: "t4-clean-workspace-lifecycle",
    tier: 4,
    feature: "F-2,F-4,F-5",
    name: "Clean sandboxed workspace lifecycle: favorites -> hidden/sort -> analyze -> mkdir/rename/move -> preview -> cleanup -> rescan"
) {
    let sandbox = try E2ESandbox(prefix: "t4-cwl")
    defer { sandbox.cleanup() }

    _ = try sandbox.createDirectory("Desktop")
    _ = try sandbox.createDirectory("Documents")
    _ = try sandbox.createDirectory("Downloads")
    _ = try sandbox.createDirectory("Applications")
    _ = try sandbox.createDirectory("Library/Caches")

    let workspaceURL = try sandbox.createDirectory("Workspace")
    let rawDir = try sandbox.createDirectory("Workspace/Raw")
    _ = try sandbox.createDirectory("Workspace/Keep")
    let mockTrash = try sandbox.createDirectory("MockTrash")

    let draftText = String(repeating: "Lifecycle draft note line.\n", count: 300) + String(repeating: "z", count: 8_192 - 300 * 27)
    let draftFile = try sandbox.createFile("Workspace/Raw/draft.md", utf8: draftText)
    let pngFile = try sandbox.createFile("Workspace/Raw/preview.png", data: minimalValidPNGData())
    let dataFile = try sandbox.createExactSizeFile("Workspace/Raw/data.bin", byteCount: 16_384, fillByte: 0xAA, sparse: false)
    let envFile = try sandbox.createExactSizeFile("Workspace/Raw/.env", byteCount: 4_096, fillByte: 0xBB, sparse: false)
    let archiveFile = try sandbox.createExactSizeFile("Workspace/Keep/archive.tar", byteCount: 32_768, fillByte: 0xCC, sparse: false)

    let dataAlloc = try allocatedBytesViaLstat(dataFile)
    let envAlloc = try allocatedBytesViaLstat(envFile)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let browser = FileBrowserService(safetyGuard: sg, homeDirectory: sandbox.rootURL)
    let analyzer = DiskSpaceAnalyzer(safetyGuard: sg)
    let historyStore = CleanupHistoryStore(fileURL: sandbox.url("State/history.json"))
    let removalEngine = RemovalEngine(
        safetyGuard: sg,
        historyStore: historyStore,
        localTrashHandler: makeMockTrashHandler(trashDir: mockTrash)
    )

    let favKinds = Set(browser.quickFavorites().map(\.kind))
    for expectedKind in [
        FileBrowserFavoriteKind.home,
        .desktop,
        .documents,
        .downloads,
        .applications,
        .caches,
        .volume,
    ] {
        try E2ERunner.expect(favKinds.contains(expectedKind), "Missing favorite kind \(expectedKind)")
    }

    let visibleRaw = try browser.listDirectory(at: rawDir, showHidden: false, sortBy: .size, ascending: false)
    let allRaw = try browser.listDirectory(at: rawDir, showHidden: true, sortBy: .size, ascending: false)
    try E2ERunner.expectEqual(visibleRaw.count, 3)
    try E2ERunner.expectEqual(allRaw.count, 4)
    let envEntry = try E2ERunner.expectNotNil(allRaw.first(where: { $0.name == ".env" }))
    try E2ERunner.expect(envEntry.isHidden)

    let volInfo = try DiskSpaceAnalyzer.volumeInfo(for: sandbox.rootURL)
    try E2ERunner.expectEqual(volInfo.usedBytes + volInfo.availableBytes, volInfo.totalBytes)

    let treeBefore = try await analyzer.analyze(root: workspaceURL, maxDepth: 5)
    let organizedDir = try await browser.fileOperationsEngine.createDirectory(
        named: "Organized",
        in: workspaceURL,
        expectedParentCanonicalParent: sandbox.canonicalPath(for: workspaceURL)
    )

    let draftInode = try inodeViaLstat(draftFile)
    let reportLower = try await browser.fileOperationsEngine.renameItem(
        at: draftFile,
        toNewName: "report.md",
        expectedSourceCanonicalParent: sandbox.canonicalPath(for: rawDir)
    )
    let reportUpper = try await browser.fileOperationsEngine.renameItem(
        at: reportLower,
        toNewName: "REPORT.MD",
        expectedSourceCanonicalParent: sandbox.canonicalPath(for: rawDir)
    )
    try E2ERunner.expectEqual(try inodeViaLstat(reportUpper), draftInode)

    let movedReport = try await browser.fileOperationsEngine.moveItem(
        from: reportUpper,
        to: organizedDir,
        expectedSourceCanonicalParent: sandbox.canonicalPath(for: rawDir),
        expectedDestinationCanonicalParent: sandbox.canonicalPath(for: organizedDir)
    )
    let movedPng = try await browser.fileOperationsEngine.moveItem(
        from: pngFile,
        to: organizedDir,
        expectedSourceCanonicalParent: sandbox.canonicalPath(for: rawDir),
        expectedDestinationCanonicalParent: sandbox.canonicalPath(for: organizedDir)
    )

    let reportPreview = try browser.loadPreview(at: movedReport)
    guard case .text = reportPreview.content else {
        throw E2EAssertionFailure("Expected .text preview for REPORT.MD")
    }
    let pngPreview = try browser.loadPreview(at: movedPng)
    guard case let .image(_, _, pngBytes) = pngPreview.content else {
        throw E2EAssertionFailure("Expected .image preview for preview.png")
    }
    try E2ERunner.expectEqual(pngBytes, minimalValidPNGData().count)
    let dataPreview = try browser.loadPreview(at: dataFile)
    guard case .hexDump = dataPreview.content else {
        throw E2EAssertionFailure("Expected .hexDump preview for data.bin")
    }

    let expectedDataPath = dataFile.standardizedFileURL.path
    let expectedEnvPath = envFile.standardizedFileURL.path
    let trashReport = removalEngine.remove(
        targets: [RemovalTarget(url: dataFile, estimatedSize: Int64(dataAlloc), expectedCanonicalParent: sandbox.canonicalPath(for: rawDir))],
        mode: .trash,
        actionTitle: "Trash Raw Data",
        allowElevation: false
    )
    try E2ERunner.expect(trashReport.isFullSuccess)
    let permReport = removalEngine.remove(
        targets: [RemovalTarget(url: envFile, estimatedSize: Int64(envAlloc), expectedCanonicalParent: sandbox.canonicalPath(for: rawDir))],
        mode: .permanent,
        actionTitle: "Permanent Delete Env",
        allowElevation: false
    )
    try E2ERunner.expect(permReport.isFullSuccess)

    let history = historyStore.load()
    try E2ERunner.expectEqual(history.count, 2)
    try E2ERunner.expectEqual(history[0].mode, .permanent)
    try E2ERunner.expectEqual(history[0].freedBytes, Int64(envAlloc))
    try E2ERunner.expectEqual(history[0].removedPaths, [expectedEnvPath])
    try E2ERunner.expectEqual(history[1].mode, .trash)
    try E2ERunner.expectEqual(history[1].freedBytes, Int64(dataAlloc))
    try E2ERunner.expectEqual(history[1].removedPaths, [expectedDataPath])

    let treeAfter = try await analyzer.analyze(root: workspaceURL, maxDepth: 5)
    try E2ERunner.expectEqual(treeBefore.bytes - treeAfter.bytes, dataAlloc + envAlloc)
    try E2ERunner.expect(RemovalEngine.entryExists(movedReport))
    try E2ERunner.expect(RemovalEngine.entryExists(movedPng))
    try E2ERunner.expect(RemovalEngine.entryExists(archiveFile))
}

runner.register(
    id: "t4-developer-workspace-cleanup",
    tier: 4,
    feature: "F-2,F-3,F-6,F-7,F-8",
    name: "Developer workspace cleanup: purges dev/browser caches + large/dup build artifacts while preserving protected repo/SSH/Archives/SimDevices"
) {
    let sandbox = try E2ESandbox(prefix: "t4-dwc")
    defer { sandbox.cleanup() }

    let sshKey = try sandbox.createExactSizeFile(".ssh/id_ed25519", byteCount: 4_096, fillByte: 0x01, sparse: false)
    let gitDir = try sandbox.createDirectory("Projects/MyApp/.git")
    let gitHead = try sandbox.createExactSizeFile("Projects/MyApp/.git/HEAD", byteCount: 4_096, fillByte: 0x02, sparse: false)
    let srcDir = try sandbox.createDirectory("Projects/MyApp/src")
    let srcMain = try sandbox.createExactSizeFile("Projects/MyApp/src/main.swift", byteCount: 4_096, fillByte: 0x03, sparse: false)
    let archiveBin = try sandbox.createExactSizeFile("Library/Developer/Xcode/Archives/2026-11/MyApp.xcarchive/app.bin", byteCount: 16_384, fillByte: 0x04, sparse: false)
    let simDeviceBin = try sandbox.createExactSizeFile("Library/Developer/CoreSimulator/Devices/UUID-1/data.bin", byteCount: 16_384, fillByte: 0x05, sparse: false)
    let appleCache = try sandbox.createExactSizeFile("Library/Caches/com.apple.dt.Instruments/x.bin", byteCount: 4_096, fillByte: 0x06, sparse: false)
    let selfData = try sandbox.createExactSizeFile("Library/Application Support/MacSweep/state.db", byteCount: 4_096, fillByte: 0x07, sparse: false)
    _ = try sandbox.createMockAppBundle(atRelativePath: "Applications/KeepTool.app", bundleID: "com.keeptool.app", name: "KeepTool")
    let keepToolCache = try sandbox.createExactSizeFile("Library/Caches/com.keeptool.app/cache.bin", byteCount: 4_096, fillByte: 0x08, sparse: false)

    _ = try sandbox.createExactSizeFile("Library/Developer/Xcode/DerivedData/MyApp-abc/Build/out.o", byteCount: 32_768, fillByte: 0x10, sparse: false)
    _ = try sandbox.createExactSizeFile("Library/Developer/CoreSimulator/Caches/dyld/sim.cache", byteCount: 16_384, fillByte: 0x11, sparse: false)
    _ = try sandbox.createExactSizeFile("Library/Caches/Homebrew/llvm.tar.gz", byteCount: 16_384, fillByte: 0x12, sparse: false)
    _ = try sandbox.createExactSizeFile(".npm/_cacache/index", byteCount: 8_192, fillByte: 0x13, sparse: false)
    _ = try sandbox.createExactSizeFile(".cache/pip/wheels/pkg.whl", byteCount: 8_192, fillByte: 0x14, sparse: false)
    _ = try sandbox.createExactSizeFile(".cargo/registry/cache/crate.crate", byteCount: 8_192, fillByte: 0x15, sparse: false)
    _ = try sandbox.createExactSizeFile("Library/Caches/Google/Chrome/Cache/c.dat", byteCount: 8_192, fillByte: 0x16, sparse: false)

    let hugeIso = try sandbox.createExactSizeFile("Projects/MyApp/build/huge-bundle.iso", byteCount: 60_000_000, sparse: true)
    let projectDup = try sandbox.createExactSizeFile("Projects/MyApp/build/dep-bundle-1.tar", byteCount: 32_768, fillByte: 0x77, sparse: false)
    let downloadDup = try sandbox.createExactSizeFile("Downloads/dep-bundle-1.tar", byteCount: 32_768, fillByte: 0x77, sparse: false)
    let mockTrash = try sandbox.createDirectory("MockTrash")

    let sg = SafetyGuard(
        homeDirectory: sandbox.rootURL,
        selfBundlePath: nil,
        protectedPaths: [gitDir.path, srcDir.path],
        protectedBundleIDs: ["com.keeptool.app"]
    )
    let junkScanner = JunkCacheScanner(
        safetyGuard: sg,
        environment: JunkScannerEnvironment(
            homeDirectory: sandbox.rootURL,
            trashDirectory: sandbox.url(".Trash"),
            runningBundleIDs: [],
            runningAppNames: [],
            includeSystemLogs: false
        )
    )
    let resScanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let historyStore = CleanupHistoryStore(fileURL: sandbox.url("State/history.json"))
    let removalEngine = RemovalEngine(
        safetyGuard: sg,
        historyStore: historyStore,
        localTrashHandler: makeMockTrashHandler(trashDir: mockTrash)
    )

    let junkEntries = try await junkScanner.scan().flatMap(\.entries)
    let selectedJunk = junkEntries.filter(\.isSelected)
    let selectedJunkPaths = selectedJunk.map { $0.url.standardizedFileURL.path }
    for expectedSub in [
        "DerivedData/MyApp-abc",
        "CoreSimulator/Caches/dyld",
        "Library/Caches/Homebrew",
        ".npm/_cacache",
        ".cache/pip",
        ".cargo/registry/cache",
        "Library/Caches/Google/Chrome",
    ] {
        try E2ERunner.expect(
            selectedJunkPaths.contains(where: { $0.contains(expectedSub) }),
            "Missing expected selected dev/browser cache '\(expectedSub)' in \(selectedJunkPaths)"
        )
    }

    let archiveEntries = junkEntries.filter { $0.url.path.contains("/Xcode/Archives/") }
    try E2ERunner.expect(!archiveEntries.isEmpty)
    try E2ERunner.expect(archiveEntries.allSatisfy { !$0.isSelected })

    let allJunkPaths = Set(junkEntries.map { $0.url.standardizedFileURL.path })
    try E2ERunner.expect(!allJunkPaths.contains(where: { $0.contains("CoreSimulator/Devices") }))
    try E2ERunner.expect(!allJunkPaths.contains(sandbox.url("Library/Caches/Google").standardizedFileURL.path))
    try E2ERunner.expect(!allJunkPaths.contains(where: { $0.contains("com.apple.dt.Instruments") }))
    try E2ERunner.expect(!allJunkPaths.contains(where: { $0.contains("Application Support/MacSweep") }))
    try E2ERunner.expect(!allJunkPaths.contains(where: { $0.contains("com.keeptool.app") }))

    let largeItems = try await resScanner.scanLargeFiles(under: sandbox.url("Projects"), minBytes: LargeFileSizeThreshold.mb50.rawValue)
    try E2ERunner.expectEqual(largeItems.map(\.name), ["huge-bundle.iso"])

    let dupGroups = resScanner.applySmartSelection(
        to: try await resScanner.scanDuplicates(under: sandbox.rootURL, minBytes: 1_024),
        preset: .preferNonDownloads
    )
    try E2ERunner.expectEqual(dupGroups.count, 1)
    let selectedDups = dupGroups[0].files.filter(\.isSelected)
    try E2ERunner.expectEqual(selectedDups.map(\.url.standardizedFileURL.path), [downloadDup.standardizedFileURL.path])

    let targets = selectedJunk.map {
        RemovalTarget(url: $0.url, estimatedSize: Int64($0.bytes), requiresAdmin: $0.requiresAdmin, expectedCanonicalParent: $0.expectedCanonicalParent)
    } + largeItems.map {
        RemovalTarget(url: $0.url, estimatedSize: Int64($0.bytes), expectedCanonicalParent: $0.expectedCanonicalParent)
    } + selectedDups.map {
        RemovalTarget(url: $0.url, estimatedSize: Int64(dupGroups[0].fileSize), expectedCanonicalParent: $0.expectedCanonicalParent)
    }

    let report = removalEngine.remove(targets: targets, mode: .trash, actionTitle: "Developer Cleanup", allowElevation: false)
    try E2ERunner.expect(report.isFullSuccess, "Developer cleanup failures: \(report.failures)")

    for preserved in [sshKey, gitHead, srcMain, archiveBin, simDeviceBin, appleCache, selfData, keepToolCache, projectDup] {
        try E2ERunner.expect(RemovalEngine.entryExists(preserved), "Protected/kept asset removed: \(preserved.path)")
    }
    try E2ERunner.expect(!RemovalEngine.entryExists(hugeIso))
    try E2ERunner.expect(!RemovalEngine.entryExists(downloadDup))

    let rescanSelected = try await junkScanner.scan().flatMap(\.entries).filter(\.isSelected)
    try E2ERunner.expect(rescanSelected.isEmpty)
}

runner.register(
    id: "t4-memory-pressure-and-resource-release",
    tier: 4,
    feature: "F-3,F-7,F-9",
    name: "MemoryReleaseService live snapshot, standard relief, large file cleanup, and mocked elevated purge + cancel isolation"
) {
    let sandbox = try E2ESandbox(prefix: "t4-mpr")
    defer { sandbox.cleanup() }

    let homeDir = try sandbox.createDirectory("Home")
    let protDir = try sandbox.createDirectory("Home/Protected")
    let importantMov = try sandbox.createExactSizeFile("Home/Protected/important.mov", byteCount: 60_000_000, sparse: true)
    let stalePkg = try sandbox.createExactSizeFile("Home/Downloads/stale_installer.pkg", byteCount: 60_000_000, sparse: true)
    let mockTrash = try sandbox.createDirectory("MockTrash")

    let oldDate = Date().addingTimeInterval(-100 * 86_400)
    try setFileTimes(at: stalePkg, accessDate: oldDate, modificationDate: oldDate)
    try setFileTimes(at: importantMov, accessDate: oldDate, modificationDate: oldDate)

    let sg = SafetyGuard(homeDirectory: homeDir, selfBundlePath: nil, protectedPaths: [protDir.path])
    let historyStore = CleanupHistoryStore(fileURL: sandbox.url("State/history.json"))
    let removalEngine = RemovalEngine(
        safetyGuard: sg,
        historyStore: historyStore,
        localTrashHandler: makeMockTrashHandler(trashDir: mockTrash)
    )

    let memServiceStd = MemoryReleaseService(privilegedExecutor: PrivilegedExecutor(safetyGuard: sg))
    let snapBefore = memServiceStd.captureSnapshot()
    try E2ERunner.expectEqual(snapBefore.totalBytes, ProcessInfo.processInfo.physicalMemory)
    try E2ERunner.expect(snapBefore.usedFraction >= 0.0 && snapBefore.usedFraction <= 1.0)
    try E2ERunner.expect(snapBefore.swapUsedBytes <= snapBefore.swapTotalBytes)
    try E2ERunner.expect(snapBefore.pageSizeBytes > 0)

    let reliefStd = try await memServiceStd.releaseMemory(allowElevation: false)
    try E2ERunner.expect(!reliefStd.usedElevation)
    try E2ERunner.expectEqual(reliefStd.methodUsed, "standard_pressure_relief")
    try E2ERunner.expect(reliefStd.reclaimedEstimateBytes <= snapBefore.totalBytes)
    try E2ERunner.expect(historyStore.load().isEmpty)

    let largeItems = try await LargeAndDuplicateScanner(safetyGuard: sg).scanLargeFiles(
        under: homeDir,
        minBytes: LargeFileSizeThreshold.mb50.rawValue,
        olderThanDays: 30
    )
    try E2ERunner.expectEqual(largeItems.map(\.name), ["stale_installer.pkg"])

    let report = removalEngine.remove(
        targets: [RemovalTarget(url: largeItems[0].url, estimatedSize: Int64(largeItems[0].bytes), expectedCanonicalParent: largeItems[0].expectedCanonicalParent)],
        mode: .trash,
        actionTitle: "Stale Installer Cleanup",
        allowElevation: false
    )
    try E2ERunner.expect(report.isFullSuccess)
    try E2ERunner.expectEqual(historyStore.load().count, 1)
    try E2ERunner.expect(RemovalEngine.entryExists(importantMov))

    let capturedPurgeScript = LockedBox<String?>(nil)
    let successMem = MemoryReleaseService(privilegedExecutor: PrivilegedExecutor(
        safetyGuard: sg,
        adminShellRunner: { script in
            capturedPurgeScript.set(script)
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    ))
    let reliefElev = try await successMem.releaseMemory(allowElevation: true)
    try E2ERunner.expect(reliefElev.usedElevation)
    try E2ERunner.expectEqual(reliefElev.methodUsed, "purge")
    try E2ERunner.expectContains(try E2ERunner.expectNotNil(capturedPurgeScript.get()), "/usr/sbin/purge")
    try E2ERunner.expectEqual(historyStore.load().count, 1)

    let cancelMem = MemoryReleaseService(privilegedExecutor: PrivilegedExecutor(
        safetyGuard: sg,
        adminShellRunner: { _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "execution error: User canceled. (-128)")
        }
    ))
    let cancelErr = try await E2ERunner.expectThrowsAsync("Expected userCancelled error") {
        _ = try await cancelMem.releaseMemory(allowElevation: true)
    }
    try E2ERunner.expectEqual(cancelErr as? PrivilegedError, .userCancelled)
    try E2ERunner.expectEqual(historyStore.load().count, 1)
}

runner.register(
    id: "t4-hostile-filesystem-survival",
    tier: 4,
    feature: "F-2,F-3,F-4,F-5,F-6,F-8",
    name: "Hostile filesystem survival: symlink loops, FIFOs, uchg, 0o000, bidi/control chars, TOCTOU swap across all scanners & engines"
) {
    let sandbox = try E2ESandbox(prefix: "t4-hfs")
    defer { sandbox.cleanup() }

    let workDir = try sandbox.createDirectory("Work")
    let docsDir = try sandbox.createDirectory("Documents")
    let sshDir = try sandbox.createDirectory(".ssh")

    let loopA = try sandbox.createSymlink(atRelativePath: "Work/loopA", targetURL: sandbox.url("Work/loopB"))
    let loopB = try sandbox.createSymlink(atRelativePath: "Work/loopB", targetURL: sandbox.url("Work/loopA"))
    let escapeSSH = try sandbox.createSymlink(atRelativePath: "Work/escapeSSH", targetURL: sshDir)
    let brokenLink = try sandbox.createSymlink(atRelativePath: "Work/broken.link", targetPath: "/nonexistent/macsweep/target")
    _ = try sandbox.createSymlink(atRelativePath: "Library/Caches/EscapeDocs", targetURL: docsDir)
    _ = (loopA, loopB)

    let hostileFifo = try sandbox.createFIFO(atRelativePath: "Work/hostile.fifo")
    _ = try sandbox.createFIFO(atRelativePath: "Library/Caches/com.hostile.Fifo/cache.fifo")

    let lockedFile = try sandbox.createExactSizeFile("Work/locked.dat", byteCount: 16_384, fillByte: 0x61, sparse: false)
    try sandbox.setUserImmutable(lockedFile, locked: true)

    let noAccessDir = try sandbox.createDirectory("Work/NoAccessDir")
    _ = try sandbox.createExactSizeFile("Work/NoAccessDir/inside.bin", byteCount: 16_384, fillByte: 0x62, sparse: false)
    try E2ERunner.expect(Darwin.chmod(noAccessDir.path, 0o000) == 0)
    defer { _ = Darwin.chmod(noAccessDir.path, 0o700) }

    let noAccessFile = try sandbox.createExactSizeFile("Work/NoAccessFile.dat", byteCount: 16_384, fillByte: 0x63, sparse: false)
    try E2ERunner.expect(Darwin.chmod(noAccessFile.path, 0o000) == 0)
    defer { _ = Darwin.chmod(noAccessFile.path, 0o600) }

    let bidiFile = try sandbox.createExactSizeFile("Work/invoice\u{202E}gpj.exe", byteCount: 4_096, fillByte: 0x64, sparse: false)
    let ctrlFile = try sandbox.createExactSizeFile("Work/evil\n\tname.txt", byteCount: 4_096, fillByte: 0x65, sparse: false)

    let swapParent = try sandbox.createDirectory("Work/SwapParent")
    let victimFile = try sandbox.createExactSizeFile("Work/SwapParent/victim.bin", byteCount: 16_384, fillByte: 0x66, sparse: false)
    let decoyDir = try sandbox.createDirectory("DecoyTarget")
    let decoyVictim = try sandbox.createExactSizeFile("DecoyTarget/victim.bin", byteCount: 16_384, fillByte: 0x67, sparse: false)

    let sshKey = try sandbox.createExactSizeFile(".ssh/id_rsa", byteCount: 4_096, fillByte: 0x68, sparse: false)
    let secretDoc = try sandbox.createExactSizeFile("Documents/secret.txt", byteCount: 4_096, fillByte: 0x69, sparse: false)
    let benignA = try sandbox.createExactSizeFile("Work/benign_a.bin", byteCount: 16_384, fillByte: 0x70, sparse: false)
    let benignB = try sandbox.createExactSizeFile("Work/benign_b.bin", byteCount: 16_384, fillByte: 0x70, sparse: false)
    _ = try sandbox.createExactSizeFile("Library/Caches/com.hostile.Ok/ok.bin", byteCount: 4_096, fillByte: 0x71, sparse: false)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil, protectedPaths: [docsDir.path])
    let analyzer = DiskSpaceAnalyzer(safetyGuard: sg)
    let browser = FileBrowserService(safetyGuard: sg, homeDirectory: sandbox.rootURL)
    let fileOps = browser.fileOperationsEngine
    let junkScanner = JunkCacheScanner(
        safetyGuard: sg,
        environment: JunkScannerEnvironment(
            homeDirectory: sandbox.rootURL,
            trashDirectory: sandbox.url(".Trash"),
            runningBundleIDs: [],
            runningAppNames: [],
            includeSystemLogs: false
        )
    )
    let resScanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let removalEngine = RemovalEngine(safetyGuard: sg)

    let progressEvents = LockedBox<[DiskScanProgress]>([])
    let analyzeStart = Date()
    let rootTree = try await analyzer.analyze(root: sandbox.rootURL, maxDepth: 4) { progress in
        progressEvents.append(progress)
    }
    try E2ERunner.expect(Date().timeIntervalSince(analyzeStart) < 5.0)
    let maxSkippedSymlinks = progressEvents.get().map(\.skippedSymlinks).max() ?? 0
    try E2ERunner.expect(maxSkippedSymlinks >= 4)

    let workTree = try await analyzer.analyze(root: workDir, maxDepth: 3)
    if Darwin.geteuid() != 0 {
        let noAccessNode = try E2ERunner.expectNotNil(workTree.children.first(where: { $0.name == "NoAccessDir" }))
        try E2ERunner.expect(!noAccessNode.isAccessible)
    }
    let docsNode = try E2ERunner.expectNotNil(rootTree.children.first(where: { $0.name == "Documents" }))
    try E2ERunner.expect(docsNode.isProtected)
    let sshNode = try E2ERunner.expectNotNil(rootTree.children.first(where: { $0.name == ".ssh" }))
    try E2ERunner.expect(sshNode.isProtected)

    let entries = try browser.listDirectory(at: workDir, showHidden: true)
    let lockedEntry = try E2ERunner.expectNotNil(entries.first(where: { $0.name == "locked.dat" }))
    try E2ERunner.expect(lockedEntry.isUserImmutable && lockedEntry.isMutationLocked)

    let fifoEntry = try E2ERunner.expectNotNil(entries.first(where: { $0.name == "hostile.fifo" }))
    try E2ERunner.expectEqual(fifoEntry.kind, .special)

    let bidiEntry = try E2ERunner.expectNotNil(entries.first(where: { $0.url == bidiFile.standardizedFileURL }))
    try E2ERunner.expectContains(bidiEntry.displayName, "\\u{202E}")
    let ctrlEntry = try E2ERunner.expectNotNil(entries.first(where: { $0.url == ctrlFile.standardizedFileURL }))
    try E2ERunner.expectContains(ctrlEntry.displayName, "\\n")
    try E2ERunner.expectContains(ctrlEntry.displayName, "\\t")

    let fifoStart = Date()
    let fifoPreview = try browser.loadPreview(at: hostileFifo)
    try E2ERunner.expect(Date().timeIntervalSince(fifoStart) < 1.0)
    try E2ERunner.expectEqual(fifoPreview.content, .unavailable(reason: .specialFile))

    let brokenPreview = try browser.loadPreview(at: brokenLink)
    try E2ERunner.expectEqual(brokenPreview.content, .unavailable(reason: .symbolicLink))
    let loopPreview = try browser.loadPreview(at: loopA)
    try E2ERunner.expectEqual(loopPreview.content, .unavailable(reason: .symbolicLink))
    if Darwin.geteuid() != 0 {
        let noAccessPreview = try browser.loadPreview(at: noAccessFile)
        try E2ERunner.expectEqual(noAccessPreview.content, .unavailable(reason: .permissionDenied))
    }

    let lockErr = try await E2ERunner.expectThrowsAsync("Renaming uchg file must throw") {
        _ = try await fileOps.renameItem(
            at: lockedFile,
            toNewName: "unlocked.dat",
            expectedSourceCanonicalParent: lockedEntry.expectedCanonicalParent
        )
    }
    guard case .userImmutable = lockErr as? FileOperationError else {
        throw E2EAssertionFailure("Expected FileOperationError.userImmutable, got \(lockErr)")
    }

    let sshErr = try await E2ERunner.expectThrowsAsync("Creating dir through symlink to .ssh must be blocked") {
        _ = try await fileOps.createDirectory(named: "pwn", in: escapeSSH)
    }
    guard case .blockedBySafetyGuard = sshErr as? FileOperationError else {
        throw E2EAssertionFailure("Expected FileOperationError.blockedBySafetyGuard, got \(sshErr)")
    }

    let nulErr = try await E2ERunner.expectThrowsAsync("NUL name must throw invalidName") {
        _ = try await fileOps.renameItem(
            at: benignA,
            toNewName: "bad\0name",
            expectedSourceCanonicalParent: sandbox.canonicalPath(for: workDir)
        )
    }
    guard case .invalidName = nulErr as? FileOperationError else {
        throw E2EAssertionFailure("Expected FileOperationError.invalidName, got \(nulErr)")
    }

    let junkStart = Date()
    let junkEntries = try await junkScanner.scan().flatMap(\.entries)
    try E2ERunner.expect(Date().timeIntervalSince(junkStart) < 5.0)
    try E2ERunner.expect(junkEntries.contains(where: { $0.name == "com.hostile.Ok" }))
    try E2ERunner.expect(!junkEntries.contains(where: { $0.name == "EscapeDocs" }))
    try E2ERunner.expect(!junkEntries.contains(where: { $0.url.path.contains("cache.fifo") }))

    let dupStart = Date()
    let dupGroups = try await resScanner.scanDuplicates(under: workDir, minBytes: 1_024)
    try E2ERunner.expect(Date().timeIntervalSince(dupStart) < 5.0)
    try E2ERunner.expectEqual(dupGroups.count, 1)
    let dupPaths = Set(dupGroups[0].files.map { $0.url.standardizedFileURL.path })
    try E2ERunner.expectEqual(dupPaths, Set([benignA.standardizedFileURL.path, benignB.standardizedFileURL.path]))

    let victimExpectedParent = sandbox.canonicalPath(for: swapParent)
    try FileManager.default.removeItem(at: swapParent)
    try sandbox.createSymlink(atRelativePath: "Work/SwapParent", targetURL: decoyDir)

    let expectedLockedPath = lockedFile.standardizedFileURL.path
    let expectedBenignBPath = benignB.standardizedFileURL.path
    let expectedVictimURL = victimFile.standardizedFileURL
    let expectedEscapeURL = escapeSSH.standardizedFileURL
    let report = removalEngine.remove(
        targets: [
            RemovalTarget(url: victimFile, estimatedSize: 16_384, expectedCanonicalParent: victimExpectedParent),
            RemovalTarget(url: escapeSSH, estimatedSize: 0, expectedCanonicalParent: sandbox.canonicalPath(for: workDir)),
            RemovalTarget(url: lockedFile, estimatedSize: 16_384, expectedCanonicalParent: sandbox.canonicalPath(for: workDir)),
            RemovalTarget(url: benignB, estimatedSize: 16_384, expectedCanonicalParent: sandbox.canonicalPath(for: workDir)),
        ],
        mode: .permanent,
        actionTitle: "Hostile Cleanup",
        allowElevation: false
    )

    try E2ERunner.expectEqual(Set(report.succeededURLs.map(\.path)), Set([expectedLockedPath, expectedBenignBPath]))
    try E2ERunner.expectEqual(report.failures.count, 2)
    try E2ERunner.expect(report.failures.contains(where: { $0.url == expectedVictimURL && $0.reason.contains("TOCTOU") }))
    try E2ERunner.expect(report.failures.contains(where: { $0.url == expectedEscapeURL }))

    try E2ERunner.expect(RemovalEngine.entryExists(decoyVictim))
    try E2ERunner.expect(RemovalEngine.entryExists(sshKey))
    try E2ERunner.expect(RemovalEngine.entryExists(secretDoc))
    try E2ERunner.expect(RemovalEngine.entryExists(benignA))
    try E2ERunner.expect(!RemovalEngine.entryExists(lockedFile))
    try E2ERunner.expect(!RemovalEngine.entryExists(benignB))
}

await runner.runAndExit()

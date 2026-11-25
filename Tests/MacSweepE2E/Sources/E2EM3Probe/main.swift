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
}

private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        await withCheckedContinuation { cont in
            let shouldResumeImmediately: Bool = lock.withLock {
                if isOpen {
                    return true
                }
                continuation = cont
                return false
            }
            if shouldResumeImmediately {
                cont.resume()
            }
        }
    }

    func open() {
        let cont: CheckedContinuation<Void, Never>? = lock.withLock {
            isOpen = true
            let c = continuation
            continuation = nil
            return c
        }
        cont?.resume()
    }
}

private final class ResourceCancelProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var _invoked = false
    private var _progressEvents: [ResourceScanProgress] = []
    private var _taskToCancel: Task<Void, Error>?

    func markInvoked() {
        lock.withLock { _invoked = true }
    }

    func setTaskToCancel(_ task: Task<Void, Error>) {
        lock.withLock { _taskToCancel = task }
    }

    func recordProgressAndCancel(_ progress: ResourceScanProgress) {
        let task: Task<Void, Error>? = lock.withLock {
            _progressEvents.append(progress)
            return _taskToCancel
        }
        task?.cancel()
    }

    var invoked: Bool {
        lock.withLock { _invoked }
    }

    var progressEvents: [ResourceScanProgress] {
        lock.withLock { _progressEvents }
    }
}

private func sha256Hex(of url: URL) throws -> String {
    let data = try Data(contentsOf: url)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func makeDistinctPayload(byteCount: Int, fillByte: UInt8, mutateOffset: Int? = nil, mutateByte: UInt8 = 0xFF) -> Data {
    var data = Data(repeating: fillByte, count: byteCount)
    if let offset = mutateOffset, offset >= 0, offset < byteCount {
        data[offset] = mutateByte
    }
    return data
}

private func makeMockTrashHandler(trashDir: URL) -> RemovalEngine.LocalTrashHandler {
    { itemURL in
        let dst = trashDir.appendingPathComponent("\(UUID().uuidString)-\(itemURL.lastPathComponent)")
        try FileManager.default.moveItem(at: itemURL, to: dst)
    }
}

private func setModificationDate(_ date: Date, for url: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

let runner = E2ERunner(probeName: "E2EM3Probe")

// MARK: - Feature F6: Junk & Cache Cleaner (6 Tier 1 + 6 Tier 2 = 12 Cases)

runner.register(
    id: "f6-t1-user-app-caches",
    tier: 1,
    feature: "F-6",
    name: "JunkCacheScanner scans user & app caches, computes accurate totals, and validates subpaths"
) {
    let sandbox = try E2ESandbox(prefix: "f6-t1-caches")
    defer { sandbox.cleanup() }

    _ = try sandbox.createExactSizeFile("Library/Caches/com.acme.AppA/a.bin", byteCount: 4096, fillByte: 0x11)
    _ = try sandbox.createExactSizeFile("Library/Caches/com.acme.AppB/b.bin", byteCount: 8192, fillByte: 0x22)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox.rootURL)
    let categories = try await scanner.scan()

    let appCacheCategory = try E2ERunner.expectNotNil(
        categories.first(where: { $0.category == .userCaches || $0.category == .appCaches }),
        "Expected user/app caches category"
    )
    let entryNames = Set(appCacheCategory.entries.map(\.name))
    try E2ERunner.expect(entryNames.contains("com.acme.AppA"), "Missing com.acme.AppA cache entry")
    try E2ERunner.expect(entryNames.contains("com.acme.AppB"), "Missing com.acme.AppB cache entry")
    try E2ERunner.expectEqual(appCacheCategory.totalBytes, UInt64(12_288), "Cache category totalBytes mismatch")

    for entry in appCacheCategory.entries {
        try E2ERunner.expectEqual(
            entry.expectedCanonicalParent,
            SandboxBuilder.canonicalParentPath(for: entry.url),
            "expectedCanonicalParent must match canonical parent"
        )
        try E2ERunner.expect(
            sg.validateCacheSubpath(entry.url).isAllowed,
            "Cache entry \(entry.url.path) must pass validateCacheSubpath"
        )
    }
}

runner.register(
    id: "f6-t1-shared-vendor-subpaths",
    tier: 1,
    feature: "F-6",
    name: "JunkCacheScanner drills into sharedVendorFolderNames without selecting bare vendor root"
) {
    let sandbox = try E2ESandbox(prefix: "f6-t1-vendor")
    defer { sandbox.cleanup() }

    _ = try sandbox.createExactSizeFile("Library/Caches/Google/Chrome/Cache/c1.dat", byteCount: 4096)
    _ = try sandbox.createExactSizeFile("Library/Caches/Microsoft/Edge/c2.dat", byteCount: 4096)
    _ = try sandbox.createExactSizeFile("Library/Caches/Adobe/Premiere/c3.dat", byteCount: 4096)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox.rootURL)
    let categories = try await scanner.scan()
    let allEntries = categories.flatMap(\.entries)
    let allPaths = Set(allEntries.map { $0.url.standardizedFileURL.path })

    for vendor in ["Google", "Microsoft", "Adobe"] {
        let bareVendorPath = sandbox.url("Library/Caches/\(vendor)").standardizedFileURL.path
        try E2ERunner.expect(!allPaths.contains(bareVendorPath), "Bare vendor root \(vendor) must never be emitted")
        try E2ERunner.expect(!sg.validateCacheSubpath(URL(fileURLWithPath: bareVendorPath)).isAllowed)
    }

    for entry in allEntries {
        try E2ERunner.expect(
            sg.validateCacheSubpath(entry.url).isAllowed,
            "Drilled-down entry \(entry.url.path) must pass validateCacheSubpath"
        )
    }
    try E2ERunner.expect(allEntries.count >= 3, "Expected drilled-down vendor app cache entries")
}

runner.register(
    id: "f6-t1-logs-and-crash-reports",
    tier: 1,
    feature: "F-6",
    name: "JunkCacheScanner discovers user logs & DiagnosticReports children while preserving root dirs"
) {
    let sandbox = try E2ESandbox(prefix: "f6-t1-logs")
    defer { sandbox.cleanup() }

    _ = try sandbox.createExactSizeFile("Library/Logs/AppFoo/foo.log", byteCount: 2048)
    _ = try sandbox.createExactSizeFile("Library/Logs/DiagnosticReports/AppFoo.crash", byteCount: 2048)

    let logsRoot = sandbox.url("Library/Logs")
    let diagRoot = sandbox.url("Library/Logs/DiagnosticReports")

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox.rootURL)
    let categories = try await scanner.scan()

    let logsCat = try E2ERunner.expectNotNil(
        categories.first(where: { $0.category == .logs }),
        "Expected logs category"
    )
    let logPaths = Set(logsCat.entries.map { $0.url.standardizedFileURL.path })
    try E2ERunner.expect(!logPaths.contains(logsRoot.standardizedFileURL.path), "Library/Logs root must not be targeted")
    try E2ERunner.expect(!logPaths.contains(diagRoot.standardizedFileURL.path), "DiagnosticReports root must not be targeted")
    try E2ERunner.expect(!sg.validateForRemoval(logsRoot).isAllowed)
    try E2ERunner.expect(!sg.validateForRemoval(diagRoot).isAllowed)
    try E2ERunner.expect(!logsCat.entries.isEmpty, "Expected child log entries")
    for entry in logsCat.entries {
        try E2ERunner.expect(sg.validateForRemoval(entry.url).isAllowed, "Log child \(entry.name) should be removable")
    }
}

runner.register(
    id: "f6-t1-dev-caches-default-selection",
    tier: 1,
    feature: "F-6",
    name: "JunkCacheScanner discovers developer caches and keeps Xcode Archives unselected by default"
) {
    let sandbox = try E2ESandbox(prefix: "f6-t1-dev")
    defer { sandbox.cleanup() }

    _ = try sandbox.createExactSizeFile("Library/Developer/Xcode/DerivedData/MyProj/d.dat", byteCount: 8192)
    _ = try sandbox.createExactSizeFile("Library/Developer/Xcode/Archives/2026-01/a.xcarchive", byteCount: 16_384)
    _ = try sandbox.createExactSizeFile("Library/Caches/Homebrew/pkg.tar.gz", byteCount: 4096)
    _ = try sandbox.createExactSizeFile(".npm/_cacache/idx", byteCount: 2048)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox.rootURL)
    let categories = try await scanner.scan()

    let devCat = try E2ERunner.expectNotNil(
        categories.first(where: { $0.category == .developerCaches }),
        "Expected developer caches category"
    )
    try E2ERunner.expect(!devCat.safetyNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Developer caches safetyNote must be non-empty")

    let archiveEntries = devCat.entries.filter { $0.url.path.contains("/Archives") }
    try E2ERunner.expect(!archiveEntries.isEmpty, "Expected Xcode Archives entry to be discovered")
    for archive in archiveEntries {
        try E2ERunner.expect(!archive.isSelected, "Xcode Archives must default to isSelected == false")
    }
    try E2ERunner.expect(devCat.entries.contains(where: { $0.url.path.contains("DerivedData") }), "Expected DerivedData entry")
}

runner.register(
    id: "f6-t1-trash-and-browser-caches",
    tier: 1,
    feature: "F-6",
    name: "JunkCacheScanner enumerates Trash items and browser caches without touching browser profile data"
) {
    let sandbox = try E2ESandbox(prefix: "f6-t1-trash-browser")
    defer { sandbox.cleanup() }

    _ = try sandbox.createExactSizeFile(".Trash/old.zip", byteCount: 4096)
    _ = try sandbox.createExactSizeFile("Library/Caches/Google/Chrome/Default/Cache/data_0", byteCount: 4096)
    _ = try sandbox.createFile("Library/Application Support/Google/Chrome/Default/Bookmarks", utf8: "{\"roots\":{}}")

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox.rootURL)
    let categories = try await scanner.scan()

    let trashCat = try E2ERunner.expectNotNil(categories.first(where: { $0.category == .trash }))
    try E2ERunner.expect(trashCat.entries.contains(where: { $0.name == "old.zip" }), "Expected old.zip in Trash category")

    let allPaths = categories.flatMap(\.entries).map { $0.url.standardizedFileURL.path }
    try E2ERunner.expect(!allPaths.contains(where: { $0.contains("Bookmarks") }), "Browser Bookmarks must never be flagged as junk")
    try E2ERunner.expect(allPaths.contains(where: { $0.contains("/Library/Caches/Google/Chrome") }), "Expected Chrome cache subpath")
}

runner.register(
    id: "f6-t1-remove-and-history-audit",
    tier: 1,
    feature: "F-6",
    name: "Selected junk entries remove cleanly via RemovalEngine .trash and record CleanupRecord"
) {
    let sandbox = try E2ESandbox(prefix: "f6-t1-remove")
    defer { sandbox.cleanup() }

    _ = try sandbox.createExactSizeFile("Library/Caches/com.acme.CleanMe/tmp.bin", byteCount: 4096)
    let mockTrash = try sandbox.createDirectory("MockTrash")
    let historyStore = CleanupHistoryStore(fileURL: sandbox.url("State/history.json"))

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox.rootURL)
    let categories = try await scanner.scan()

    let entry = try E2ERunner.expectNotNil(
        categories.flatMap(\.entries).first(where: { $0.url.path.contains("com.acme.CleanMe") }),
        "Expected com.acme.CleanMe entry"
    )
    let expectedRemovedPath = entry.url.standardizedFileURL.path

    let engine = RemovalEngine(
        safetyGuard: sg,
        historyStore: historyStore,
        localTrashHandler: makeMockTrashHandler(trashDir: mockTrash)
    )
    let target = RemovalTarget(
        url: entry.url,
        estimatedSize: Int64(entry.bytes),
        requiresAdmin: entry.requiresAdmin,
        expectedCanonicalParent: entry.expectedCanonicalParent
    )
    let report = engine.remove(targets: [target], mode: .trash, actionTitle: "Junk Cleanup", allowElevation: false)

    try E2ERunner.expect(report.isFullSuccess, "Junk removal failed: \(report.failures)")
    try E2ERunner.expect(!RemovalEngine.entryExists(entry.url), "Original cache entry should be removed")

    let history = historyStore.load()
    let latest = try E2ERunner.expectNotNil(history.first)
    try E2ERunner.expectEqual(latest.actionTitle, "Junk Cleanup")
    try E2ERunner.expectEqual(latest.itemCount, 1)
    try E2ERunner.expectEqual(latest.freedBytes, 4096)
    try E2ERunner.expectEqual(latest.removedPaths, [expectedRemovedPath])
}

runner.register(
    id: "f6-t2-apple-and-self-cache-exclusion",
    tier: 2,
    feature: "F-6",
    name: "JunkCacheScanner excludes Apple, com.apple.*, group.com.apple.*, and local.macsweep caches"
) {
    let sandbox = try E2ESandbox(prefix: "f6-t2-apple-self")
    defer { sandbox.cleanup() }

    let appleCache = try sandbox.createDirectory("Library/Caches/Apple")
    _ = try sandbox.createExactSizeFile("Library/Caches/Apple/x.bin", byteCount: 1024)
    let safariCache = try sandbox.createDirectory("Library/Caches/com.apple.Safari")
    _ = try sandbox.createExactSizeFile("Library/Caches/com.apple.Safari/y.bin", byteCount: 1024)
    let groupApple = try sandbox.createDirectory("Library/Caches/group.com.apple.notes")
    _ = try sandbox.createExactSizeFile("Library/Caches/group.com.apple.notes/z.bin", byteCount: 1024)
    let selfCache = try sandbox.createDirectory("Library/Caches/local.macsweep")
    _ = try sandbox.createExactSizeFile("Library/Caches/local.macsweep/w.bin", byteCount: 1024)
    let benignCache = try sandbox.createDirectory("Library/Caches/com.benign.app")
    _ = try sandbox.createExactSizeFile("Library/Caches/com.benign.app/ok.bin", byteCount: 1024)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    for protectedURL in [appleCache, safariCache, groupApple, selfCache] {
        try E2ERunner.expect(!sg.validateCacheSubpath(protectedURL).isAllowed, "Must block \(protectedURL.lastPathComponent)")
    }
    try E2ERunner.expect(sg.validateCacheSubpath(benignCache).isAllowed, "Benign cache must be allowed")

    let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox.rootURL)
    let categories = try await scanner.scan()
    let scannedPaths = Set(categories.flatMap(\.entries).map { $0.url.standardizedFileURL.path })

    for protectedURL in [appleCache, safariCache, groupApple, selfCache] {
        try E2ERunner.expect(
            !scannedPaths.contains(protectedURL.standardizedFileURL.path),
            "Protected cache \(protectedURL.lastPathComponent) must be omitted"
        )
    }
    try E2ERunner.expect(scannedPaths.contains(benignCache.standardizedFileURL.path), "Benign cache must be scanned")
}

runner.register(
    id: "f6-t2-symlink-escape-outside-caches",
    tier: 2,
    feature: "F-6",
    name: "JunkCacheScanner skips symlinks inside Library/Caches escaping to Documents or /System"
) {
    let sandbox = try E2ESandbox(prefix: "f6-t2-symlink")
    defer { sandbox.cleanup() }

    let secret = try sandbox.createFile("Documents/secret.txt", utf8: "do-not-delete")
    let docsDir = sandbox.url("Documents")
    _ = try sandbox.createDirectory("Library/Caches")
    let escapeDocs = try sandbox.createSymlink(atRelativePath: "Library/Caches/EscapeDocs", targetURL: docsDir)
    let escapeSys = try sandbox.createSymlink(atRelativePath: "Library/Caches/EscapeSys", targetPath: "/System")

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    try E2ERunner.expect(!sg.validateCacheSubpath(escapeDocs).isAllowed, "Symlink to Documents must fail validateCacheSubpath")
    try E2ERunner.expect(!sg.validateCacheSubpath(escapeSys).isAllowed, "Symlink to /System must fail validateCacheSubpath")

    let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox.rootURL)
    let categories = try await scanner.scan()
    let paths = categories.flatMap(\.entries).map { $0.url.standardizedFileURL.path }

    try E2ERunner.expect(!paths.contains(where: { $0.contains("EscapeDocs") || $0.contains("EscapeSys") || $0.contains("secret.txt") }))
    try E2ERunner.expectEqual(try String(contentsOf: secret, encoding: .utf8), "do-not-delete")
}

runner.register(
    id: "f6-t2-protected-paths-and-prefs",
    tier: 2,
    feature: "F-6",
    name: "SweepPreferences.protectedPaths and protectedBundleIDs prevent junk removal"
) {
    let sandbox = try E2ESandbox(prefix: "f6-t2-prefs")
    defer { sandbox.cleanup() }

    let keepByPathDir = try sandbox.createDirectory("Library/Caches/com.keep.ByPath")
    _ = try sandbox.createExactSizeFile("Library/Caches/com.keep.ByPath/data.bin", byteCount: 4096)
    let keepByBundleDir = try sandbox.createDirectory("Library/Caches/com.keep.ByBundle")
    _ = try sandbox.createExactSizeFile("Library/Caches/com.keep.ByBundle/data.bin", byteCount: 4096)
    let dropDir = try sandbox.createDirectory("Library/Caches/com.drop.App")
    _ = try sandbox.createExactSizeFile("Library/Caches/com.drop.App/data.bin", byteCount: 4096)

    let prefsURL = sandbox.url("Config/preferences.json")
    let prefsStore = PreferencesStore(fileURL: prefsURL)
    var prefs = SweepPreferences()
    prefs.protectedPaths = [keepByPathDir.path]
    prefs.protectedBundleIDs = ["com.keep.ByBundle"]
    try E2ERunner.expect(prefsStore.save(prefs), "PreferencesStore.save must succeed")

    let reloaded = PreferencesStore(fileURL: prefsURL).load()
    let sg = SafetyGuard(
        homeDirectory: sandbox.rootURL,
        selfBundlePath: nil,
        protectedPaths: reloaded.protectedPaths,
        protectedBundleIDs: reloaded.protectedBundleIDs
    )

    let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox.rootURL)
    let categories = try await scanner.scan()
    let paths = Set(categories.flatMap(\.entries).map { $0.url.standardizedFileURL.path })
    try E2ERunner.expect(!paths.contains(keepByPathDir.standardizedFileURL.path), "protectedPaths cache must be excluded from scan")
    try E2ERunner.expect(!paths.contains(keepByBundleDir.standardizedFileURL.path), "protectedBundleIDs cache must be excluded from scan")
    try E2ERunner.expect(paths.contains(dropDir.standardizedFileURL.path), "Unprotected cache must still be discovered")

    let expectedDropURL = dropDir.standardizedFileURL
    let mockTrash = try sandbox.createDirectory("MockTrash")
    let engine = RemovalEngine(safetyGuard: sg, localTrashHandler: makeMockTrashHandler(trashDir: mockTrash))
    let report = engine.remove(
        targets: [
            RemovalTarget(url: keepByPathDir, estimatedSize: 4096),
            RemovalTarget(url: keepByBundleDir, estimatedSize: 4096),
            RemovalTarget(url: dropDir, estimatedSize: 4096),
        ],
        mode: .trash,
        allowElevation: false
    )

    try E2ERunner.expect(!report.isFullSuccess, "Removing protected caches must be blocked")
    try E2ERunner.expectEqual(report.succeededURLs, [expectedDropURL])
    try E2ERunner.expect(RemovalEngine.entryExists(keepByPathDir), "protectedPaths cache must remain untouched")
    try E2ERunner.expect(RemovalEngine.entryExists(keepByBundleDir), "protectedBundleIDs cache must remain untouched")
}

runner.register(
    id: "f6-t2-toctou-parent-swap",
    tier: 2,
    feature: "F-6",
    name: "RemovalEngine blocks junk cleanup if scanned cache parent directory is swapped for symlink"
) {
    let sandbox = try E2ESandbox(prefix: "f6-t2-toctou")
    defer { sandbox.cleanup() }

    let parentA = try sandbox.createDirectory("Library/Caches/ParentA")
    _ = try sandbox.createExactSizeFile("Library/Caches/ParentA/item.cache", byteCount: 2048)
    let safeDir = try sandbox.createDirectory("Documents/TargetDir")
    let decoyItem = try sandbox.createExactSizeFile("Documents/TargetDir/item.cache", byteCount: 2048)
    let docParentDecoy = try sandbox.createExactSizeFile("Documents/ParentA/item.cache", byteCount: 2048)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox.rootURL)
    let categories = try await scanner.scan()
    let targetEntry = try E2ERunner.expectNotNil(
        categories.flatMap(\.entries).first(where: { $0.url.path.contains("ParentA") }),
        "Expected ParentA cache entry"
    )

    // Swap ParentA (or its target child parent) before deletion.
    let scannedURL = targetEntry.url
    let expectedParent = targetEntry.expectedCanonicalParent
    let swapParentDir = scannedURL.deletingLastPathComponent()
    if swapParentDir.standardizedFileURL == parentA.standardizedFileURL {
        try FileManager.default.removeItem(at: parentA)
        try FileManager.default.createSymbolicLink(at: parentA, withDestinationURL: safeDir)
    } else {
        // ParentA itself was scanned as the cache dir; swap Library/Caches parent for Documents
        let cachesDir = sandbox.url("Library/Caches")
        try FileManager.default.removeItem(at: cachesDir)
        try FileManager.default.createSymbolicLink(at: cachesDir, withDestinationURL: sandbox.url("Documents"))
    }
    try E2ERunner.expect(RemovalEngine.entryExists(scannedURL), "Swapped target URL must resolve on disk so TOCTOU check is exercised")

    let engine = RemovalEngine(
        safetyGuard: sg,
        localTrashHandler: { _ in
            throw E2EAssertionFailure("localTrashHandler must not be invoked on TOCTOU mismatch")
        }
    )
    let report = engine.remove(
        targets: [RemovalTarget(url: scannedURL, estimatedSize: Int64(targetEntry.bytes), expectedCanonicalParent: expectedParent)],
        mode: .permanent,
        allowElevation: false
    )

    try E2ERunner.expect(!report.isFullSuccess)
    try E2ERunner.expect(report.succeededURLs.isEmpty)
    try E2ERunner.expectContains(report.failures.first?.reason ?? "", "TOCTOU")
    try E2ERunner.expect(RemovalEngine.entryExists(decoyItem), "Target file after symlink swap must remain intact")
    try E2ERunner.expect(RemovalEngine.entryExists(docParentDecoy), "Documents/ParentA decoy after symlink swap must remain intact")
}

runner.register(
    id: "f6-t2-dataless-fifo-and-dotdot",
    tier: 2,
    feature: "F-6",
    name: "JunkCacheScanner skips FIFOs without blocking, handles empty dirs, and rejects .. cache subpaths"
) {
    let sandbox = try E2ESandbox(prefix: "f6-t2-fifo")
    defer { sandbox.cleanup() }

    _ = try sandbox.createDirectory("Library/Caches/com.acme.FifoApp")
    _ = try sandbox.createFIFO(atRelativePath: "Library/Caches/com.acme.FifoApp/pipe.fifo")
    _ = try sandbox.createDirectory("Library/Caches/com.acme.App/Sub")
    _ = try sandbox.createDirectory("Library/Logs")

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    try E2ERunner.expect(sg.validateCacheSubpath(sandbox.url("Library/Caches/com.acme.App")).isAllowed, "Valid cache subpath must pass")
    let dotDotURL = URL(fileURLWithPath: sandbox.rootURL.path + "/Library/Caches/com.acme.App/Sub/..")
    try E2ERunner.expect(dotDotURL.path.contains("/.."), "Test URL must preserve .. component")
    try E2ERunner.expect(!sg.validateCacheSubpath(dotDotURL).isAllowed, "Dotdot cache subpath must be blocked")

    let start = Date()
    let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox.rootURL)
    let categories = try await scanner.scan()
    let elapsed = Date().timeIntervalSince(start)

    try E2ERunner.expect(elapsed < 1.0, "JunkCacheScanner blocked or ran slow on FIFO (\(elapsed)s)")
    let logsCount = categories.first(where: { $0.category == .logs })?.entries.count ?? 0
    try E2ERunner.expectEqual(logsCount, 0, "Empty Library/Logs should yield 0 log entries")
}

runner.register(
    id: "f6-t2-running-app-and-no-fda-graceful",
    tier: 2,
    feature: "F-6",
    name: "JunkCacheScanner survives unreadable 0o000 cache directory and empty running-app list gracefully"
) {
    let sandbox = try E2ESandbox(prefix: "f6-t2-locked")
    defer { sandbox.cleanup() }

    // Create parent and child files FIRST, then chmod 0o000 at the end (per SandboxBuilder caveat).
    let lockedDir = try sandbox.createDirectory("Library/Caches/com.acme.Locked")
    let lockedFile = try sandbox.createExactSizeFile("Library/Caches/com.acme.Locked/secret.bin", byteCount: 1024)
    _ = try sandbox.createExactSizeFile("Library/Caches/com.acme.Open/ok.bin", byteCount: 2048)

    try E2ERunner.expectEqual(Darwin.chmod(lockedFile.path, 0o000), 0)
    try E2ERunner.expectEqual(Darwin.chmod(lockedDir.path, 0o000), 0)
    defer {
        _ = Darwin.chmod(lockedDir.path, 0o700)
        _ = Darwin.chmod(lockedFile.path, 0o600)
    }

    let terminated = await RemovalEngine.terminateRunningApps(bundleIDs: [], bundleURLs: [])
    try E2ERunner.expect(terminated.isEmpty, "Empty bundleIDs terminateRunningApps should return empty")

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox.rootURL)
    let categories = try await scanner.scan()
    let allEntries = categories.flatMap(\.entries)
    try E2ERunner.expect(allEntries.contains(where: { $0.url.path.contains("com.acme.Open") }), "Accessible cache must still scan cleanly")
}

// MARK: - Feature F7: Large Files Finder (6 Tier 1 + 6 Tier 2 = 12 Cases)

runner.register(
    id: "f7-t1-threshold-50mb-100mb-500mb",
    tier: 1,
    feature: "F-7",
    name: "LargeAndDuplicateScanner filters large files accurately at 50 MB, 100 MB, and 500 MB thresholds"
) {
    let sandbox = try E2ESandbox(prefix: "f7-t1-thresh")
    defer { sandbox.cleanup() }

    _ = try sandbox.createExactSizeFile("Scan/a_40mb.bin", byteCount: 40_000_000, sparse: true)
    _ = try sandbox.createExactSizeFile("Scan/b_60mb.bin", byteCount: 60_000_000, sparse: true)
    _ = try sandbox.createExactSizeFile("Scan/c_150mb.dmg", byteCount: 150_000_000, sparse: true)
    _ = try sandbox.createExactSizeFile("Scan/d_600mb.iso", byteCount: 600_000_000, sparse: true)

    let scanRoot = sandbox.url("Scan")
    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)

    let over50 = try await scanner.scanLargeFiles(under: scanRoot, minBytes: 50_000_000)
    try E2ERunner.expectEqual(over50.map(\.name), ["d_600mb.iso", "c_150mb.dmg", "b_60mb.bin"])

    let over100 = try await scanner.scanLargeFiles(under: scanRoot, minBytes: 100_000_000)
    try E2ERunner.expectEqual(over100.map(\.name), ["d_600mb.iso", "c_150mb.dmg"])

    let over500 = try await scanner.scanLargeFiles(under: scanRoot, minBytes: 500_000_000)
    try E2ERunner.expectEqual(over500.map(\.name), ["d_600mb.iso"])
}

runner.register(
    id: "f7-t1-category-classification",
    tier: 1,
    feature: "F-7",
    name: "LargeAndDuplicateScanner classifies large files into video, archive/image, installer, document, and other"
) {
    let sandbox = try E2ESandbox(prefix: "f7-t1-cats")
    defer { sandbox.cleanup() }

    _ = try sandbox.createExactSizeFile("Scan/clip.mp4", byteCount: 60_000_000, sparse: true)
    _ = try sandbox.createExactSizeFile("Scan/archive.dmg", byteCount: 60_000_000, sparse: true)
    _ = try sandbox.createExactSizeFile("Scan/setup.pkg", byteCount: 60_000_000, sparse: true)
    _ = try sandbox.createExactSizeFile("Scan/report.pdf", byteCount: 60_000_000, sparse: true)
    _ = try sandbox.createExactSizeFile("Scan/blob.dat", byteCount: 60_000_000, sparse: true)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let items = try await scanner.scanLargeFiles(under: sandbox.url("Scan"), minBytes: 50_000_000)

    try E2ERunner.expectEqual(items.count, 5)
    let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.category) })
    let cats = Set(byName.values)
    try E2ERunner.expectEqual(cats.count, 5, "Expected 5 distinct large-file categories across mp4/dmg/pkg/pdf/dat, got \(cats)")
    try E2ERunner.expectEqual(byName["clip.mp4"], .video)
    try E2ERunner.expectEqual(byName["archive.dmg"], .diskImageAndArchive)
    try E2ERunner.expectEqual(byName["setup.pkg"], .installer)
    try E2ERunner.expectEqual(byName["report.pdf"], .document)
    try E2ERunner.expectEqual(byName["blob.dat"], .other)
    try E2ERunner.expectNotEqual(byName["archive.dmg"], byName["blob.dat"])
}

runner.register(
    id: "f7-t1-age-filter-days",
    tier: 1,
    feature: "F-7",
    name: "LargeAndDuplicateScanner filters stale large files by olderThanDays accurately"
) {
    let sandbox = try E2ESandbox(prefix: "f7-t1-age")
    defer { sandbox.cleanup() }

    let oldFile = try sandbox.createExactSizeFile("Scan/old.dmg", byteCount: 60_000_000, sparse: true)
    let freshFile = try sandbox.createExactSizeFile("Scan/fresh.dmg", byteCount: 60_000_000, sparse: true)

    let now = Date()
    try setModificationDate(now.addingTimeInterval(-200 * 86_400), for: oldFile)
    try setModificationDate(now.addingTimeInterval(-2 * 86_400), for: freshFile)

    let scanRoot = sandbox.url("Scan")
    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)

    let allLarge = try await scanner.scanLargeFiles(under: scanRoot, minBytes: 50_000_000, olderThanDays: nil)
    try E2ERunner.expectEqual(allLarge.count, 2)

    let stale90 = try await scanner.scanLargeFiles(under: scanRoot, minBytes: 50_000_000, olderThanDays: 90)
    try E2ERunner.expectEqual(stale90.map(\.name), ["old.dmg"])

    let stale365 = try await scanner.scanLargeFiles(under: scanRoot, minBytes: 50_000_000, olderThanDays: 365)
    try E2ERunner.expect(stale365.isEmpty, "200-day file must not match > 365 days")
}

runner.register(
    id: "f7-t1-canonical-parent-and-sort",
    tier: 1,
    feature: "F-7",
    name: "LargeFileItem captures expectedCanonicalParent and sorts descending by bytes"
) {
    let sandbox = try E2ESandbox(prefix: "f7-t1-sort")
    defer { sandbox.cleanup() }

    _ = try sandbox.createExactSizeFile("Work/SubA/z.bin", byteCount: 80_000_000, sparse: true)
    _ = try sandbox.createExactSizeFile("Work/SubB/a.bin", byteCount: 60_000_000, sparse: true)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let items = try await scanner.scanLargeFiles(under: sandbox.url("Work"), minBytes: 50_000_000)

    try E2ERunner.expectEqual(items.map(\.name), ["z.bin", "a.bin"])
    for item in items {
        try E2ERunner.expectEqual(
            item.expectedCanonicalParent,
            SandboxBuilder.canonicalParentPath(for: item.url),
            "LargeFileItem expectedCanonicalParent mismatch"
        )
    }
}

runner.register(
    id: "f7-t1-safe-trash-and-history",
    tier: 1,
    feature: "F-7",
    name: "Large file deletion routes through RemovalEngine .trash and records CleanupRecord"
) {
    let sandbox = try E2ESandbox(prefix: "f7-t1-trash")
    defer { sandbox.cleanup() }

    _ = try sandbox.createExactSizeFile("Downloads/big.iso", byteCount: 60_000_000, sparse: true)
    let mockTrash = try sandbox.createDirectory("MockTrash")
    let historyStore = CleanupHistoryStore(fileURL: sandbox.url("State/history.json"))

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let items = try await scanner.scanLargeFiles(under: sandbox.url("Downloads"), minBytes: 50_000_000)
    let item = try E2ERunner.expectNotNil(items.first)

    let engine = RemovalEngine(
        safetyGuard: sg,
        historyStore: historyStore,
        localTrashHandler: makeMockTrashHandler(trashDir: mockTrash)
    )
    let report = engine.remove(
        targets: [RemovalTarget(url: item.url, estimatedSize: Int64(item.bytes), expectedCanonicalParent: item.expectedCanonicalParent)],
        mode: .trash,
        actionTitle: "Large File Cleanup",
        allowElevation: false
    )

    try E2ERunner.expect(report.isFullSuccess, "Large file removal failed: \(report.failures)")
    try E2ERunner.expect(!RemovalEngine.entryExists(item.url), "big.iso should be moved to MockTrash")
    let latest = try E2ERunner.expectNotNil(historyStore.load().first)
    try E2ERunner.expectEqual(latest.actionTitle, "Large File Cleanup")
    try E2ERunner.expectEqual(latest.freedBytes, Int64(item.bytes))
}

runner.register(
    id: "f7-t1-cancellation-support",
    tier: 1,
    feature: "F-7",
    name: "Large file scan supports cooperative Swift Task cancellation cleanly"
) {
    let sandbox = try E2ESandbox(prefix: "f7-t1-cancel")
    defer { sandbox.cleanup() }

    _ = try sandbox.createExactSizeFile("SmallTree/Dir0/f_0.dat", byteCount: 1024)
    _ = try sandbox.createExactSizeFile("SmallTree/big.dat", byteCount: 60_000_000, sparse: true)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let smallTreeURL = sandbox.url("SmallTree")

    // (A) Pre-cancelled entry directly into scanLargeFiles (NO pre-call Task.checkCancellation())
    let preGate = AsyncGate()
    let preState = ResourceCancelProbeState()
    let preTask = Task<Void, Error> {
        await preGate.wait()
        preState.markInvoked()
        _ = try await scanner.scanLargeFiles(under: smallTreeURL, minBytes: 50_000_000)
    }
    preTask.cancel()
    preGate.open()

    let preErr = try await E2ERunner.expectThrowsAsync("Pre-cancelled scanLargeFiles must throw CancellationError") {
        _ = try await preTask.value
    }
    try E2ERunner.expect(preErr is CancellationError, "Expected CancellationError on pre-cancelled scan, got \(preErr)")
    try E2ERunner.expect(preState.invoked, "scanLargeFiles must be invoked before CancellationError")

    // (B) Mid-scan cooperative cancellation triggered inside onProgress on a 251-file tree
    for dirIdx in 0..<25 {
        for fileIdx in 0..<10 {
            _ = try sandbox.createExactSizeFile("BulkTree/Dir_\(dirIdx)/file_\(fileIdx).dat", byteCount: 1024)
        }
    }
    _ = try sandbox.createExactSizeFile("BulkTree/Dir_0/big.dat", byteCount: 60_000_000, sparse: true)

    let midGate = AsyncGate()
    let midState = ResourceCancelProbeState()
    let midScanner = LargeAndDuplicateScanner(safetyGuard: sg, progressThrottleInterval: 0.01)
    let bulkTreeURL = sandbox.url("BulkTree")
    let midTask = Task<Void, Error> {
        await midGate.wait()
        midState.markInvoked()
        _ = try await midScanner.scanLargeFiles(under: bulkTreeURL, minBytes: 50_000_000) { progress in
            midState.recordProgressAndCancel(progress)
        }
    }
    midState.setTaskToCancel(midTask)
    midGate.open()

    let midErr = try await E2ERunner.expectThrowsAsync("Mid-scan cancelled scanLargeFiles must throw CancellationError") {
        _ = try await midTask.value
    }
    try E2ERunner.expect(midErr is CancellationError, "Expected CancellationError on mid-scan cancel, got \(midErr)")
    try E2ERunner.expect(midState.invoked, "Mid-scan scanLargeFiles must be invoked")
    let events = midState.progressEvents
    try E2ERunner.expect(!events.isEmpty, "onProgress must fire at least once before mid-scan cancellation")
    if let last = events.last {
        try E2ERunner.expect(last.scannedFiles < 251, "Expected scan to abort mid-tree (< 251 files), got \(last.scannedFiles)")
    }
}

runner.register(
    id: "f7-t2-skip-symlinks-and-hardlinks",
    tier: 2,
    feature: "F-7",
    name: "LargeAndDuplicateScanner skips symlinks and avoids double-counting hardlinks"
) {
    let sandbox = try E2ESandbox(prefix: "f7-t2-links")
    defer { sandbox.cleanup() }

    let externalBig = try sandbox.createExactSizeFile("External/huge_120mb.bin", byteCount: 120_000_000, sparse: true)
    let realBig = try sandbox.createExactSizeFile("ScanRoot/real_120mb.bin", byteCount: 120_000_000, sparse: true)
    _ = try sandbox.createSymlink(atRelativePath: "ScanRoot/link.bin", targetURL: externalBig)
    _ = try sandbox.createHardlink(atRelativePath: "ScanRoot/hard_120mb.bin", to: realBig)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let items = try await scanner.scanLargeFiles(under: sandbox.url("ScanRoot"), minBytes: 50_000_000)

    let names = Set(items.map(\.name))
    try E2ERunner.expect(!names.contains("link.bin"), "Symlink to large file must never be returned")
    try E2ERunner.expectEqual(items.count, 1, "Hardlink sharing inode must be deduplicated so only 1 entry is counted")
}

runner.register(
    id: "f7-t2-exclude-protected-and-photos",
    tier: 2,
    feature: "F-7",
    name: "LargeAndDuplicateScanner excludes .photoslibrary, .ssh, and user protectedPaths"
) {
    let sandbox = try E2ESandbox(prefix: "f7-t2-prot")
    defer { sandbox.cleanup() }

    _ = try sandbox.createExactSizeFile("Scan/Pictures/Test.photoslibrary/orig.mov", byteCount: 60_000_000, sparse: true)
    let vaultDir = try sandbox.createDirectory("Scan/Vault")
    _ = try sandbox.createExactSizeFile("Scan/Vault/secret.bin", byteCount: 60_000_000, sparse: true)
    _ = try sandbox.createExactSizeFile("Scan/.ssh/huge.key", byteCount: 60_000_000, sparse: true)
    _ = try sandbox.createExactSizeFile("Scan/Work/deletable.bin", byteCount: 60_000_000, sparse: true)

    let sg = SafetyGuard(homeDirectory: sandbox.url("Scan"), selfBundlePath: nil, protectedPaths: [vaultDir.path])
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let items = try await scanner.scanLargeFiles(under: sandbox.url("Scan"), minBytes: 50_000_000)

    try E2ERunner.expectEqual(items.map(\.name), ["deletable.bin"])
}

runner.register(
    id: "f7-t2-exact-threshold-boundary",
    tier: 2,
    feature: "F-7",
    name: "Large file scan respects inclusive >= boundary at threshold-1, threshold, and threshold+1"
) {
    let sandbox = try E2ESandbox(prefix: "f7-t2-bva")
    defer { sandbox.cleanup() }

    let threshold: Int64 = 50_000_000
    _ = try sandbox.createExactSizeFile("Scan/below.bin", byteCount: threshold - 1, sparse: true)
    _ = try sandbox.createExactSizeFile("Scan/exact.bin", byteCount: threshold, sparse: true)
    _ = try sandbox.createExactSizeFile("Scan/above.bin", byteCount: threshold + 1, sparse: true)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let items = try await scanner.scanLargeFiles(under: sandbox.url("Scan"), minBytes: UInt64(threshold))

    let names = Set(items.map(\.name))
    try E2ERunner.expect(!names.contains("below.bin"), "threshold - 1 must be excluded")
    try E2ERunner.expect(names.contains("exact.bin"), "exact threshold must be included")
    try E2ERunner.expect(names.contains("above.bin"), "threshold + 1 must be included")
}

runner.register(
    id: "f7-t2-fifo-special-and-zero-byte",
    tier: 2,
    feature: "F-7",
    name: "Large file scan ignores FIFOs, 0-byte files, and directories summing > threshold"
) {
    let sandbox = try E2ESandbox(prefix: "f7-t2-fifo")
    defer { sandbox.cleanup() }

    _ = try sandbox.createFIFO(atRelativePath: "Scan/pipe.fifo")
    _ = try sandbox.createExactSizeFile("Scan/empty.bin", byteCount: 0)
    for i in 0..<10 {
        _ = try sandbox.createExactSizeFile("Scan/SubDir/part_\(i).bin", byteCount: 6_000_000, sparse: true)
    }
    _ = try sandbox.createExactSizeFile("Scan/valid_55mb.bin", byteCount: 55_000_000, sparse: true)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)

    let start = Date()
    let items = try await scanner.scanLargeFiles(under: sandbox.url("Scan"), minBytes: 50_000_000)
    let elapsed = Date().timeIntervalSince(start)

    try E2ERunner.expect(elapsed < 1.0, "Large file scan blocked on FIFO (\(elapsed)s)")
    try E2ERunner.expectEqual(items.map(\.name), ["valid_55mb.bin"], "Only valid >= 50 MB regular file should be returned; FIFOs, 0-byte files, and SubDir sum must be ignored")
}

runner.register(
    id: "f7-t2-unreadable-subdir-and-bidi-name",
    tier: 2,
    feature: "F-7",
    name: "Large file scan survives 0o000 unreadable directory and SafeFileReader sanitizes bidi filenames"
) {
    let sandbox = try E2ESandbox(prefix: "f7-t2-bidi")
    defer { sandbox.cleanup() }

    // Create child first, then chmod 0o000 on LockedDir.
    let lockedDir = try sandbox.createDirectory("Scan/LockedDir")
    _ = try sandbox.createExactSizeFile("Scan/LockedDir/hidden_60mb.bin", byteCount: 60_000_000, sparse: true)
    let bidiName = "evil\u{202E}txt.bin"
    _ = try sandbox.createExactSizeFile("Scan/\(bidiName)", byteCount: 60_000_000, sparse: true)

    try E2ERunner.expectEqual(Darwin.chmod(lockedDir.path, 0o000), 0)
    defer { _ = Darwin.chmod(lockedDir.path, 0o700) }

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let items = try await scanner.scanLargeFiles(under: sandbox.url("Scan"), minBytes: 50_000_000)

    let bidiItem = try E2ERunner.expectNotNil(items.first(where: { $0.name == bidiName }))
    let sanitized = SafeFileReader.sanitizeForDisplay(bidiItem.name)
    try E2ERunner.expectContains(sanitized, "\\u{202E}", "Bidi override char must be escaped in display name")
}

runner.register(
    id: "f7-t2-toctou-and-uchg-large-file",
    tier: 2,
    feature: "F-7",
    name: "Large file cleanup unlocks uchg in .permanent mode and blocks TOCTOU parent swap"
) {
    let sandbox = try E2ESandbox(prefix: "f7-t2-toctou")
    defer { sandbox.cleanup() }

    let locked = try sandbox.createExactSizeFile("Work/locked.bin", byteCount: 60_000_000, sparse: true)
    try sandbox.setUserImmutable(locked, locked: true)

    let swapParent = try sandbox.createDirectory("Work/ParentSwap")
    _ = try sandbox.createExactSizeFile("Work/ParentSwap/big.bin", byteCount: 60_000_000, sparse: true)
    let safeTargetDir = try sandbox.createDirectory("SafeDir")
    let decoy = try sandbox.createExactSizeFile("SafeDir/big.bin", byteCount: 60_000_000, sparse: true)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let items = try await scanner.scanLargeFiles(under: sandbox.url("Work"), minBytes: 50_000_000)

    let lockedItem = try E2ERunner.expectNotNil(items.first(where: { $0.name == "locked.bin" }))
    let swapItem = try E2ERunner.expectNotNil(items.first(where: { $0.name == "big.bin" }))

    try FileManager.default.removeItem(at: swapParent)
    try FileManager.default.createSymbolicLink(at: swapParent, withDestinationURL: safeTargetDir)

    let engine = RemovalEngine(safetyGuard: sg)
    let okReport = engine.remove(
        targets: [RemovalTarget(url: lockedItem.url, estimatedSize: Int64(lockedItem.bytes), expectedCanonicalParent: lockedItem.expectedCanonicalParent)],
        mode: .permanent,
        allowElevation: false
    )
    try E2ERunner.expect(okReport.isFullSuccess, "Permanent removal of uchg large file should succeed")
    try E2ERunner.expect(!RemovalEngine.entryExists(locked))

    let badReport = engine.remove(
        targets: [RemovalTarget(url: swapItem.url, estimatedSize: Int64(swapItem.bytes), expectedCanonicalParent: swapItem.expectedCanonicalParent)],
        mode: .permanent,
        allowElevation: false
    )
    try E2ERunner.expect(!badReport.isFullSuccess)
    try E2ERunner.expectContains(badReport.failures.first?.reason ?? "", "TOCTOU")
    try E2ERunner.expect(RemovalEngine.entryExists(decoy))
}

// MARK: - Feature F8: Duplicate File Finder (6 Tier 1 + 6 Tier 2 = 12 Cases)

runner.register(
    id: "f8-t1-three-stage-exact-match",
    tier: 1,
    feature: "F-8",
    name: "Duplicate finder detects identical 3-copy group and computes exact reclaimableBytes"
) {
    let sandbox = try E2ESandbox(prefix: "f8-t1-exact")
    defer { sandbox.cleanup() }

    let dupData = makeDistinctPayload(byteCount: 131_072, fillByte: 0x5A, mutateOffset: 4096, mutateByte: 0x99)
    let uniqueData = makeDistinctPayload(byteCount: 131_072, fillByte: 0x5A, mutateOffset: 4096, mutateByte: 0x77)

    _ = try sandbox.createFile("Scan/A/doc.dat", data: dupData)
    _ = try sandbox.createFile("Scan/B/doc_copy.dat", data: dupData)
    _ = try sandbox.createFile("Scan/C/doc_3.dat", data: dupData)
    _ = try sandbox.createFile("Scan/D/unique.dat", data: uniqueData)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let groups = try await scanner.scanDuplicates(under: sandbox.url("Scan"), minBytes: 1)

    try E2ERunner.expectEqual(groups.count, 1)
    let group = try E2ERunner.expectNotNil(groups.first)
    try E2ERunner.expectEqual(group.files.count, 3)
    try E2ERunner.expectEqual(group.fileSize, UInt64(131_072))
    try E2ERunner.expectEqual(group.reclaimableBytes, UInt64(262_144))
    try E2ERunner.expect(!group.files.contains(where: { $0.name == "unique.dat" }))
}

runner.register(
    id: "f8-t1-partial-hash-discriminates-middle-or-ends",
    tier: 1,
    feature: "F-8",
    name: "Full CryptoKit SHA256 catches middle-byte differences even when size and head/tail match"
) {
    let sandbox = try E2ESandbox(prefix: "f8-t1-mid")
    defer { sandbox.cleanup() }

    let data1 = makeDistinctPayload(byteCount: 262_144, fillByte: 0x33, mutateOffset: 131_072, mutateByte: 0xA1)
    let data2 = makeDistinctPayload(byteCount: 262_144, fillByte: 0x33, mutateOffset: 131_072, mutateByte: 0xB2)
    let data3 = makeDistinctPayload(byteCount: 262_144, fillByte: 0x33, mutateOffset: 0, mutateByte: 0xC3)
    let matchPayload = makeDistinctPayload(byteCount: 262_144, fillByte: 0x44, mutateOffset: 131_072, mutateByte: 0xD4)

    _ = try sandbox.createFile("Scan/f1.bin", data: data1)
    _ = try sandbox.createFile("Scan/f2.bin", data: data2)
    _ = try sandbox.createFile("Scan/f3.bin", data: data3)
    _ = try sandbox.createFile("Scan/match_a.bin", data: matchPayload)
    _ = try sandbox.createFile("Scan/match_b.bin", data: matchPayload)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let groups = try await scanner.scanDuplicates(under: sandbox.url("Scan"), minBytes: 1)

    try E2ERunner.expectEqual(groups.count, 1, "Expected only the identical pair to form a duplicate group")
    try E2ERunner.expectEqual(Set(groups[0].files.map(\.name)), Set(["match_a.bin", "match_b.bin"]), "Files differing in middle or head must never form a duplicate group")
}

runner.register(
    id: "f8-t1-multiple-groups-sorted",
    tier: 1,
    feature: "F-8",
    name: "Duplicate finder separates distinct groups and sorts by reclaimableBytes descending"
) {
    let sandbox = try E2ESandbox(prefix: "f8-t1-multi")
    defer { sandbox.cleanup() }

    let g1Payload = makeDistinctPayload(byteCount: 204_800, fillByte: 0x1A)
    let g2Payload = makeDistinctPayload(byteCount: 102_400, fillByte: 0x2B)

    _ = try sandbox.createFile("Scan/G1/a.bin", data: g1Payload)
    _ = try sandbox.createFile("Scan/G1/b.bin", data: g1Payload)
    for i in 0..<4 {
        _ = try sandbox.createFile("Scan/G2/c_\(i).bin", data: g2Payload)
    }

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let groups = try await scanner.scanDuplicates(under: sandbox.url("Scan"), minBytes: 1)

    try E2ERunner.expectEqual(groups.count, 2)
    try E2ERunner.expectEqual(groups[0].reclaimableBytes, UInt64(307_200))
    try E2ERunner.expectEqual(groups[1].reclaimableBytes, UInt64(204_800))
}

runner.register(
    id: "f8-t1-smart-auto-select-keeps-one",
    tier: 1,
    feature: "F-8",
    name: "Smart duplicate auto-selection always retains at least 1 original copy"
) {
    let sandbox = try E2ESandbox(prefix: "f8-t1-smart")
    defer { sandbox.cleanup() }

    let payload = makeDistinctPayload(byteCount: 32_768, fillByte: 0x4C)
    let orig = try sandbox.createFile("Scan/Documents/original.pdf", data: payload)
    let dlCopy = try sandbox.createFile("Scan/Downloads/original (1).pdf", data: payload)

    let now = Date()
    try setModificationDate(now.addingTimeInterval(-3600), for: orig)
    try setModificationDate(now, for: dlCopy)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let scanned = try await scanner.scanDuplicates(under: sandbox.url("Scan"), minBytes: 1)
    let groups = scanner.applySmartSelection(to: scanned)

    let group = try E2ERunner.expectNotNil(groups.first)
    let selected = group.files.filter(\.isSelected)
    let retained = group.files.filter { !$0.isSelected }
    try E2ERunner.expectEqual(selected.count, group.files.count - 1)
    try E2ERunner.expectEqual(retained.count, 1)
    try E2ERunner.expectEqual(retained.first?.url.lastPathComponent, "original.pdf")
}

runner.register(
    id: "f8-t1-remove-selected-duplicates-history",
    tier: 1,
    feature: "F-8",
    name: "Removing selected duplicate copies preserves retained original and writes CleanupRecord"
) {
    let sandbox = try E2ESandbox(prefix: "f8-t1-remove")
    defer { sandbox.cleanup() }

    let payload = makeDistinctPayload(byteCount: 65_536, fillByte: 0x6D)
    _ = try sandbox.createFile("Scan/Keep/orig.dat", data: payload)
    _ = try sandbox.createFile("Scan/Downloads/dup1.dat", data: payload)
    _ = try sandbox.createFile("Scan/Downloads/dup2.dat", data: payload)

    let mockTrash = try sandbox.createDirectory("MockTrash")
    let historyStore = CleanupHistoryStore(fileURL: sandbox.url("State/history.json"))

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let groups = scanner.applySmartSelection(to: try await scanner.scanDuplicates(under: sandbox.url("Scan"), minBytes: 1))
    let group = try E2ERunner.expectNotNil(groups.first)

    let selectedTargets = group.files.filter(\.isSelected).map {
        RemovalTarget(url: $0.url, estimatedSize: Int64(group.fileSize), expectedCanonicalParent: $0.expectedCanonicalParent)
    }
    let retainedEntry = try E2ERunner.expectNotNil(group.files.first(where: { !$0.isSelected }))
    let retainedHashBefore = try sha256Hex(of: retainedEntry.url)

    let engine = RemovalEngine(
        safetyGuard: sg,
        historyStore: historyStore,
        localTrashHandler: makeMockTrashHandler(trashDir: mockTrash)
    )
    let report = engine.remove(targets: selectedTargets, mode: .trash, actionTitle: "Duplicate Cleanup", allowElevation: false)

    try E2ERunner.expect(report.isFullSuccess, "Duplicate cleanup failed: \(report.failures)")
    try E2ERunner.expect(RemovalEngine.entryExists(retainedEntry.url), "Retained duplicate must remain on disk")
    try E2ERunner.expectEqual(try sha256Hex(of: retainedEntry.url), retainedHashBefore)

    let record = try E2ERunner.expectNotNil(historyStore.load().first)
    try E2ERunner.expectEqual(record.itemCount, 2)
    try E2ERunner.expectEqual(record.freedBytes, 131_072)
}

runner.register(
    id: "f8-t1-tiny-file-below-partial-chunk",
    tier: 1,
    feature: "F-8",
    name: "Duplicate finder handles tiny 37-byte files smaller than partial-hash chunk window"
) {
    let sandbox = try E2ESandbox(prefix: "f8-t1-tiny37")
    defer { sandbox.cleanup() }

    let match37 = Data("0123456789abcdefghijklmnopqrstuvwxyz!".utf8)
    let diff37 = Data("0123456789abcdefghijklmnopqrstuvwxyz?".utf8)
    try E2ERunner.expectEqual(match37.count, 37)

    _ = try sandbox.createFile("Scan/a.txt", data: match37)
    _ = try sandbox.createFile("Scan/b.txt", data: match37)
    _ = try sandbox.createFile("Scan/c.txt", data: diff37)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let groups = try await scanner.scanDuplicates(under: sandbox.url("Scan"), minBytes: 1)

    try E2ERunner.expectEqual(groups.count, 1)
    let group = try E2ERunner.expectNotNil(groups.first)
    try E2ERunner.expectEqual(group.fileSize, UInt64(37))
    try E2ERunner.expectEqual(group.reclaimableBytes, UInt64(37))
    try E2ERunner.expectEqual(Set(group.files.map(\.name)), Set(["a.txt", "b.txt"]))
}

runner.register(
    id: "f8-t2-one-byte-and-partial-hash-collision",
    tier: 2,
    feature: "F-8",
    name: "Duplicate finder matches 1-byte files and resolves partial-hash collisions via full SHA256"
) {
    let sandbox = try E2ESandbox(prefix: "f8-t2-1byte-coll")
    defer { sandbox.cleanup() }

    // 1-byte duplicates (real sparse: false) + distinct 1-byte file
    _ = try sandbox.createExactSizeFile("Scan/one_a.bin", byteCount: 1, fillByte: 0x41, sparse: false)
    _ = try sandbox.createExactSizeFile("Scan/one_b.bin", byteCount: 1, fillByte: 0x41, sparse: false)
    _ = try sandbox.createExactSizeFile("Scan/one_diff.bin", byteCount: 1, fillByte: 0x42, sparse: false)

    // Partial-hash-collision pair: 64 KiB files sharing identical first 16 KiB and last 16 KiB, differing at byte 32_768
    let collA = makeDistinctPayload(byteCount: 65_536, fillByte: 0x55, mutateOffset: 32_768, mutateByte: 0x10)
    let collB = makeDistinctPayload(byteCount: 65_536, fillByte: 0x55, mutateOffset: 32_768, mutateByte: 0x20)
    _ = try sandbox.createFile("Scan/coll_a.bin", data: collA)
    _ = try sandbox.createFile("Scan/coll_b.bin", data: collB)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let groups = try await scanner.scanDuplicates(under: sandbox.url("Scan"), minBytes: 1)

    try E2ERunner.expectEqual(groups.count, 1, "Only the 1-byte identical pair should form a DuplicateGroup; partial-hash collision must be rejected")
    let oneByteGroup = try E2ERunner.expectNotNil(groups.first)
    try E2ERunner.expectEqual(oneByteGroup.fileSize, UInt64(1))
    try E2ERunner.expectEqual(oneByteGroup.reclaimableBytes, UInt64(1))
    try E2ERunner.expectEqual(Set(oneByteGroup.files.map(\.name)), Set(["one_a.bin", "one_b.bin"]))
}

runner.register(
    id: "f8-t2-hardlink-not-duplicate",
    tier: 2,
    feature: "F-8",
    name: "Duplicate finder deduplicates hardlinks sharing (st_dev, st_ino)"
) {
    let sandbox = try E2ESandbox(prefix: "f8-t2-hardlink")
    defer { sandbox.cleanup() }

    let payload = makeDistinctPayload(byteCount: 32_768, fillByte: 0x7E)
    let a = try sandbox.createFile("Case1/a.bin", data: payload)
    _ = try sandbox.createHardlink(atRelativePath: "Case1/b_hardlink.bin", to: a)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)

    let case1Groups = try await scanner.scanDuplicates(under: sandbox.url("Case1"), minBytes: 1)
    try E2ERunner.expect(case1Groups.isEmpty, "Hardlinks of same inode occupy zero extra space and must not be flagged")

    let x = try sandbox.createFile("Case2/x.bin", data: payload)
    _ = try sandbox.createHardlink(atRelativePath: "Case2/x_hard.bin", to: x)
    _ = try sandbox.createFile("Case2/y_copy.bin", data: payload)

    let case2Groups = try await scanner.scanDuplicates(under: sandbox.url("Case2"), minBytes: 1)
    try E2ERunner.expectEqual(case2Groups.count, 1)
    let g = try E2ERunner.expectNotNil(case2Groups.first)
    try E2ERunner.expectEqual(g.files.count, 2, "Duplicate group must deduplicate hardlink inode")
    try E2ERunner.expectEqual(g.reclaimableBytes, UInt64(32_768))
}

runner.register(
    id: "f8-t2-symlinks-and-zero-byte-ignored",
    tier: 2,
    feature: "F-8",
    name: "Duplicate finder ignores 0-byte files and symlinks pointing to existing files"
) {
    let sandbox = try E2ESandbox(prefix: "f8-t2-zero-sym")
    defer { sandbox.cleanup() }

    _ = try sandbox.createExactSizeFile("Scan/empty1.txt", byteCount: 0, sparse: false)
    _ = try sandbox.createExactSizeFile("Scan/empty2.txt", byteCount: 0, sparse: false)

    let real = try sandbox.createFile("Scan/real.bin", data: makeDistinctPayload(byteCount: 32_768, fillByte: 0x2A))
    _ = try sandbox.createSymlink(atRelativePath: "Scan/symlink.bin", targetURL: real)
    let dupPayload = makeDistinctPayload(byteCount: 16_384, fillByte: 0x1E)
    _ = try sandbox.createFile("Scan/dup_a.bin", data: dupPayload)
    _ = try sandbox.createFile("Scan/dup_b.bin", data: dupPayload)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let groups = try await scanner.scanDuplicates(under: sandbox.url("Scan"), minBytes: 0)

    try E2ERunner.expectEqual(groups.count, 1, "Expected only the identical regular pair to form a duplicate group")
    try E2ERunner.expectEqual(Set(groups[0].files.map(\.name)), Set(["dup_a.bin", "dup_b.bin"]), "0-byte files and symlinks must never yield duplicate groups")
}

runner.register(
    id: "f8-t2-unreadable-and-app-bundle-excluded",
    tier: 2,
    feature: "F-8",
    name: "Duplicate finder handles unreadable 0o000 files without crash and excludes .app internals & protectedPaths"
) {
    let sandbox = try E2ESandbox(prefix: "f8-t2-unreadable")
    defer { sandbox.cleanup() }

    let payload = makeDistinctPayload(byteCount: 32_768, fillByte: 0x3D)

    // Create unreadable 0o000 file (create first, chmod 0o000 last)
    let lockedFile = try sandbox.createFile("Scan/locked_000.dat", data: payload)
    try E2ERunner.expectEqual(Darwin.chmod(lockedFile.path, 0o000), 0)
    defer { _ = Darwin.chmod(lockedFile.path, 0o600) }

    // Protected .app bundle & protectedPath with identical bytes
    _ = try sandbox.createMockAppBundle(atRelativePath: "Scan/Applications/Mock.app", bundleID: "com.mock.app", name: "Mock")
    _ = try sandbox.createFile("Scan/Applications/Mock.app/Contents/Resources/icon.dat", data: payload)
    let vaultDir = try sandbox.createDirectory("Scan/Vault")
    _ = try sandbox.createFile("Scan/Vault/keep.dat", data: payload)

    // Genuine removable duplicates
    _ = try sandbox.createFile("Scan/Work/dup1.dat", data: payload)
    _ = try sandbox.createFile("Scan/Work/dup2.dat", data: payload)

    let sg = SafetyGuard(homeDirectory: sandbox.url("Scan"), selfBundlePath: nil, protectedPaths: [vaultDir.path])
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let groups = try await scanner.scanDuplicates(under: sandbox.url("Scan"), minBytes: 1)

    let allPaths = groups.flatMap(\.files).map { $0.url.path }
    try E2ERunner.expect(!allPaths.contains(where: { $0.contains("Mock.app") }), ".app bundle internals must be excluded")
    try E2ERunner.expect(!allPaths.contains(where: { $0.contains("Vault/keep.dat") }), "protectedPaths must be excluded")
    try E2ERunner.expect(!allPaths.contains(where: { $0.contains("locked_000.dat") }), "unreadable 0o000 file must be safely skipped")
    try E2ERunner.expectEqual(groups.count, 1)
    try E2ERunner.expectEqual(Set(groups[0].files.map(\.name)), Set(["dup1.dat", "dup2.dat"]))
}

runner.register(
    id: "f8-t2-fifo-and-min-size-boundary",
    tier: 2,
    feature: "F-8",
    name: "Duplicate finder never blocks on FIFOs and enforces inclusive minBytes boundary"
) {
    let sandbox = try E2ESandbox(prefix: "f8-t2-fifo-min")
    defer { sandbox.cleanup() }

    _ = try sandbox.createFIFO(atRelativePath: "Scan/p1.fifo")
    _ = try sandbox.createFIFO(atRelativePath: "Scan/p2.fifo")

    let smallData = makeDistinctPayload(byteCount: 1023, fillByte: 0x19)
    let exactData = makeDistinctPayload(byteCount: 1024, fillByte: 0x29)
    _ = try sandbox.createFile("Scan/s1.bin", data: smallData)
    _ = try sandbox.createFile("Scan/s2.bin", data: smallData)
    _ = try sandbox.createFile("Scan/e1.bin", data: exactData)
    _ = try sandbox.createFile("Scan/e2.bin", data: exactData)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)

    let start = Date()
    let groups = try await scanner.scanDuplicates(under: sandbox.url("Scan"), minBytes: 1024)
    let elapsed = Date().timeIntervalSince(start)

    try E2ERunner.expect(elapsed < 1.0, "Duplicate scan blocked on FIFO (\(elapsed)s)")
    try E2ERunner.expectEqual(groups.count, 1)
    try E2ERunner.expectEqual(groups[0].fileSize, UInt64(1024))
    try E2ERunner.expectEqual(Set(groups[0].files.map(\.name)), Set(["e1.bin", "e2.bin"]))
}

runner.register(
    id: "f8-t2-toctou-before-duplicate-delete",
    tier: 2,
    feature: "F-8",
    name: "RemovalEngine blocks duplicate cleanup if scanned parent directory is swapped for symlink"
) {
    let sandbox = try E2ESandbox(prefix: "f8-t2-toctou")
    defer { sandbox.cleanup() }

    let payload = makeDistinctPayload(byteCount: 16_384, fillByte: 0x8E)
    let dirA = try sandbox.createDirectory("Scan/DirA")
    let dirB = try sandbox.createDirectory("Scan/DirB")
    let keepA = try sandbox.createFile("Scan/DirA/dup.bin", data: payload)
    _ = try sandbox.createFile("Scan/DirB/dup.bin", data: payload)
    let safeDir = try sandbox.createDirectory("Keep/SafeDir")
    let safeDecoy = try sandbox.createFile("Keep/SafeDir/dup.bin", data: payload)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
    let groups = try await scanner.scanDuplicates(under: sandbox.url("Scan"), minBytes: 1)
    let group = try E2ERunner.expectNotNil(groups.first)
    let entryB = try E2ERunner.expectNotNil(group.files.first(where: { $0.url.path.contains("/DirB/") }))

    // Swap DirB for symlink to Keep/SafeDir after scan
    _ = dirA
    try FileManager.default.removeItem(at: dirB)
    try FileManager.default.createSymbolicLink(at: dirB, withDestinationURL: safeDir)

    let engine = RemovalEngine(safetyGuard: sg)
    let report = engine.remove(
        targets: [RemovalTarget(url: entryB.url, estimatedSize: Int64(group.fileSize), expectedCanonicalParent: entryB.expectedCanonicalParent)],
        mode: .permanent,
        allowElevation: false
    )

    try E2ERunner.expect(!report.isFullSuccess)
    try E2ERunner.expectContains(report.failures.first?.reason ?? "", "TOCTOU")
    try E2ERunner.expect(RemovalEngine.entryExists(safeDecoy), "SafeDir file must remain untouched")
    try E2ERunner.expect(RemovalEngine.entryExists(keepA), "DirA original must remain untouched")
}

// MARK: - Feature F9: Memory/RAM Monitor & Release (6 Tier 1 + 6 Tier 2 = 12 Cases)

runner.register(
    id: "f9-t1-live-snapshot-physical-bounds",
    tier: 1,
    feature: "F-9",
    name: "MemoryReleaseService captures live Mach MemorySnapshot matching physicalMemory bounds"
) {
    let service = MemoryReleaseService()
    let snapshot = service.captureSnapshot()
    let physical = ProcessInfo.processInfo.physicalMemory

    try E2ERunner.expectEqual(snapshot.totalBytes, physical, "totalBytes must equal ProcessInfo.physicalMemory")
    try E2ERunner.expect(snapshot.totalBytes > 0, "totalBytes must be > 0")
    try E2ERunner.expect(snapshot.activeBytes > 0, "activeBytes must be > 0")
    try E2ERunner.expect(snapshot.wiredBytes > 0, "wiredBytes must be > 0")

    let sumBuckets = snapshot.activeBytes &+ snapshot.wiredBytes &+ snapshot.compressedBytes &+ snapshot.cachedFilesBytes &+ snapshot.freeBytes
    try E2ERunner.expect(sumBuckets > 0, "Sum of memory buckets must be > 0")
    try E2ERunner.expect(sumBuckets <= physical &* 2, "Sum of Mach buckets should be within sane physical memory bounds")
}

runner.register(
    id: "f9-t1-swap-and-pressure-valid",
    tier: 1,
    feature: "F-9",
    name: "MemoryReleaseService reports valid swapUsedBytes <= swapTotalBytes and valid pressureLevel"
) {
    let service = MemoryReleaseService()
    let s1 = service.captureSnapshot()
    let s2 = service.captureSnapshot()

    try E2ERunner.expect(s1.swapUsedBytes <= s1.swapTotalBytes, "swapUsedBytes must be <= swapTotalBytes")
    try E2ERunner.expect(s2.swapUsedBytes <= s2.swapTotalBytes, "swapUsedBytes must be <= swapTotalBytes")
    try E2ERunner.expectEqual(s1.totalBytes, s2.totalBytes)
    _ = s1.pressureLevel
}

runner.register(
    id: "f9-t1-nonprivileged-relief-honest",
    tier: 1,
    feature: "F-9",
    name: "Non-privileged memory relief runs without elevation and reports honest before/after snapshots"
) {
    let invokedAdmin = LockedBox(false)
    let sg = SafetyGuard(selfBundlePath: nil)
    let executor = PrivilegedExecutor(
        safetyGuard: sg,
        adminShellRunner: { _ in
            invokedAdmin.set(true)
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    )
    let service = MemoryReleaseService(privilegedExecutor: executor)
    let result = try await service.releaseMemory(allowElevation: false)

    try E2ERunner.expect(!invokedAdmin.get(), "Non-privileged relief must not invoke adminShellRunner")
    try E2ERunner.expect(!result.usedElevation, "usedElevation must be false")
    try E2ERunner.expectEqual(result.before.totalBytes, result.after.totalBytes)
    try E2ERunner.expect(!result.methodUsed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    try E2ERunner.expect(!result.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    try E2ERunner.expect(result.reclaimedEstimateBytes <= result.before.totalBytes, "Reclaimed estimate must never exceed physical memory")
}

runner.register(
    id: "f9-t1-elevated-purge-mocked-runner",
    tier: 1,
    feature: "F-9",
    name: "Elevated memory release invokes /usr/sbin/purge via injected PrivilegedExecutor ScriptRunner"
) {
    let capturedScript = LockedBox<String?>(nil)
    let sg = SafetyGuard(selfBundlePath: nil)
    let executor = PrivilegedExecutor(
        safetyGuard: sg,
        adminShellRunner: { script in
            capturedScript.set(script)
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    )
    let service = MemoryReleaseService(privilegedExecutor: executor)
    let result = try await service.releaseMemory(allowElevation: true)

    let script = try E2ERunner.expectNotNil(capturedScript.get(), "Expected adminShellRunner to be called")
    try E2ERunner.expectContains(script, "/usr/sbin/purge", "Elevated purge script must invoke /usr/sbin/purge")
    try E2ERunner.expect(result.usedElevation, "usedElevation must be true on elevated purge")
    try E2ERunner.expectEqual(result.before.totalBytes, ProcessInfo.processInfo.physicalMemory)
    try E2ERunner.expectEqual(result.after.totalBytes, ProcessInfo.processInfo.physicalMemory)
    try E2ERunner.expect(!result.note.isEmpty)
}

runner.register(
    id: "f9-t1-snapshot-monotone-timestamps-format",
    tier: 1,
    feature: "F-9",
    name: "MemorySnapshot properties and ratios contain zero NaN or unsigned underflow"
) {
    let service = MemoryReleaseService()
    let s1 = service.captureSnapshot()
    let s2 = service.captureSnapshot()

    try E2ERunner.expectEqual(s1.totalBytes, ProcessInfo.processInfo.physicalMemory)
    try E2ERunner.expectEqual(s2.totalBytes, ProcessInfo.processInfo.physicalMemory)
    let usedApprox = s1.activeBytes &+ s1.wiredBytes &+ s1.compressedBytes
    let ratio = Double(usedApprox) / Double(max(1, s1.totalBytes))
    try E2ERunner.expect(!ratio.isNaN && !ratio.isInfinite && ratio >= 0.0)
}

runner.register(
    id: "f9-t1-concurrent-snapshots-safe",
    tier: 1,
    feature: "F-9",
    name: "Concurrent captureSnapshot calls under Swift 6 TaskGroup complete cleanly without data races"
) {
    let service = MemoryReleaseService()
    let physical = ProcessInfo.processInfo.physicalMemory

    let totals = try await withThrowingTaskGroup(of: UInt64.self) { group in
        for _ in 0..<8 {
            group.addTask {
                let snap = service.captureSnapshot()
                return snap.totalBytes
            }
        }
        var collected: [UInt64] = []
        for try await value in group {
            collected.append(value)
        }
        return collected
    }

    try E2ERunner.expectEqual(totals.count, 8)
    for total in totals {
        try E2ERunner.expectEqual(total, physical)
    }
}

runner.register(
    id: "f9-t2-elevated-user-cancelled",
    tier: 2,
    feature: "F-9",
    name: "Elevated memory release surfaces user cancellation cleanly on AppleScript (-128)"
) {
    let sg = SafetyGuard(selfBundlePath: nil)
    let executor = PrivilegedExecutor(
        safetyGuard: sg,
        adminShellRunner: { _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "execution error: User canceled. (-128)")
        }
    )
    let service = MemoryReleaseService(privilegedExecutor: executor)

    let err = try await E2ERunner.expectThrowsAsync("Expected elevated release to throw on user cancellation") {
        _ = try await service.releaseMemory(allowElevation: true)
    }
    guard let privErr = err as? PrivilegedError else {
        throw E2EAssertionFailure("Expected PrivilegedError, got \(type(of: err)): \(err)")
    }
    try E2ERunner.expectEqual(privErr, .userCancelled)
}

runner.register(
    id: "f9-t2-elevated-command-failed",
    tier: 2,
    feature: "F-9",
    name: "Elevated memory release propagates command failure cleanly when /usr/sbin/purge fails"
) {
    let sg = SafetyGuard(selfBundlePath: nil)
    let executor = PrivilegedExecutor(
        safetyGuard: sg,
        adminShellRunner: { _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "purge failed")
        }
    )
    let service = MemoryReleaseService(privilegedExecutor: executor)

    let err = try await E2ERunner.expectThrowsAsync("Expected elevated release to throw on purge failure") {
        _ = try await service.releaseMemory(allowElevation: true)
    }
    guard let privErr = err as? PrivilegedError else {
        throw E2EAssertionFailure("Expected PrivilegedError, got \(type(of: err)): \(err)")
    }
    switch privErr {
    case .commandFailed:
        break
    default:
        throw E2EAssertionFailure("Expected PrivilegedError.commandFailed, got \(privErr)")
    }
}

runner.register(
    id: "f9-t2-reclaimed-estimate-never-underflows",
    tier: 2,
    feature: "F-9",
    name: "MemoryReleaseResult reclaimedEstimateBytes never underflows UInt64 across repeated runs"
) {
    let service = MemoryReleaseService()
    for _ in 0..<5 {
        let res = try await service.releaseMemory(allowElevation: false)
        try E2ERunner.expect(res.reclaimedEstimateBytes <= res.before.totalBytes, "Detected probable UInt64 underflow in reclaimedEstimateBytes: \(res.reclaimedEstimateBytes)")
    }
}

runner.register(
    id: "f9-t2-no-disk-or-history-side-effects",
    tier: 2,
    feature: "F-9",
    name: "Memory release never mutates filesystem or writes fake freed bytes to CleanupHistoryStore"
) {
    let sandbox = try E2ESandbox(prefix: "f9-t2-nodisk")
    defer { sandbox.cleanup() }

    let sentinel = try sandbox.createFile("Work/sentinel.txt", utf8: "untouched")
    let defaultHistoryStore = CleanupHistoryStore()
    let beforeHistory = defaultHistoryStore.load()

    let sg = SafetyGuard(selfBundlePath: nil)
    let mockedExecutor = PrivilegedExecutor(
        safetyGuard: sg,
        adminShellRunner: { _ in ProcessResult(exitCode: 0, stdout: "", stderr: "") }
    )
    let service = MemoryReleaseService(privilegedExecutor: mockedExecutor)
    _ = try await service.releaseMemory(allowElevation: false)
    _ = try await service.releaseMemory(allowElevation: true)

    try E2ERunner.expectEqual(defaultHistoryStore.load(), beforeHistory, "Memory release must not log CleanupHistoryStore entries")
    let workChildren = try FileManager.default.contentsOfDirectory(at: sandbox.url("Work"), includingPropertiesForKeys: nil)
    try E2ERunner.expectEqual(workChildren.map(\.lastPathComponent), ["sentinel.txt"], "Memory release must not create or delete files in sandbox")
    try E2ERunner.expectEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
}

runner.register(
    id: "f9-t2-no-shell-command-injection-in-purge",
    tier: 2,
    feature: "F-9",
    name: "Elevated memory release invokes strictly /usr/sbin/purge with zero path interpolation"
) {
    let capturedScript = LockedBox<String?>(nil)
    let sg = SafetyGuard(selfBundlePath: nil)
    let executor = PrivilegedExecutor(
        safetyGuard: sg,
        adminShellRunner: { script in
            capturedScript.set(script)
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    )
    let service = MemoryReleaseService(privilegedExecutor: executor)
    _ = try await service.releaseMemory(allowElevation: true)

    let script = try E2ERunner.expectNotNil(capturedScript.get())
    let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
    try E2ERunner.expectContains(trimmed, "/usr/sbin/purge")
    try E2ERunner.expectNotContains(trimmed, "$TMPDIR")
    try E2ERunner.expectNotContains(trimmed, "rm ")
    try E2ERunner.expectNotContains(trimmed, ";")
    try E2ERunner.expectNotContains(trimmed, "&&")
}

runner.register(
    id: "f9-t2-zero-swap-and-bounded-latency",
    tier: 2,
    feature: "F-9",
    name: "MemoryReleaseService handles swap edge cases cleanly and completes within 2.0s latency SLA"
) {
    let service = MemoryReleaseService()
    let start = Date()
    let snap = service.captureSnapshot()
    let relief = try await service.releaseMemory(allowElevation: false)
    let elapsed = Date().timeIntervalSince(start)

    try E2ERunner.expect(elapsed < 2.0, "Memory snapshot + non-privileged relief exceeded 2.0s SLA (\(elapsed)s)")
    if snap.swapTotalBytes == 0 {
        try E2ERunner.expectEqual(snap.swapUsedBytes, 0)
    }
    let swapRatio = snap.swapTotalBytes == 0 ? 0.0 : Double(snap.swapUsedBytes) / Double(snap.swapTotalBytes)
    try E2ERunner.expect(!swapRatio.isNaN && !swapRatio.isInfinite && swapRatio >= 0.0 && swapRatio <= 1.0)
    try E2ERunner.expectEqual(relief.after.totalBytes, snap.totalBytes)
}

await runner.runAndExit()

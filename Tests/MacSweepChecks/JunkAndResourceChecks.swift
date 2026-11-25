import CryptoKit
import Darwin
import Foundation
@testable import MacSweepCore

private final class AsyncResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func store(_ res: Result<T, Error>) {
        lock.withLock { result = res }
    }

    func take() -> Result<T, Error>? {
        lock.withLock { result }
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        self.storage = value
    }

    func set(_ value: Value) {
        lock.withLock { storage = value }
    }

    func get() -> Value {
        lock.withLock { storage }
    }
}

private func runAsync<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = AsyncResultBox<T>()
    Task {
        do {
            box.store(.success(try await work()))
        } catch {
            box.store(.failure(error))
        }
        sem.signal()
    }
    sem.wait()
    return try box.take()!.get()
}

private func createFile(
    in root: URL,
    relativePath: String,
    data: Data
) throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
}

private func createExactSizeFile(
    in root: URL,
    relativePath: String,
    byteCount: Int,
    fillByte: UInt8 = 0x41
) throws -> URL {
    try createFile(in: root, relativePath: relativePath, data: Data(repeating: fillByte, count: byteCount))
}

func runJunkAndResourceChecks(_ runner: CheckRunner) {
    print("== Junk Cleaner & Resource Release (M3) Checks ==")

    // MARK: - A. JunkCacheScanner Checks (7 checks)

    runner.run("JunkCacheScanner validates subpaths and drills into sharedVendorFolderNames without targeting bare vendor roots") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-junk-vendor")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/com.acme.AppA/a.bin", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/Google/Chrome/Cache/c1.dat", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/Microsoft/Edge/c2.dat", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/Adobe/Premiere/c3.dat", byteCount: 4096)

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)
        let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox, runningBundleIDs: [], runningAppNames: [])
        let categories = try runAsync { try await scanner.scan() }

        let allEntries = categories.flatMap(\.entries)
        let allPaths = Set(allEntries.map { $0.url.standardizedFileURL.path })

        try runner.expect(!allPaths.contains(sandbox.appendingPathComponent("Library/Caches").standardizedFileURL.path))
        for vendor in ["Google", "Microsoft", "Adobe"] {
            let bareVendor = sandbox.appendingPathComponent("Library/Caches/\(vendor)").standardizedFileURL.path
            try runner.expect(!allPaths.contains(bareVendor), "Bare vendor root \(vendor) must never be emitted")
        }
        try runner.expect(allEntries.contains(where: { $0.url.path.contains("/Library/Caches/Google/Chrome") }))
        try runner.expect(allEntries.contains(where: { $0.url.path.contains("/Library/Caches/Microsoft/Edge") }))
        try runner.expect(allEntries.contains(where: { $0.url.path.contains("/Library/Caches/Adobe/Premiere") }))

        for cat in categories where cat.category == .userCaches || cat.category == .browserCaches {
            for entry in cat.entries {
                try runner.expect(sg.validateCacheSubpath(entry.url).isAllowed)
                try runner.expectEqual(entry.expectedCanonicalParent, PrivilegedExecutor.canonicalParentPath(forTargetURL: entry.url))
            }
        }
    }

    runner.run("JunkCacheScanner excludes Apple, com.apple.*, Apple group containers, local.macsweep, and user-protected caches") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-junk-apple")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/Apple/x.bin", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/com.apple.Safari/y.bin", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/group.com.apple.notes/z.bin", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/local.macsweep/w.bin", byteCount: 4096)
        let protPathDir = sandbox.appendingPathComponent("Library/Caches/com.keep.path")
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/com.keep.path/p.bin", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/com.keep.bundle/b.bin", byteCount: 4096)
        let benign = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/com.benign.app/ok.bin", byteCount: 4096)

        let sg = SafetyGuard(
            homeDirectory: sandbox,
            selfBundlePath: nil,
            protectedPaths: [protPathDir.path],
            protectedBundleIDs: ["com.keep.bundle"]
        )
        let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox, runningBundleIDs: [], runningAppNames: [])
        let categories = try runAsync { try await scanner.scan() }
        let userCat = categories.first(where: { $0.category == .userCaches })

        try runner.expectEqual(userCat?.entries.map(\.name), ["com.benign.app"])
        try runner.expectEqual(userCat?.entries.first?.url.deletingLastPathComponent().path, benign.deletingLastPathComponent().deletingLastPathComponent().path)
    }

    runner.run("JunkCacheScanner isolates user logs and DiagnosticReports children while preserving roots and marking system logs unchecked") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-junk-logs")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Logs/AppFoo/foo.log", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Logs/DiagnosticReports/AppFoo.crash", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Logs/Google/Updater.log", byteCount: 4096)

        let sysLogs = sandbox.appendingPathComponent("SysLogs")
        _ = try createExactSizeFile(in: sysLogs, relativePath: "SysDaemon/daemon.log", byteCount: 4096)

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)
        let env = JunkScannerEnvironment(
            homeDirectory: sandbox,
            systemLogsDirectory: sysLogs,
            runningBundleIDs: [],
            runningAppNames: [],
            includeSystemLogs: true
        )
        let scanner = JunkCacheScanner(safetyGuard: sg, environment: env)
        let categories = try runAsync { try await scanner.scan() }

        let logsCat = categories.first(where: { $0.category == .logs })
        try runner.expect(logsCat != nil)
        let paths = Set((logsCat?.entries ?? []).map { $0.url.standardizedFileURL.path })
        try runner.expect(!paths.contains(sandbox.appendingPathComponent("Library/Logs").standardizedFileURL.path))
        try runner.expect(!paths.contains(sandbox.appendingPathComponent("Library/Logs/DiagnosticReports").standardizedFileURL.path))
        try runner.expect(!paths.contains(sandbox.appendingPathComponent("Library/Logs/Google").standardizedFileURL.path))
        try runner.expect(paths.contains(sandbox.appendingPathComponent("Library/Logs/Google/Updater.log").standardizedFileURL.path))

        let sysEntry = logsCat?.entries.first(where: { $0.url.path.contains("SysDaemon") })
        try runner.expect(sysEntry != nil)
        try runner.expectEqual(sysEntry?.requiresAdmin, true)
        try runner.expectEqual(sysEntry?.isSelected, false)
    }

    runner.run("JunkCacheScanner targets third-party browser cache subpaths only and never flags Safari or browser profile data") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-junk-browser")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/Google/Chrome/Default/Cache/data_0", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/BraveSoftware/Brave-Browser/Default/Cache/data_0", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Application Support/Google/Chrome/Default/Bookmarks", byteCount: 512)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Application Support/Google/Chrome/Default/Cookies", byteCount: 512)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Safari/Bookmarks.plist", byteCount: 512)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Containers/com.apple.Safari/Data/Library/Caches/c.bin", byteCount: 512)

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)
        let scanner = JunkCacheScanner(
            safetyGuard: sg,
            homeDirectory: sandbox,
            runningBundleIDs: ["com.google.Chrome"],
            runningAppNames: ["Google Chrome"]
        )
        let categories = try runAsync { try await scanner.scan() }

        let browserCat = categories.first(where: { $0.category == .browserCaches })
        let allPaths = categories.flatMap(\.entries).map { $0.url.standardizedFileURL.path }
        try runner.expect(!allPaths.contains(where: { $0.contains("Bookmarks") || $0.contains("Cookies") || $0.contains("Safari") }))

        let chromeEntry = browserCat?.entries.first(where: { $0.browserBundleID == "com.google.Chrome" })
        let braveEntry = browserCat?.entries.first(where: { $0.browserBundleID == "com.brave.Browser" })
        try runner.expectEqual(chromeEntry?.isRunningAppBlocked, true)
        try runner.expectEqual(chromeEntry?.isSelected, false)
        try runner.expectEqual(braveEntry?.isRunningAppBlocked, false)
        try runner.expectEqual(braveEntry?.isSelected, true)
    }

    runner.run("JunkCacheScanner discovers developer caches without double-counting and keeps Xcode Archives unchecked") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-junk-dev")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Developer/Xcode/DerivedData/MyApp/d.dat", byteCount: 8192)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Developer/Xcode/Archives/2026-01/App.xcarchive", byteCount: 8192)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Developer/CoreSimulator/Caches/dyld/sim.bin", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Developer/CoreSimulator/Devices/UUID/data.bin", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/Homebrew/pkg.tar.gz", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: ".npm/_cacache/idx", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: ".cargo/registry/cache/crate.crate", byteCount: 4096)

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)
        let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox, runningBundleIDs: [], runningAppNames: [])
        let categories = try runAsync { try await scanner.scan() }

        let devCat = categories.first(where: { $0.category == .developerCaches })
        let userCat = categories.first(where: { $0.category == .userCaches })
        let devPaths = Set((devCat?.entries ?? []).map { $0.url.standardizedFileURL.path })
        let userPaths = Set((userCat?.entries ?? []).map { $0.url.standardizedFileURL.path })

        let homebrewPath = sandbox.appendingPathComponent("Library/Caches/Homebrew").standardizedFileURL.path
        try runner.expect(devPaths.contains(homebrewPath))
        try runner.expect(!userPaths.contains(homebrewPath), "Homebrew cache must not be double-counted in userCaches")
        try runner.expect(!devPaths.contains(where: { $0.contains("CoreSimulator/Devices") }))

        let archive = devCat?.entries.first(where: { $0.url.path.contains("/Archives/") })
        try runner.expect(archive != nil)
        try runner.expectEqual(archive?.isSelected, false)
    }

    runner.run("JunkCacheScanner enumerates ~/.Trash children only and RemovalEngine rejects mode: .trash on Trash items") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-junk-trash")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let trashItem = try createExactSizeFile(in: sandbox, relativePath: ".Trash/old.zip", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: ".Trash/OldFolder/item.bin", byteCount: 4096)

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)
        let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox, runningBundleIDs: [], runningAppNames: [])
        let categories = try runAsync { try await scanner.scan() }

        let trashCat = categories.first(where: { $0.category == .trash })
        let trashPaths = Set((trashCat?.entries ?? []).map { $0.url.standardizedFileURL.path })
        try runner.expect(!trashPaths.contains(sandbox.appendingPathComponent(".Trash").standardizedFileURL.path))
        try runner.expect(trashPaths.contains(trashItem.standardizedFileURL.path))

        let executor = PrivilegedExecutor(
            safetyGuard: sg,
            trashDirectory: sandbox.appendingPathComponent(".Trash")
        )
        let engine = RemovalEngine(safetyGuard: sg, privilegedExecutor: executor)
        let target = RemovalTarget(url: trashItem, estimatedSize: 4096)

        let badReport = engine.remove(targets: [target], mode: .trash, allowElevation: false)
        try runner.expect(!badReport.isFullSuccess, "RemovalEngine must reject .trash mode for items already in ~/.Trash")
        try runner.expect(RemovalEngine.entryExists(trashItem))

        let okReport = engine.remove(targets: [target], mode: .permanent, allowElevation: false)
        try runner.expect(okReport.isFullSuccess)
        try runner.expect(!RemovalEngine.entryExists(trashItem))
    }

    runner.run("JunkCacheScanner skips symlinks, FIFOs, 0o000 dirs, and honors Task cancellation") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-junk-safety")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let secret = try createExactSizeFile(in: sandbox, relativePath: "Documents/secret.txt", byteCount: 1024)
        let cachesDir = sandbox.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: cachesDir.appendingPathComponent("EscapeDocs"),
            withDestinationURL: sandbox.appendingPathComponent("Documents")
        )

        let fifoApp = cachesDir.appendingPathComponent("com.acme.Fifo")
        try FileManager.default.createDirectory(at: fifoApp, withIntermediateDirectories: true)
        try runner.expectEqual(mkfifo(fifoApp.appendingPathComponent("pipe.fifo").path, 0o600), 0)

        let lockedDir = cachesDir.appendingPathComponent("com.acme.Locked")
        let lockedFile = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/com.acme.Locked/x.bin", byteCount: 1024)
        try runner.expectEqual(Darwin.chmod(lockedFile.path, 0o000), 0)
        try runner.expectEqual(Darwin.chmod(lockedDir.path, 0o000), 0)
        defer {
            _ = Darwin.chmod(lockedDir.path, 0o700)
            _ = Darwin.chmod(lockedFile.path, 0o600)
        }

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)
        let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox, runningBundleIDs: [], runningAppNames: [])

        let start = Date()
        let categories = try runAsync { try await scanner.scan() }
        try runner.expect(Date().timeIntervalSince(start) < 1.5)
        let paths = categories.flatMap(\.entries).map(\.url.path)
        try runner.expect(!paths.contains(where: { $0.contains("EscapeDocs") || $0.contains("secret.txt") }))
        try runner.expect(FileManager.default.fileExists(atPath: secret.path))

        var threwCancel = false
        do {
            _ = try runAsync {
                let task = Task {
                    try await scanner.scan()
                }
                task.cancel()
                return try await task.value
            }
        } catch is CancellationError {
            threwCancel = true
        }
        try runner.expect(threwCancel)
    }

    runner.run("JunkCacheScanner does not double-count Firefox caches in userCaches and enforces browserBundleID running-browser block") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-junk-firefox")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/Firefox/Profiles/abc.default/cache2/data.bin", byteCount: 8192)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/Mozilla/Updates/u.bin", byteCount: 4096)

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)

        let runningScanner = JunkCacheScanner(
            safetyGuard: sg,
            homeDirectory: sandbox,
            runningBundleIDs: ["org.mozilla.firefox"],
            runningAppNames: []
        )
        let runningCats = try runAsync { try await runningScanner.scan() }
        let userEntriesRunning = runningCats.first(where: { $0.category == .userCaches })?.entries ?? []
        let browserEntriesRunning = runningCats.first(where: { $0.category == .browserCaches })?.entries ?? []

        try runner.expect(!userEntriesRunning.contains(where: { $0.url.path.localizedCaseInsensitiveContains("firefox") || $0.url.path.localizedCaseInsensitiveContains("mozilla") }),
                          "Firefox/Mozilla caches must never be emitted in .userCaches")
        try runner.expectEqual(browserEntriesRunning.count, 2)
        for entry in browserEntriesRunning {
            try runner.expectEqual(entry.browserBundleID, "org.mozilla.firefox")
            try runner.expectEqual(entry.isRunningAppBlocked, true)
            try runner.expectEqual(entry.isSelected, false)
        }

        let idleScanner = JunkCacheScanner(
            safetyGuard: sg,
            homeDirectory: sandbox,
            runningBundleIDs: [],
            runningAppNames: []
        )
        let idleCats = try runAsync { try await idleScanner.scan() }
        let userEntriesIdle = idleCats.first(where: { $0.category == .userCaches })?.entries ?? []
        let browserEntriesIdle = idleCats.first(where: { $0.category == .browserCaches })?.entries ?? []

        try runner.expect(userEntriesIdle.isEmpty)
        try runner.expectEqual(browserEntriesIdle.count, 2)
        try runner.expect(browserEntriesIdle.allSatisfy { $0.browserBundleID == "org.mozilla.firefox" && !$0.isRunningAppBlocked && $0.isSelected })
    }

    runner.run("JunkCacheScanner blocks intermediate symlink escapes in Developer, Logs, CrashReporter, and Trash paths") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-junk-sym-escape")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        _ = try createExactSizeFile(in: sandbox, relativePath: "Documents/DerivedData/MySecret/secret.bin", byteCount: 8192)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Documents/DiagnosticReports/important.crash", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Documents/CrashReporter/secret.plist", byteCount: 2048)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Documents/TrashTarget/keep.txt", byteCount: 2048)

        let devDir = sandbox.appendingPathComponent("Library/Developer")
        let libDir = sandbox.appendingPathComponent("Library")
        let appSuppDir = sandbox.appendingPathComponent("Library/Application Support")
        try FileManager.default.createDirectory(at: devDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSuppDir, withIntermediateDirectories: true)

        try FileManager.default.createSymbolicLink(
            at: devDir.appendingPathComponent("Xcode"),
            withDestinationURL: sandbox.appendingPathComponent("Documents")
        )
        try FileManager.default.createSymbolicLink(
            at: libDir.appendingPathComponent("Logs"),
            withDestinationURL: sandbox.appendingPathComponent("Documents")
        )
        try FileManager.default.createSymbolicLink(
            at: appSuppDir.appendingPathComponent("CrashReporter"),
            withDestinationURL: sandbox.appendingPathComponent("Documents/CrashReporter")
        )
        try FileManager.default.createSymbolicLink(
            at: sandbox.appendingPathComponent(".Trash"),
            withDestinationURL: sandbox.appendingPathComponent("Documents/TrashTarget")
        )

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)
        let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox, runningBundleIDs: [], runningAppNames: [])
        let categories = try runAsync { try await scanner.scan() }
        let allEntries = categories.flatMap(\.entries)
        try runner.expect(allEntries.isEmpty, "Intermediate symlinks into ~/Documents must yield 0 junk hits, got \(allEntries.map(\.url.path))")
    }

    // MARK: - B. Large Files Checks (5 checks)

    runner.run("LargeAndDuplicateScanner enforces inclusive threshold, age, category, and descending sort") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-large-filters")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let below = try createExactSizeFile(in: sandbox, relativePath: "Scan/below.bin", byteCount: 9_999)
        let exact = try createExactSizeFile(in: sandbox, relativePath: "Scan/exact.mp4", byteCount: 10_000)
        let above = try createExactSizeFile(in: sandbox, relativePath: "Scan/above.dmg", byteCount: 15_000)
        _ = below

        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-120 * 86_400)], ofItemAtPath: exact.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-5 * 86_400)], ofItemAtPath: above.path)

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)
        let scanner = LargeAndDuplicateScanner(safetyGuard: sg)

        let allOver10K = try runAsync {
            try await scanner.scanLargeFiles(under: sandbox.appendingPathComponent("Scan"), minBytes: 10_000, referenceDate: now)
        }
        try runner.expectEqual(allOver10K.map(\.name), ["above.dmg", "exact.mp4"])
        try runner.expectEqual(allOver10K.first?.category, .diskImageAndArchive)
        try runner.expectEqual(allOver10K.last?.category, .video)
        try runner.expectEqual(allOver10K.first?.expectedCanonicalParent, PrivilegedExecutor.canonicalParentPath(forTargetURL: above))

        let stale90 = try runAsync {
            try await scanner.scanLargeFiles(under: sandbox.appendingPathComponent("Scan"), minBytes: 10_000, olderThanDays: 90, referenceDate: now)
        }
        try runner.expectEqual(stale90.map(\.name), ["exact.mp4"])
    }

    runner.run("LargeAndDuplicateScanner prunes .app, .photoslibrary, .ssh, and protectedPaths while descending into ~/Documents") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-large-prune")
        let extSandbox = try runner.makeTempSandbox(prefix: "m3-large-ext")
        defer {
            try? FileManager.default.removeItem(at: sandbox)
            try? FileManager.default.removeItem(at: extSandbox)
        }

        _ = try createExactSizeFile(in: sandbox, relativePath: "Pictures/Main.photoslibrary/orig.mov", byteCount: 20_000)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Applications/Demo.app/Contents/MacOS/Demo", byteCount: 20_000)
        _ = try createExactSizeFile(in: sandbox, relativePath: ".ssh/huge.key", byteCount: 20_000)
        let vaultDir = sandbox.appendingPathComponent("Vault")
        _ = try createExactSizeFile(in: sandbox, relativePath: "Vault/secret.bin", byteCount: 20_000)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Documents/keep_findable.bin", byteCount: 20_000)

        let extBig = try createExactSizeFile(in: extSandbox, relativePath: "ext.bin", byteCount: 25_000)
        try FileManager.default.createSymbolicLink(
            at: sandbox.appendingPathComponent("Documents/link.bin"),
            withDestinationURL: extBig
        )

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil, protectedPaths: [vaultDir.path])
        let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
        let items = try runAsync {
            try await scanner.scanLargeFiles(under: sandbox, minBytes: 15_000)
        }

        let names = items.map(\.name)
        try runner.expectEqual(names, ["keep_findable.bin"])
    }

    runner.run("SafetyGuard.shouldPruneDirectoryScan uses downward containment so ~/Pictures and ~/Documents remain scannable") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-prune-downward")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        _ = try createExactSizeFile(in: sandbox, relativePath: "Pictures/Photos Library.photoslibrary/originals/photo.mov", byteCount: 20_000)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Pictures/export.mp4", byteCount: 20_000)
        let keepFile = try createExactSizeFile(in: sandbox, relativePath: "Documents/Sub/keep.bin", byteCount: 20_000)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Documents/other_large.dmg", byteCount: 20_000)

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil, protectedPaths: [keepFile.path])

        let picturesDir = sandbox.appendingPathComponent("Pictures")
        let documentsDir = sandbox.appendingPathComponent("Documents")
        let docsSubDir = sandbox.appendingPathComponent("Documents/Sub")
        let photosLibDir = sandbox.appendingPathComponent("Pictures/Photos Library.photoslibrary")

        try runner.expect(!sg.shouldPruneDirectoryScan(at: picturesDir), "~/Pictures must not be pruned due to Photos Library descendant")
        try runner.expect(!sg.shouldPruneDirectoryScan(at: documentsDir), "~/Documents must not be pruned due to protected descendant")
        try runner.expect(!sg.shouldPruneDirectoryScan(at: docsSubDir), "~/Documents/Sub must not be pruned due to protected keep.bin")
        try runner.expect(sg.shouldPruneDirectoryScan(at: photosLibDir))
        try runner.expect(sg.shouldPruneDirectoryScan(at: keepFile))

        try runner.expect(!sg.validateForRemoval(documentsDir).isAllowed)
        try runner.expect(!sg.validateForRemoval(keepFile).isAllowed)

        let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
        let items = try runAsync {
            try await scanner.scanLargeFiles(under: sandbox, minBytes: 15_000)
        }
        let discoveredNames = Set(items.map(\.name))
        try runner.expectEqual(discoveredNames, ["export.mp4", "other_large.dmg"])
    }

    runner.run("LargeAndDuplicateScanner deduplicates hardlinks, skips FIFOs, and survives 0o000 subdirectories") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-large-hardlink")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let scanRoot = sandbox.appendingPathComponent("Scan")
        let real = try createExactSizeFile(in: sandbox, relativePath: "Scan/real.bin", byteCount: 16_384)
        try runner.expectEqual(Darwin.link(real.path, scanRoot.appendingPathComponent("hard.bin").path), 0)
        try runner.expectEqual(mkfifo(scanRoot.appendingPathComponent("pipe.fifo").path, 0o600), 0)

        let lockedDir = scanRoot.appendingPathComponent("Locked")
        _ = try createExactSizeFile(in: sandbox, relativePath: "Scan/Locked/inside.bin", byteCount: 16_384)
        try runner.expectEqual(Darwin.chmod(lockedDir.path, 0o000), 0)
        defer { _ = Darwin.chmod(lockedDir.path, 0o700) }

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)
        let scanner = LargeAndDuplicateScanner(safetyGuard: sg)

        let start = Date()
        let items = try runAsync {
            try await scanner.scanLargeFiles(under: scanRoot, minBytes: 10_000)
        }
        try runner.expect(Date().timeIntervalSince(start) < 1.0)
        try runner.expectEqual(items.count, 1)
    }

    runner.run("LargeAndDuplicateScanner skips SF_DATALESS and st_dev mount boundaries via statProvider") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-large-stat")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let local = try createExactSizeFile(in: sandbox, relativePath: "Scan/local.bin", byteCount: 12_000)
        let cloud = try createExactSizeFile(in: sandbox, relativePath: "Scan/cloud.bin", byteCount: 12_000)
        let mountDir = sandbox.appendingPathComponent("Scan/MountedDrive")
        _ = try createExactSizeFile(in: sandbox, relativePath: "Scan/MountedDrive/ext.bin", byteCount: 12_000)

        var baseStat = stat()
        try runner.expectEqual(lstat(sandbox.path, &baseStat), 0)
        let foreignDev = baseStat.st_dev &+ 1
        let cloudPath = cloud.standardizedFileURL.path
        let mountPath = mountDir.standardizedFileURL.path

        let scanner = LargeAndDuplicateScanner(
            safetyGuard: SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil),
            statProvider: { path in
                var st = stat()
                guard lstat(path, &st) == 0 else { return nil }
                if path == cloudPath {
                    st.st_flags |= UInt32(SF_DATALESS)
                } else if path == mountPath {
                    st.st_dev = foreignDev
                }
                return st
            }
        )

        let items = try runAsync {
            try await scanner.scanLargeFiles(under: sandbox.appendingPathComponent("Scan"), minBytes: 10_000)
        }
        try runner.expectEqual(items.map(\.url.path), [local.standardizedFileURL.path])
    }

    runner.run("LargeAndDuplicateScanner scanLargeFiles honors cooperative cancellation") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-large-cancel")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        for i in 0..<24 {
            _ = try createExactSizeFile(in: sandbox, relativePath: "Scan/f_\(i).bin", byteCount: 4096)
        }
        let scanner = LargeAndDuplicateScanner(safetyGuard: SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil))
        var cancelled = false
        do {
            _ = try runAsync {
                let t = Task {
                    try await scanner.scanLargeFiles(under: sandbox.appendingPathComponent("Scan"), minBytes: 1000)
                }
                t.cancel()
                return try await t.value
            }
        } catch is CancellationError {
            cancelled = true
        }
        try runner.expect(cancelled)
    }

    // MARK: - C. Duplicate Files 3-Stage Pipeline Checks (6 checks)

    runner.run("Duplicate finder partitions multi-groups, handles 1-byte/37-byte files, and sorts by reclaimableBytes") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-dup-groups")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let dataLarge = Data(repeating: 0xAA, count: 8192)
        let dataMed = Data(repeating: 0xBB, count: 4096)
        _ = try createFile(in: sandbox, relativePath: "Scan/L1.bin", data: dataLarge)
        _ = try createFile(in: sandbox, relativePath: "Scan/L2.bin", data: dataLarge)
        _ = try createFile(in: sandbox, relativePath: "Scan/M1.bin", data: dataMed)
        _ = try createFile(in: sandbox, relativePath: "Scan/M2.bin", data: dataMed)
        _ = try createFile(in: sandbox, relativePath: "Scan/M3.bin", data: dataMed)
        _ = try createFile(in: sandbox, relativePath: "Scan/M4.bin", data: dataMed)
        _ = try createFile(in: sandbox, relativePath: "Scan/one_a.bin", data: Data([0x41]))
        _ = try createFile(in: sandbox, relativePath: "Scan/one_b.bin", data: Data([0x41]))
        _ = try createFile(in: sandbox, relativePath: "Scan/one_diff.bin", data: Data([0x42]))

        let scanner = LargeAndDuplicateScanner(safetyGuard: SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil))
        let groups = try runAsync {
            try await scanner.scanDuplicates(under: sandbox.appendingPathComponent("Scan"), minBytes: 1)
        }

        try runner.expectEqual(groups.count, 3)
        try runner.expectEqual(groups[0].reclaimableBytes, UInt64(12_288))
        try runner.expectEqual(groups[1].reclaimableBytes, UInt64(8_192))
        try runner.expectEqual(groups[2].reclaimableBytes, UInt64(1))
    }

    runner.run("Duplicate finder Stage-3 SHA-256 catches middle-byte mismatch despite identical prefix & tail") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-dup-stage3")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        var p1 = Data(repeating: 0x55, count: 65_536)
        var p2 = Data(repeating: 0x55, count: 65_536)
        p1[32_768] = 0x10
        p2[32_768] = 0x20

        _ = try createFile(in: sandbox, relativePath: "Scan/coll_a.bin", data: p1)
        _ = try createFile(in: sandbox, relativePath: "Scan/coll_b.bin", data: p2)

        let scanner = LargeAndDuplicateScanner(safetyGuard: SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil))
        let groups = try runAsync {
            try await scanner.scanDuplicates(under: sandbox.appendingPathComponent("Scan"), minBytes: 1)
        }
        try runner.expect(groups.isEmpty)
    }

    runner.run("Duplicate finder deduplicates hardlinks via (st_dev, st_ino) and never flags them as duplicate copies") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-dup-hardlink")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let payload = Data(repeating: 0x7E, count: 8192)
        let c1 = try createFile(in: sandbox, relativePath: "Case1/a.bin", data: payload)
        try runner.expectEqual(Darwin.link(c1.path, sandbox.appendingPathComponent("Case1/b_hard.bin").path), 0)

        let x = try createFile(in: sandbox, relativePath: "Case2/x.bin", data: payload)
        try runner.expectEqual(Darwin.link(x.path, sandbox.appendingPathComponent("Case2/x_hard.bin").path), 0)
        _ = try createFile(in: sandbox, relativePath: "Case2/y_copy.bin", data: payload)

        let scanner = LargeAndDuplicateScanner(safetyGuard: SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil))
        let g1 = try runAsync { try await scanner.scanDuplicates(under: sandbox.appendingPathComponent("Case1"), minBytes: 1) }
        try runner.expect(g1.isEmpty)

        let g2 = try runAsync { try await scanner.scanDuplicates(under: sandbox.appendingPathComponent("Case2"), minBytes: 1) }
        try runner.expectEqual(g2.count, 1)
        try runner.expectEqual(g2.first?.files.count, 2)
        try runner.expectEqual(g2.first?.reclaimableBytes, UInt64(8192))
    }

    runner.run("Duplicate finder ignores 0-byte files, symlinks, SF_DATALESS, FIFOs, 0o000 files, .app, and protectedPaths") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-dup-exclusions")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        _ = try createFile(in: sandbox, relativePath: "Scan/e1.txt", data: Data())
        _ = try createFile(in: sandbox, relativePath: "Scan/e2.txt", data: Data())

        let payload = Data(repeating: 0x3D, count: 4096)
        let real = try createFile(in: sandbox, relativePath: "Scan/real.bin", data: payload)
        try FileManager.default.createSymbolicLink(at: sandbox.appendingPathComponent("Scan/sym.bin"), withDestinationURL: real)
        try runner.expectEqual(mkfifo(sandbox.appendingPathComponent("Scan/p.fifo").path, 0o600), 0)

        let locked = try createFile(in: sandbox, relativePath: "Scan/locked.bin", data: payload)
        try runner.expectEqual(Darwin.chmod(locked.path, 0o000), 0)
        defer { _ = Darwin.chmod(locked.path, 0o600) }

        _ = try createFile(in: sandbox, relativePath: "Scan/Mock.app/Contents/MacOS/Mock", data: payload)
        let vault = sandbox.appendingPathComponent("Scan/Vault")
        _ = try createFile(in: sandbox, relativePath: "Scan/Vault/keep.bin", data: payload)

        let dlA = try createFile(in: sandbox, relativePath: "Scan/cloudA.bin", data: payload)
        let dlB = try createFile(in: sandbox, relativePath: "Scan/cloudB.bin", data: payload)

        let sg = SafetyGuard(homeDirectory: sandbox.appendingPathComponent("Scan"), selfBundlePath: nil, protectedPaths: [vault.path])
        let dlPaths = Set([dlA.standardizedFileURL.path, dlB.standardizedFileURL.path])
        let scanner = LargeAndDuplicateScanner(
            safetyGuard: sg,
            statProvider: { path in
                var st = stat()
                guard lstat(path, &st) == 0 else { return nil }
                if dlPaths.contains(path) {
                    st.st_flags |= UInt32(SF_DATALESS)
                }
                return st
            }
        )
        let groups = try runAsync {
            try await scanner.scanDuplicates(under: sandbox.appendingPathComponent("Scan"), minBytes: 0)
        }
        try runner.expect(groups.isEmpty)
    }

    runner.run("Duplicate smart selection presets always keep >= 1 copy unchecked and settingSelection enforces keep-one") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-dup-smart")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let payload = Data(repeating: 0x4C, count: 4096)
        let orig = try createFile(in: sandbox, relativePath: "Scan/Documents/original.pdf", data: payload)
        let dlCopy = try createFile(in: sandbox, relativePath: "Scan/Downloads/original (1).pdf", data: payload)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: orig.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: dlCopy.path)

        let scanner = LargeAndDuplicateScanner(safetyGuard: SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil))
        let scanned = try runAsync { try await scanner.scanDuplicates(under: sandbox.appendingPathComponent("Scan"), minBytes: 1) }

        let smart = scanner.applySmartSelection(to: scanned)
        let g = smart[0]
        try runner.expectEqual(g.files.filter { !$0.isSelected }.count, 1)
        try runner.expectEqual(g.files.first(where: { !$0.isSelected })?.name, "original.pdf")

        let newest = g.applyingPreset(.keepNewest)
        try runner.expectEqual(newest.files.first(where: { !$0.isSelected })?.name, "original (1).pdf")

        // Attempting to check the last unchecked copy with enforceKeepOne: true is rejected.
        let keeperID = newest.files.first(where: { !$0.isSelected })!.id
        let blockedAll = newest.settingSelection(true, forEntryID: keeperID, enforceKeepOne: true)
        try runner.expectEqual(blockedAll.files.filter { !$0.isSelected }.count, 1)
    }

    runner.run("LargeAndDuplicateScanner scanDuplicates honors cooperative cancellation") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-dup-cancel")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let payload = Data(repeating: 0x22, count: 4096)
        for i in 0..<10 {
            _ = try createFile(in: sandbox, relativePath: "Scan/c_\(i).bin", data: payload)
        }
        let scanner = LargeAndDuplicateScanner(safetyGuard: SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil))
        var cancelled = false
        do {
            _ = try runAsync {
                let t = Task {
                    try await scanner.scanDuplicates(under: sandbox.appendingPathComponent("Scan"), minBytes: 1)
                }
                t.cancel()
                return try await t.value
            }
        } catch is CancellationError {
            cancelled = true
        }
        try runner.expect(cancelled)
    }

    // MARK: - D. MemoryReleaseService Checks (3 checks)

    runner.run("MemoryReleaseService captures live Mach MemorySnapshot within physical bounds and concurrently safely") {
        let service = MemoryReleaseService()
        let physical = ProcessInfo.processInfo.physicalMemory

        let totals = try runAsync {
            try await withThrowingTaskGroup(of: MemorySnapshot.self) { group in
                for _ in 0..<8 {
                    group.addTask { service.captureSnapshot() }
                }
                var out: [MemorySnapshot] = []
                for try await s in group { out.append(s) }
                return out
            }
        }

        try runner.expectEqual(totals.count, 8)
        for snap in totals {
            try runner.expectEqual(snap.totalBytes, physical)
            try runner.expect(snap.pageSizeBytes > 0)
            try runner.expect(snap.activeBytes > 0)
            try runner.expect(snap.wiredBytes > 0)
            try runner.expect(snap.swapUsedBytes <= snap.swapTotalBytes)
            try runner.expect(snap.usedFraction >= 0.0 && snap.usedFraction <= 1.0 && !snap.usedFraction.isNaN)
        }
    }

    runner.run("MemoryReleaseService non-privileged relief does not invoke elevation and never underflows UInt64") {
        let invoked = LockedBox(false)
        let executor = PrivilegedExecutor(
            safetyGuard: SafetyGuard(selfBundlePath: nil),
            adminShellRunner: { _ in
                invoked.set(true)
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        )
        let service = MemoryReleaseService(privilegedExecutor: executor)
        let res = try runAsync { try await service.releaseMemory(allowElevation: false) }

        try runner.expect(!invoked.get())
        try runner.expect(!res.usedElevation)
        try runner.expect(res.reclaimedEstimateBytes <= res.before.totalBytes)
        try runner.expect(!res.methodUsed.isEmpty)
        try runner.expect(!res.note.isEmpty)
    }

    runner.run("MemoryReleaseService elevated purge invokes /usr/sbin/purge and propagates userCancelled / commandFailed") {
        let captured = LockedBox<String?>(nil)
        let okExec = PrivilegedExecutor(
            safetyGuard: SafetyGuard(selfBundlePath: nil),
            adminShellRunner: { script in
                captured.set(script)
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        )
        let okService = MemoryReleaseService(privilegedExecutor: okExec)
        let okRes = try runAsync { try await okService.releaseMemory(allowElevation: true) }
        try runner.expect(okRes.usedElevation)
        try runner.expect((captured.get() ?? "").contains("/usr/sbin/purge"))

        let cancelExec = PrivilegedExecutor(
            safetyGuard: SafetyGuard(selfBundlePath: nil),
            adminShellRunner: { _ in
                ProcessResult(exitCode: 1, stdout: "", stderr: "User canceled. (-128)")
            }
        )
        var gotCancel = false
        do {
            _ = try runAsync {
                try await MemoryReleaseService(privilegedExecutor: cancelExec).releaseMemory(allowElevation: true)
            }
        } catch let err as PrivilegedError {
            gotCancel = (err == .userCancelled)
        }
        try runner.expect(gotCancel)

        let failExec = PrivilegedExecutor(
            safetyGuard: SafetyGuard(selfBundlePath: nil),
            adminShellRunner: { _ in
                ProcessResult(exitCode: 1, stdout: "", stderr: "purge failed")
            }
        )
        var gotFail = false
        do {
            _ = try runAsync {
                try await MemoryReleaseService(privilegedExecutor: failExec).releaseMemory(allowElevation: true)
            }
        } catch let err as PrivilegedError {
            if case .commandFailed = err { gotFail = true }
        }
        try runner.expect(gotFail)
    }

    runner.run("MemoryReleaseService honors pre-cancelled Task before invoking /usr/sbin/purge") {
        let invoked = LockedBox(false)
        let exec = PrivilegedExecutor(
            safetyGuard: SafetyGuard(selfBundlePath: nil),
            adminShellRunner: { _ in
                invoked.set(true)
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        )
        let service = MemoryReleaseService(privilegedExecutor: exec)
        var threwCancel = false
        do {
            _ = try runAsync {
                let task = Task {
                    try await service.releaseMemory(allowElevation: true)
                }
                task.cancel()
                return try await task.value
            }
        } catch is CancellationError {
            threwCancel = true
        }
        try runner.expect(threwCancel, "Pre-cancelled elevated releaseMemory must throw CancellationError")
        try runner.expect(!invoked.get(), "Pre-cancelled elevated releaseMemory must not invoke adminShellRunner")
    }

    // MARK: - E. RemovalEngine + CleanupHistoryStore + TOCTOU Integration (1 check)

    runner.run("M3 scan -> RemovalEngine -> CleanupHistoryStore preserves retained duplicate and blocks TOCTOU parent swap") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-integration")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let payload = Data(repeating: 0x6D, count: 8192)
        let orig = try createFile(in: sandbox, relativePath: "Documents/orig.dat", data: payload)
        let dup = try createFile(in: sandbox, relativePath: "Downloads/dup.dat", data: payload)
        let parentA = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/ParentA/item.bin", byteCount: 4096, fillByte: 0x41)
        let safeDir = sandbox.appendingPathComponent("SafeDir")
        let decoy = try createExactSizeFile(in: sandbox, relativePath: "SafeDir/item.bin", byteCount: 4096, fillByte: 0x42)

        let mockTrash = sandbox.appendingPathComponent("MockTrash")
        try FileManager.default.createDirectory(at: mockTrash, withIntermediateDirectories: true)
        let historyStore = CleanupHistoryStore(fileURL: sandbox.appendingPathComponent("State/history.json"))
        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)

        let dupScanner = LargeAndDuplicateScanner(safetyGuard: sg)
        let smartGroups = dupScanner.applySmartSelection(
            to: try runAsync { try await dupScanner.scanDuplicates(under: sandbox, minBytes: 1) }
        )
        let dupTargets = smartGroups.flatMap { g in
            g.files.filter(\.isSelected).map {
                RemovalTarget(url: $0.url, estimatedSize: Int64(g.fileSize), expectedCanonicalParent: $0.expectedCanonicalParent)
            }
        }
        try runner.expectEqual(dupTargets.map(\.url.path), [dup.standardizedFileURL.path])

        let engine = RemovalEngine(
            safetyGuard: sg,
            historyStore: historyStore,
            localTrashHandler: { itemURL in
                let dst = mockTrash.appendingPathComponent("\(UUID().uuidString)-\(itemURL.lastPathComponent)")
                try FileManager.default.moveItem(at: itemURL, to: dst)
            }
        )
        let okReport = engine.remove(targets: dupTargets, mode: .trash, actionTitle: "M3 Duplicate Cleanup", allowElevation: false)
        try runner.expect(okReport.isFullSuccess)
        try runner.expect(RemovalEngine.entryExists(orig))
        try runner.expect(!RemovalEngine.entryExists(dup))
        try runner.expectEqual(historyStore.load().first?.freedBytes, 8192)

        // TOCTOU parent swap test
        let expectedParent = PrivilegedExecutor.canonicalParentPath(forTargetURL: parentA)
        let swapDir = parentA.deletingLastPathComponent()
        try FileManager.default.removeItem(at: swapDir)
        try FileManager.default.createSymbolicLink(at: swapDir, withDestinationURL: safeDir)

        let badReport = engine.remove(
            targets: [RemovalTarget(url: parentA, estimatedSize: 4096, expectedCanonicalParent: expectedParent)],
            mode: .permanent,
            allowElevation: false
        )
        try runner.expect(!badReport.isFullSuccess)
        try runner.expect(RemovalEngine.entryExists(decoy))
    }

    // MARK: - F. Tier-5 Adversarial Regressions (Core Bugs 3, 4c, 5, 6 & Missing Option Paths)

    runner.run("JunkCacheScanner excludes 0o000 TCC-blocked Chrome and Arc from userCaches while reporting needsFullDiskAccess") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-tcc-browser")
        let fm = FileManager.default
        let chromeDir = sandbox.appendingPathComponent("Library/Caches/Google/Chrome")
        let arcDir = sandbox.appendingPathComponent("Library/Caches/Arc")
        let normalCache = sandbox.appendingPathComponent("Library/Caches/com.acme.OpenApp")
        try fm.createDirectory(at: chromeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: arcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: normalCache, withIntermediateDirectories: true)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/Google/Chrome/data.bin", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/Arc/data.bin", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/com.acme.OpenApp/ok.bin", byteCount: 4096)

        try runner.expectEqual(Darwin.chmod(chromeDir.path, 0o000), 0)
        try runner.expectEqual(Darwin.chmod(arcDir.path, 0o000), 0)
        defer {
            _ = Darwin.chmod(chromeDir.path, 0o755)
            _ = Darwin.chmod(arcDir.path, 0o755)
            try? fm.removeItem(at: sandbox)
        }

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)
        let scanner = JunkCacheScanner(safetyGuard: sg, homeDirectory: sandbox, runningBundleIDs: [], runningAppNames: [])
        let result = try runAsync { try await scanner.scanAll() }

        try runner.expect(result.needsFullDiskAccess, "0o000 browser caches must set needsFullDiskAccess=true")
        try runner.expect(result.blockedLocations.contains("Google Chrome"), "blockedLocations must include Google Chrome")
        try runner.expect(result.blockedLocations.contains("Arc"), "blockedLocations must include Arc")

        let userEntries = result.categories.first(where: { $0.category == .userCaches })?.entries ?? []
        try runner.expect(!userEntries.contains(where: { $0.name == "Chrome" || $0.name == "Arc" }), "TCC-blocked Chrome/Arc must NOT leak into .userCaches")
        try runner.expect(userEntries.contains(where: { $0.name == "com.acme.OpenApp" }))
    }

    runner.run("JunkCacheScanner enforces runningBundleIDs, Xcode DeviceSupport unchecked, CoreSimulator running block, and onProgress") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-junk-opts")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Caches/com.example.App/c.bin", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Developer/Xcode/iOS DeviceSupport/18.0/Symbols.dat", byteCount: 4096)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Library/Developer/CoreSimulator/Caches/dyld/cache.bin", byteCount: 4096)

        let progressCount = LockedBox(0)
        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)
        let env = JunkScannerEnvironment(
            homeDirectory: sandbox,
            systemLogsDirectory: sandbox.appendingPathComponent("SysLogs"),
            trashDirectory: sandbox.appendingPathComponent(".Trash"),
            runningBundleIDs: ["com.example.App", "com.apple.iphonesimulator"],
            runningAppNames: ["Simulator"],
            includeSystemLogs: false
        )
        let scanner = JunkCacheScanner(safetyGuard: sg, environment: env, progressThrottleInterval: 0.0)
        let cats = try runAsync {
            try await scanner.scan { _ in
                progressCount.set(progressCount.get() + 1)
            }
        }
        try runner.expect(progressCount.get() > 0, "onProgress must be invoked")

        let userEntries = cats.first(where: { $0.category == .userCaches })?.entries ?? []
        let appCache = userEntries.first(where: { $0.name == "com.example.App" })
        try runner.expectEqual(appCache?.isRunningAppBlocked, true)
        try runner.expectEqual(appCache?.isSelected, false)

        let devEntries = cats.first(where: { $0.category == .developerCaches })?.entries ?? []
        let devSupport = devEntries.first(where: { $0.subgroup == "Xcode iOS DeviceSupport" })
        let simCache = devEntries.first(where: { $0.subgroup == "CoreSimulator Caches" })
        try runner.expectEqual(devSupport?.isSelected, false, "Xcode DeviceSupport must be unchecked by default")
        try runner.expectEqual(simCache?.isRunningAppBlocked, true, "Running Simulator must block CoreSimulator Caches")
        try runner.expectEqual(simCache?.isSelected, false)
    }

    runner.run("LargeAndDuplicateScanner includePackages deduplicates hardlinks, filters categories, honors olderThanDays 0 parity, and matches bulkOnly vs fallbackOnly") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-large-pkg-hl")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let appMacOS = sandbox.appendingPathComponent("Scan/Big.app/Contents/MacOS")
        try fm.createDirectory(at: appMacOS, withIntermediateDirectories: true)
        let binA = appMacOS.appendingPathComponent("a")
        let binB = appMacOS.appendingPathComponent("b")
        try Data(repeating: 0x41, count: 30_000).write(to: binA)
        try fm.linkItem(at: binA, to: binB)

        let vid = try createExactSizeFile(in: sandbox, relativePath: "Scan/movie.mp4", byteCount: 60_000)
        _ = try createExactSizeFile(in: sandbox, relativePath: "Scan/archive.zip", byteCount: 60_000)

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)
        let bulkScanner = LargeAndDuplicateScanner(safetyGuard: sg, enumerationMode: .bulkOnly)
        let fallbackScanner = LargeAndDuplicateScanner(safetyGuard: sg, enumerationMode: .fallbackOnly)

        // 1. Hardlink deduplication inside Big.app keeps it below 50_000 bytes
        let pkgItems = try runAsync {
            try await bulkScanner.scanLargeFiles(
                under: sandbox.appendingPathComponent("Scan"),
                minBytes: 50_000,
                includePackages: true
            )
        }
        try runner.expect(!pkgItems.contains(where: { $0.name == "Big.app" }), "Hardlinked 2x30KB inside Big.app must deduplicate below 50KB")

        // 2. Category filtering + olderThanDays: 0 parity with DiskSpaceAnalyzer
        let futureDate = Date().addingTimeInterval(3600)
        try fm.setAttributes([.modificationDate: futureDate], ofItemAtPath: vid.path)
        let videoOnly = try runAsync {
            try await bulkScanner.scanLargeFiles(
                under: sandbox.appendingPathComponent("Scan"),
                options: LargeFileScanOptions(minBytes: 50_000, olderThanDays: 0, categories: [.video]),
                referenceDate: Date()
            )
        }
        try runner.expectEqual(videoOnly.map(\.name), ["movie.mp4"], "categories: [.video] + olderThanDays: 0 must include future-dated video (no age filter)")

        let fallbackVideo = try runAsync {
            try await fallbackScanner.scanLargeFiles(
                under: sandbox.appendingPathComponent("Scan"),
                options: LargeFileScanOptions(minBytes: 50_000, olderThanDays: 0, categories: [.video]),
                referenceDate: Date()
            )
        }
        try runner.expectEqual(fallbackVideo.map(\.url.path), videoOnly.map(\.url.path), "bulkOnly and fallbackOnly large files must match")
    }

    runner.run("LargeAndDuplicateScanner duplicate options: includeZeroByteFiles, includeHiddenFiles, keepShortestPath, clearAll, enforceKeepOne false, and bulk/fallback parity") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-dup-opts")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        _ = try createFile(in: sandbox, relativePath: "EmptyA.txt", data: Data())
        _ = try createFile(in: sandbox, relativePath: "EmptyB.txt", data: Data())
        _ = try createFile(in: sandbox, relativePath: ".hiddenA.dat", data: Data(repeating: 0x55, count: 512))
        _ = try createFile(in: sandbox, relativePath: ".hiddenB.dat", data: Data(repeating: 0x55, count: 512))
        _ = try createFile(in: sandbox, relativePath: "Short.dat", data: Data(repeating: 0x77, count: 1024))
        _ = try createFile(in: sandbox, relativePath: "Sub/VeryLongDirectoryName/LongerPath.dat", data: Data(repeating: 0x77, count: 1024))

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)
        let bulk = LargeAndDuplicateScanner(safetyGuard: sg, enumerationMode: .bulkOnly)
        let fallback = LargeAndDuplicateScanner(safetyGuard: sg, enumerationMode: .fallbackOnly)

        let optsZeroHidden = DuplicateScanOptions(minBytes: 0, includeZeroByteFiles: true, includeHiddenFiles: true)
        let bulkGroups = try runAsync { try await bulk.scanDuplicates(under: sandbox, options: optsZeroHidden) }
        let fallbackGroups = try runAsync { try await fallback.scanDuplicates(under: sandbox, options: optsZeroHidden) }
        try runner.expectEqual(bulkGroups.count, 3, "Expected 3 groups (zero-byte, hidden, normal)")
        try runner.expectEqual(bulkGroups.map(\.sha256Hex), fallbackGroups.map(\.sha256Hex))

        let noHiddenOpts = DuplicateScanOptions(minBytes: 1, includeZeroByteFiles: false, includeHiddenFiles: false)
        let noHiddenGroups = try runAsync { try await bulk.scanDuplicates(under: sandbox, options: noHiddenOpts) }
        try runner.expectEqual(noHiddenGroups.count, 1)

        // keepShortestPath
        let shortest = bulk.applySmartSelection(to: noHiddenGroups, preset: .keepShortestPath)
        let keptShortest = shortest[0].files.filter { !$0.isSelected }
        try runner.expectEqual(keptShortest.map(\.name), ["Short.dat"])

        // clearAll
        let cleared = bulk.applySmartSelection(to: noHiddenGroups, preset: .clearAll)
        try runner.expectEqual(cleared[0].selectedCount, 0)

        // enforceKeepOne: false allows selecting all copies
        var allSelected = noHiddenGroups[0]
        for file in noHiddenGroups[0].files {
            allSelected = allSelected.settingSelection(true, forEntryID: file.id, enforceKeepOne: false)
        }
        try runner.expect(allSelected.allCopiesSelected, "enforceKeepOne: false must allow all copies to be selected")
    }

    runner.run("MemoryReleaseService mach_host_self refcount stays constant across 100 calls, handles positive/negative deltas, and honors purge cancellation") {
        let service = MemoryReleaseService()
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }

        var refsBefore: mach_port_urefs_t = 0
        try runner.expectEqual(mach_port_get_refs(mach_task_self_, hostPort, MACH_PORT_RIGHT_SEND, &refsBefore), KERN_SUCCESS)
        for _ in 0..<100 {
            _ = service.captureSnapshot()
        }
        var refsAfter: mach_port_urefs_t = 0
        try runner.expectEqual(mach_port_get_refs(mach_task_self_, hostPort, MACH_PORT_RIGHT_SEND, &refsAfter), KERN_SUCCESS)
        try runner.expectEqual(refsAfter, refsBefore, "captureSnapshot() must not leak mach_host_self() send rights")

        // Positive and negative freeBytes delta via snapshotProvider
        final class CounterBox: @unchecked Sendable {
            private let lock = NSLock()
            var count = 0
            func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
        }
        let posCounter = CounterBox()
        let posService = MemoryReleaseService(
            snapshotProvider: {
                let idx = posCounter.next()
                return MemorySnapshot(
                    totalBytes: 16_000_000_000,
                    activeBytes: 4_000_000_000,
                    inactiveBytes: 2_000_000_000,
                    wiredBytes: 2_000_000_000,
                    compressedBytes: 1_000_000_000,
                    cachedFilesBytes: idx == 0 ? 3_000_000_000 : 1_000_000_000,
                    appMemoryBytes: 3_000_000_000,
                    freeBytes: idx == 0 ? 1_000_000_000 : 2_500_000_000,
                    swapUsedBytes: 0,
                    swapTotalBytes: 2_000_000_000,
                    pageSizeBytes: 16_384,
                    pressureLevel: .normal
                )
            },
            standardReliefHandler: {}
        )
        let posRes = try runAsync { await posService.performStandardRelief() }
        try runner.expectEqual(posRes.reclaimedEstimateBytes, 1_500_000_000)

        let negCounter = CounterBox()
        let negService = MemoryReleaseService(
            snapshotProvider: {
                let idx = negCounter.next()
                return MemorySnapshot(
                    totalBytes: 16_000_000_000,
                    activeBytes: 4_000_000_000,
                    inactiveBytes: 2_000_000_000,
                    wiredBytes: 2_000_000_000,
                    compressedBytes: 1_000_000_000,
                    cachedFilesBytes: 2_000_000_000,
                    appMemoryBytes: 3_000_000_000,
                    freeBytes: idx == 0 ? 2_500_000_000 : 1_000_000_000,
                    swapUsedBytes: 0,
                    swapTotalBytes: 2_000_000_000,
                    pageSizeBytes: 16_384,
                    pressureLevel: .normal
                )
            },
            standardReliefHandler: {}
        )
        let negRes = try runAsync { await negService.performStandardRelief() }
        try runner.expectEqual(negRes.reclaimedEstimateBytes, 0, "Negative freeBytes delta must clamp reclaimedEstimateBytes to 0")

        // Mid-flight cancellation during performElevatedPurge sleep
        let midService = MemoryReleaseService(
            snapshotProvider: {
                MemorySnapshot(
                    totalBytes: 16_000_000_000, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0,
                    compressedBytes: 0, cachedFilesBytes: 0, appMemoryBytes: 0, freeBytes: 0,
                    swapUsedBytes: 0, swapTotalBytes: 0, pageSizeBytes: 16_384, pressureLevel: .normal
                )
            },
            elevatedPurgeHandler: {}
        )
        var midCancelled = false
        do {
            _ = try runAsync {
                let t = Task { try await midService.performElevatedPurge() }
                try? await Task.sleep(nanoseconds: 50_000_000)
                t.cancel()
                return try await t.value
            }
        } catch is CancellationError {
            midCancelled = true
        }
        try runner.expect(midCancelled, "Mid-flight cancel during performElevatedPurge must throw CancellationError")
    }

    runner.run("LargeAndDuplicateScanner Stage 2/3 cancellation and mid-scan file-size mutation resilience") {
        let sandbox = try runner.makeTempSandbox(prefix: "m3-stage23-race")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let payload = Data(repeating: 0x3A, count: 16_384)
        let fA = try createFile(in: sandbox, relativePath: "a.bin", data: payload)
        let fB = try createFile(in: sandbox, relativePath: "b.bin", data: payload)
        _ = try createFile(in: sandbox, relativePath: "c.bin", data: payload)

        // 1. Mutate fB's size during Stage 2 (.duplicatesPartialHash) -> fB must be dropped, only a & c remain
        final class MutateBox: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            let url: URL
            init(url: URL) { self.url = url }
            func trigger() {
                let shouldMutate = lock.withLock { () -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if shouldMutate {
                    try? Data(repeating: 0x3A, count: 17_000).write(to: url)
                }
            }
        }
        let mutator = MutateBox(url: fB)
        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)
        let scanner = LargeAndDuplicateScanner(safetyGuard: sg, progressThrottleInterval: 0.01)
        let opts = DuplicateScanOptions(minBytes: 1024, partialHashChunkBytes: 512)

        let groups = try runAsync {
            try await scanner.scanDuplicates(under: sandbox, options: opts) { prog in
                if prog.stage == .duplicatesPartialHash {
                    mutator.trigger()
                }
            }
        }
        try runner.expectEqual(groups.count, 1)
        let remainingPaths = Set(groups[0].files.map(\.url.path))
        try runner.expect(remainingPaths.contains(fA.standardizedFileURL.path))
        try runner.expect(!remainingPaths.contains(fB.standardizedFileURL.path), "Size-mutated file must not be grouped as duplicate")

        // 2. Cancel during Stage 3 (.duplicatesFullHash)
        let cancelFlagBox = LockedBox<Task<[DuplicateGroup], Error>?>(nil)
        var threwStage3Cancel = false
        do {
            _ = try runAsync {
                let task = Task {
                    try await scanner.scanDuplicates(under: sandbox, options: opts) { prog in
                        if prog.stage == .duplicatesFullHash {
                            cancelFlagBox.get()?.cancel()
                        }
                    }
                }
                cancelFlagBox.set(task)
                return try await task.value
            }
        } catch is CancellationError {
            threwStage3Cancel = true
        }
        try runner.expect(threwStage3Cancel, "Stage 3 cancellation via onProgress must throw CancellationError")
    }

    runner.run("Audit regression: SF_NOUNLINK (/Applications) is not pruned or rejected during scans while /System (SF_RESTRICTED) stays blocked") {
        let sg = SafetyGuard(selfBundlePath: nil)
        let appsURL = URL(fileURLWithPath: "/Applications")
        let systemURL = URL(fileURLWithPath: "/System")

        try runner.expect(sg.isSIPRestricted(appsURL), "/Applications carries SF_NOUNLINK so removal guard must remain true")
        try runner.expect(!sg.isSIPRestrictedForTraversal(appsURL), "SF_NOUNLINK on /Applications must not block directory traversal")
        try runner.expect(!sg.shouldPruneDirectoryScan(at: appsURL), "shouldPruneDirectoryScan must allow descending into /Applications")
        try runner.expect(sg.isSIPRestrictedForTraversal(systemURL), "/System carries SF_RESTRICTED and must remain traversal-blocked")
        try runner.expect(sg.shouldPruneDirectoryScan(at: systemURL), "shouldPruneDirectoryScan must prune /System")

        let scanner = LargeAndDuplicateScanner(safetyGuard: sg)
        let largeInApps = try runAsync {
            try await scanner.scanLargeFiles(under: appsURL, minBytes: UInt64.max / 2)
        }
        try runner.expect(largeInApps.isEmpty, "Scanning /Applications with huge threshold must succeed without throwing permissionDenied")

        var blockedSystem = false
        do {
            _ = try runAsync {
                try await scanner.scanLargeFiles(under: systemURL, minBytes: UInt64.max / 2)
            }
        } catch DiskScanError.permissionDenied {
            blockedSystem = true
        }
        try runner.expect(blockedSystem, "Scanning /System must still throw DiskScanError.permissionDenied")
    }
}

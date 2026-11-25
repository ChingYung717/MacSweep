import Darwin
import E2EHarness
import Foundation
import MacSweepCore

let runner = E2ERunner(probeName: "E2EBaselineProbe")

// MARK: - Tier 1 Baseline Tests (8)

runner.register(
    id: "baseline-sg-allow-sandbox",
    tier: 1,
    feature: "BASE-SG",
    name: "SafetyGuard allows benign sandbox files and treats them as non-protected"
) {
    let sandbox = try E2ESandbox(prefix: "base-sg-allow")
    defer { sandbox.cleanup() }

    let file = try sandbox.createFile("Work/cache.dat", utf8: "cache-payload")
    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)

    try E2ERunner.expectEqual(sg.validateForRemoval(file), .allowed)
    try E2ERunner.expect(!sg.isUserProtected(bundleID: nil, url: file), "Sandbox file should not be user protected")
}

runner.register(
    id: "baseline-sg-block-system",
    tier: 1,
    feature: "BASE-SG",
    name: "SafetyGuard blocks root, system paths, self bundle, and self data paths"
) {
    let sandbox = try E2ESandbox(prefix: "base-sg-block")
    defer { sandbox.cleanup() }

    _ = try sandbox.createDirectory("Library/Application Support/MacSweep")
    let selfData = sandbox.url("Library/Application Support/MacSweep")
    let sandboxLib = sandbox.url("Library")
    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: "/Applications/MacSweep.app")

    let blockedPaths = [
        "/",
        "/System",
        "/Library/Apple",
        "/usr/bin/ls",
        "/Applications",
        sandbox.rootURL.path,
        sandboxLib.path,
        selfData.path,
        "/Applications/MacSweep.app",
    ]

    for path in blockedPaths {
        let result = sg.validateForRemoval(URL(fileURLWithPath: path))
        try E2ERunner.expect(!result.isAllowed, "Expected SafetyGuard to block \(path)")
    }

    try E2ERunner.expect(
        sg.isSystemProtectedApp(at: URL(fileURLWithPath: "/System")),
        "/System should be identified as system-protected"
    )
}

runner.register(
    id: "baseline-rm-trash-and-history",
    tier: 1,
    feature: "BASE-RM",
    name: "RemovalEngine .trash mode delegates to localTrashHandler and logs CleanupRecord"
) {
    let sandbox = try E2ESandbox(prefix: "base-rm-trash")
    defer { sandbox.cleanup() }

    let file = try sandbox.createExactSizeFile("Work/trash-me.dat", byteCount: 128)
    let mockTrash = try sandbox.createDirectory("MockTrash")
    let historyURL = sandbox.url("State/history.json")
    let historyStore = CleanupHistoryStore(fileURL: historyURL)
    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)

    let engine = RemovalEngine(
        safetyGuard: sg,
        historyStore: historyStore,
        localTrashHandler: { itemURL in
            let dst = mockTrash.appendingPathComponent(itemURL.lastPathComponent)
            try FileManager.default.moveItem(at: itemURL, to: dst)
        }
    )

    let target = RemovalTarget(url: file, estimatedSize: 128)
    let expectedURL = file.standardizedFileURL
    let report = engine.remove(
        targets: [target],
        mode: .trash,
        actionTitle: "Baseline Trash Test",
        allowElevation: false
    )

    try E2ERunner.expect(report.isFullSuccess, "Expected full success, failures: \(report.failures)")
    try E2ERunner.expectEqual(report.succeededURLs, [expectedURL])
    try E2ERunner.expectEqual(report.freedBytes, 128)
    try E2ERunner.expect(!RemovalEngine.entryExists(file), "Original file should no longer exist")
    try E2ERunner.expect(
        RemovalEngine.entryExists(mockTrash.appendingPathComponent(file.lastPathComponent)),
        "File should exist inside MockTrash"
    )

    let records = historyStore.load()
    try E2ERunner.expectEqual(records.count, 1)
    let first = try E2ERunner.expectNotNil(records.first)
    try E2ERunner.expectEqual(first.mode, .trash)
    try E2ERunner.expectEqual(first.actionTitle, "Baseline Trash Test")
    try E2ERunner.expectEqual(first.removedPaths, [expectedURL.path])
}

runner.register(
    id: "baseline-rm-permanent-uchg",
    tier: 1,
    feature: "BASE-RM",
    name: "RemovalEngine .permanent unlocks user-immutable (uchg) file inside target directory"
) {
    let sandbox = try E2ESandbox(prefix: "base-rm-uchg")
    defer { sandbox.cleanup() }

    let dir = try sandbox.createDirectory("Work/ImmutableDir")
    let file = try sandbox.createFile("Work/ImmutableDir/locked.txt", utf8: "locked-content")
    try sandbox.setUserImmutable(file, locked: true)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    try E2ERunner.expect(sg.isUserImmutable(file), "File should report UF_IMMUTABLE")
    try E2ERunner.expect(!sg.isSIPRestricted(file), "User uchg must not be misclassified as SIP")
    try E2ERunner.expectEqual(sg.validateForRemoval(dir), .allowed)

    let engine = RemovalEngine(safetyGuard: sg)
    let report = engine.remove(
        targets: [RemovalTarget(url: dir, estimatedSize: 14)],
        mode: .permanent,
        actionTitle: "Unlock uchg",
        allowElevation: false
    )

    try E2ERunner.expect(report.isFullSuccess, "Expected permanent removal of uchg dir to succeed: \(report.failures)")
    try E2ERunner.expect(!RemovalEngine.entryExists(dir), "Target directory should be removed")
}

runner.register(
    id: "baseline-prefs-roundtrip",
    tier: 1,
    feature: "BASE-PREFS",
    name: "PreferencesStore roundtrips non-default SweepPreferences with 0600 permissions"
) {
    let sandbox = try E2ESandbox(prefix: "base-prefs-rt")
    defer { sandbox.cleanup() }

    let prefsURL = sandbox.url("Config/preferences.json")
    let store = PreferencesStore(fileURL: prefsURL)
    let custom = SweepPreferences(
        themeMode: .system,
        language: .en,
        defaultRemovalMode: .permanent,
        showSystemApps: true,
        includeUtilitiesFolder: true,
        protectedBundleIDs: ["com.example.keep"],
        protectedPaths: ["/tmp/keep"],
        ignoredLeftoverIDs: ["old.id"]
    )

    let saved = store.save(custom)
    try E2ERunner.expect(saved, "PreferencesStore.save should succeed")
    try E2ERunner.expect(!store.isWriteBlockedDueToLoadError, "Write block should remain false")

    let reloadedStore = PreferencesStore(fileURL: prefsURL)
    let loaded = reloadedStore.load()
    try E2ERunner.expectEqual(loaded, custom)

    var st = stat()
    try E2ERunner.expectEqual(Darwin.lstat(prefsURL.path, &st), 0)
    try E2ERunner.expectEqual(st.st_mode & 0o777, mode_t(0o600), "Preferences file mode must be 0600")
}

runner.register(
    id: "baseline-history-100-cap",
    tier: 1,
    feature: "BASE-HIST",
    name: "CleanupHistoryStore enforces 100-record cap keeping newest entries first"
) {
    let sandbox = try E2ESandbox(prefix: "base-hist-cap")
    defer { sandbox.cleanup() }

    let historyURL = sandbox.url("State/history.json")
    let store = CleanupHistoryStore(fileURL: historyURL)

    for i in 0..<105 {
        let record = CleanupRecord(
            actionTitle: "Action \(i)",
            mode: .trash,
            itemCount: 1,
            freedBytes: Int64(i * 10),
            removedPaths: ["/tmp/item-\(i)"]
        )
        let ok = store.append(record)
        try E2ERunner.expect(ok, "Append \(i) should succeed")
    }

    let records = store.load()
    try E2ERunner.expectEqual(records.count, 100)
    try E2ERunner.expectEqual(records.first?.actionTitle, "Action 104")
    try E2ERunner.expectEqual(records.last?.actionTitle, "Action 5")
}

runner.register(
    id: "baseline-safereader-bounded",
    tier: 1,
    feature: "BASE-READER",
    name: "SafeFileReader reads bounded regular files, UTF-8 strings, and prefixes accurately"
) {
    let sandbox = try E2ESandbox(prefix: "base-reader-ok")
    defer { sandbox.cleanup() }

    let payload = "Hello MacSweep SafeFileReader 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    let file = try sandbox.createFile("sample.txt", utf8: payload)
    let missing = sandbox.url("missing.txt")

    let detail = SafeFileReader.readBoundedRegularFileDetailed(at: file, maxBytes: 1024)
    try E2ERunner.expectEqual(detail, .success(Data(payload.utf8)))
    try E2ERunner.expectEqual(SafeFileReader.readBoundedRegularFileDetailed(at: missing), .notFound)
    try E2ERunner.expectEqual(SafeFileReader.readBoundedUTF8String(at: file, maxBytes: 1024), payload)

    let prefix = try E2ERunner.expectNotNil(SafeFileReader.readBoundedPrefix(at: file, maxBytes: 16))
    try E2ERunner.expectEqual(prefix.data.count, 16)
    try E2ERunner.expect(prefix.isTruncated, "Prefix read of 16 bytes should report isTruncated = true")
    try E2ERunner.expectEqual(prefix.totalSize, Int64(payload.utf8.count))
}

runner.register(
    id: "baseline-sizer-totals-cache",
    tier: 1,
    feature: "BASE-SIZER",
    name: "DirectorySizer computes recursive totals, caches results, and supports invalidation"
) {
    let sandbox = try E2ESandbox(prefix: "base-sizer-cache")
    defer { sandbox.cleanup() }

    let targetDir = try sandbox.createDirectory("Tree")
    _ = try sandbox.createExactSizeFile("Tree/a.bin", byteCount: 4096)
    _ = try sandbox.createExactSizeFile("Tree/b.bin", byteCount: 4096)
    _ = try sandbox.createExactSizeFile("Tree/c.bin", byteCount: 4096)
    _ = try sandbox.createExactSizeFile("Tree/Sub/d.bin", byteCount: 8192)

    let sizer = DirectorySizer()
    let measurement = await sizer.measure(of: targetDir)
    try E2ERunner.expectEqual(measurement.bytes, 20_480)
    try E2ERunner.expectEqual(measurement.fileCount, 4)
    try E2ERunner.expectEqual(measurement.folderCount, 1)
    try E2ERunner.expect(!measurement.isTruncated)

    let cachedBefore = await sizer.isCached(path: targetDir.path)
    try E2ERunner.expect(cachedBefore, "DirectorySizer should cache non-truncated measurement")

    await sizer.invalidate(path: targetDir.standardizedFileURL.path)
    let cachedAfter = await sizer.isCached(path: targetDir.path)
    try E2ERunner.expect(!cachedAfter, "DirectorySizer cache entry should be cleared after invalidate")

    let sizeMap = await sizer.sizes(of: [targetDir])
    try E2ERunner.expectEqual(sizeMap[targetDir.standardizedFileURL.path], 20_480)
}

// MARK: - Tier 2 Boundary & Corner Cases (8)

runner.register(
    id: "baseline-sg-protected-boundaries",
    tier: 2,
    feature: "BASE-SG",
    name: "SafetyGuard enforces protectedPaths, symlinks to protected dirs, protectedBundleIDs, Photos, and invalid URLs"
) {
    let sandbox = try E2ESandbox(prefix: "base-sg-prot")
    defer { sandbox.cleanup() }

    let protDir = try sandbox.createDirectory("ProtectedFolder")
    let protChild = try sandbox.createFile("ProtectedFolder/child.txt", utf8: "secret")
    let linkToProt = try sandbox.createSymlink(atRelativePath: "Work/link-to-prot", targetURL: protDir)
    let bundleCache = try sandbox.createDirectory("Library/Caches/com.example.keep")
    let photosDB = try sandbox.createFile("Pics.photoslibrary/db.sqlite", utf8: "sqlite")

    let sg = SafetyGuard(
        homeDirectory: sandbox.rootURL,
        selfBundlePath: nil,
        protectedPaths: [protDir.path],
        protectedBundleIDs: ["com.example.keep"]
    )

    try E2ERunner.expect(!sg.validateForRemoval(protDir).isAllowed, "protectedPaths dir must be blocked")
    try E2ERunner.expect(!sg.validateForRemoval(protChild).isAllowed, "child of protectedPaths dir must be blocked")
    try E2ERunner.expect(!sg.validateForRemoval(linkToProt).isAllowed, "symlink into protectedPaths must be blocked")
    try E2ERunner.expect(!sg.validateForRemoval(bundleCache).isAllowed, "protectedBundleIDs cache must be blocked")
    try E2ERunner.expect(!sg.validateForRemoval(photosDB).isAllowed, "Photos library contents must be blocked")

    let httpURL = try E2ERunner.expectNotNil(URL(string: "https://example.com/a"))
    try E2ERunner.expect(!sg.validateForRemoval(httpURL).isAllowed, "Non-file URL must be blocked")

    let nulURL = try E2ERunner.expectNotNil(URL(string: "file:///tmp/bad%00name"))
    try E2ERunner.expect(!sg.validateForRemoval(nulURL).isAllowed, "Percent-encoded NUL URL must be blocked")
}

runner.register(
    id: "baseline-sg-system-symlink-vendor",
    tier: 2,
    feature: "BASE-SG",
    name: "SafetyGuard blocks symlinks to /System and bare shared vendor cache dirs while allowing specific app caches"
) {
    let sandbox = try E2ESandbox(prefix: "base-sg-vendor")
    defer { sandbox.cleanup() }

    let sysLink = try sandbox.createSymlink(atRelativePath: "Work/sys-link", targetPath: "/System")
    let adobeCache = try sandbox.createDirectory("Library/Caches/Adobe")
    let acmeCache = try sandbox.createDirectory("Library/Caches/com.acme.Widget")

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)

    try E2ERunner.expect(sg.pointsToSystemVolume(sysLink), "Symlink to /System should set pointsToSystemVolume")
    try E2ERunner.expect(!sg.validateForRemoval(sysLink).isAllowed, "Symlink to /System must be blocked")

    try E2ERunner.expect(sg.isCriticalSharedDirectory(adobeCache.path), "Adobe cache vendor dir should be critical shared")
    try E2ERunner.expect(!sg.validateForRemoval(adobeCache).isAllowed, "Bare vendor cache dir must be blocked")

    try E2ERunner.expectEqual(sg.validateForRemoval(acmeCache), .allowed)
}

runner.register(
    id: "baseline-rm-toctou-parent-swap",
    tier: 2,
    feature: "BASE-RM",
    name: "RemovalEngine blocks TOCTOU parent directory symlink swap in both .permanent and .trash modes"
) {
    let sandbox = try E2ESandbox(prefix: "base-rm-toctou")
    defer { sandbox.cleanup() }

    let parentA = try sandbox.createDirectory("Work/ParentA")
    let victimA = try sandbox.createExactSizeFile("Work/ParentA/victim.dat", byteCount: 64)
    let decoyDir = try sandbox.createDirectory("Work/DecoyDir")
    let decoyVictim = try sandbox.createExactSizeFile("Work/DecoyDir/victim.dat", byteCount: 64)

    // Capture scan-time RemovalTarget BEFORE parent swap.
    let capturedTarget = RemovalTarget(url: victimA, estimatedSize: 64)

    // Swap ParentA for a symlink pointing to DecoyDir.
    try FileManager.default.removeItem(at: parentA)
    try FileManager.default.createSymbolicLink(at: parentA, withDestinationURL: decoyDir)

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let engine = RemovalEngine(
        safetyGuard: sg,
        localTrashHandler: { _ in
            throw E2EAssertionFailure("localTrashHandler should never be invoked on TOCTOU mismatch")
        }
    )

    for mode in [RemovalMode.permanent, RemovalMode.trash] {
        let report = engine.remove(targets: [capturedTarget], mode: mode, allowElevation: false)
        try E2ERunner.expect(!report.isFullSuccess, "TOCTOU swap must fail for mode \(mode)")
        try E2ERunner.expect(report.succeededURLs.isEmpty, "No target should succeed on TOCTOU swap")
        let reason = report.failures.first?.reason ?? ""
        try E2ERunner.expectContains(reason, "TOCTOU", "Failure reason should mention TOCTOU")
        try E2ERunner.expect(RemovalEngine.entryExists(decoyVictim), "Decoy victim must remain untouched")
    }
}

runner.register(
    id: "baseline-rm-symlink-fifo-mixed",
    tier: 2,
    feature: "BASE-RM",
    name: "RemovalEngine safely unlinks symlinks and FIFOs in mixed batch without touching symlink targets or blocking"
) {
    let sandbox = try E2ESandbox(prefix: "base-rm-mixed")
    defer { sandbox.cleanup() }

    let precious = try sandbox.createFile("Keep/precious.txt", utf8: "do-not-delete")
    let symlink = try sandbox.createSymlink(atRelativePath: "Work/alias.txt", targetURL: precious)
    let fifo = try sandbox.createFIFO(atRelativePath: "Work/pipe.fifo")
    let regular = try sandbox.createExactSizeFile("Work/normal.bin", byteCount: 256)
    let blocked = URL(fileURLWithPath: "/System")

    let historyStore = CleanupHistoryStore(fileURL: sandbox.url("State/history.json"))
    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let engine = RemovalEngine(safetyGuard: sg, historyStore: historyStore)

    let expectedSymlinkURL = symlink.standardizedFileURL
    let expectedFifoURL = fifo.standardizedFileURL
    let expectedRegularURL = regular.standardizedFileURL
    let expectedBlockedURL = blocked.standardizedFileURL

    let targets = [
        RemovalTarget(url: symlink, estimatedSize: 0),
        RemovalTarget(url: fifo, estimatedSize: 0),
        RemovalTarget(url: regular, estimatedSize: 256),
        RemovalTarget(url: blocked, estimatedSize: 0),
    ]

    let start = Date()
    let report = engine.remove(targets: targets, mode: .permanent, actionTitle: "Mixed Batch", allowElevation: false)
    let elapsed = Date().timeIntervalSince(start)

    try E2ERunner.expect(elapsed < 1.0, "Mixed FIFO/symlink removal should complete in < 1.0s (took \(elapsed)s)")
    try E2ERunner.expectEqual(report.succeededURLs.count, 3)
    try E2ERunner.expect(report.succeededURLs.contains(expectedSymlinkURL))
    try E2ERunner.expect(report.succeededURLs.contains(expectedFifoURL))
    try E2ERunner.expect(report.succeededURLs.contains(expectedRegularURL))
    try E2ERunner.expectEqual(report.failures.count, 1)
    try E2ERunner.expectEqual(report.failures.first?.url, expectedBlockedURL)
    try E2ERunner.expect(RemovalEngine.entryExists(precious), "Symlink target must remain intact")

    let records = historyStore.load()
    try E2ERunner.expectEqual(records.first?.itemCount, 3)
}

runner.register(
    id: "baseline-prefs-corrupt-oversized",
    tier: 2,
    feature: "BASE-PREFS",
    name: "PreferencesStore refuses overwrite and preserves original bytes on corrupt or oversized JSON"
) {
    let sandbox = try E2ESandbox(prefix: "base-prefs-corrupt")
    defer { sandbox.cleanup() }

    // (a) Corrupt JSON
    let corruptURL = try sandbox.createCorruptJSON(atRelativePath: "Config/corrupt-prefs.json", variant: .truncated)
    let originalBytes = try Data(contentsOf: corruptURL)
    let corruptStore = PreferencesStore(fileURL: corruptURL)
    let loadedCorrupt = corruptStore.load()
    try E2ERunner.expectEqual(loadedCorrupt, SweepPreferences())
    try E2ERunner.expect(corruptStore.isWriteBlockedDueToLoadError, "Corrupt prefs should set write block")
    try E2ERunner.expect(!corruptStore.save(SweepPreferences()), "Save must refuse when write-blocked")
    try E2ERunner.expectEqual(try Data(contentsOf: corruptURL), originalBytes, "Corrupt bytes must remain preserved")

    // (b) Oversized > 1 MiB JSON
    let oversizedURL = try sandbox.createOversizedJSON(atRelativePath: "Config/oversized-prefs.json", exceedingBytes: 1_100_000)
    let oversizedAttrs = try FileManager.default.attributesOfItem(atPath: oversizedURL.path)
    let oversizedCount = oversizedAttrs[.size] as? NSNumber
    let oversizedStore = PreferencesStore(fileURL: oversizedURL)
    _ = oversizedStore.load()
    try E2ERunner.expect(oversizedStore.isWriteBlockedDueToLoadError, "Oversized prefs should set write block")
    try E2ERunner.expect(!oversizedStore.save(SweepPreferences()), "Save must refuse on oversized file")
    let afterAttrs = try FileManager.default.attributesOfItem(atPath: oversizedURL.path)
    try E2ERunner.expectEqual(afterAttrs[.size] as? NSNumber, oversizedCount)
}

runner.register(
    id: "baseline-history-corrupt-refusal",
    tier: 2,
    feature: "BASE-HIST",
    name: "CleanupHistoryStore refuses append and clear when history JSON is corrupt"
) {
    let sandbox = try E2ESandbox(prefix: "base-hist-corrupt")
    defer { sandbox.cleanup() }

    let corruptURL = try sandbox.createFile("State/corrupt-history.json", utf8: "[bad")
    let originalData = try Data(contentsOf: corruptURL)
    let store = CleanupHistoryStore(fileURL: corruptURL)

    let loaded = store.load()
    try E2ERunner.expect(loaded.isEmpty, "Corrupt history should load empty fallback")
    try E2ERunner.expect(store.isWriteBlockedDueToLoadError, "Write block must be active")

    let dummy = CleanupRecord(actionTitle: "Should Fail", mode: .trash, itemCount: 1, freedBytes: 10, removedPaths: ["/tmp/x"])
    try E2ERunner.expect(!store.append(dummy), "append must refuse when corrupt")
    try E2ERunner.expect(!store.clear(), "clear must refuse when corrupt")
    try E2ERunner.expectEqual(try Data(contentsOf: corruptURL), originalData, "Original corrupt bytes must remain untouched")
}

runner.register(
    id: "baseline-safereader-security",
    tier: 2,
    feature: "BASE-READER",
    name: "SafeFileReader rejects symlinks, non-blocks FIFOs, enforces maxBytes, blocks symlink writes, and escapes control/bidi chars"
) {
    let sandbox = try E2ESandbox(prefix: "base-reader-sec")
    defer { sandbox.cleanup() }

    let target = try sandbox.createFile("target.txt", utf8: "original-target")
    let symlink = try sandbox.createSymlink(atRelativePath: "link.txt", targetURL: target)
    let fifo = try sandbox.createFIFO(atRelativePath: "named.fifo")
    let bigFile = try sandbox.createExactSizeFile("big.bin", byteCount: 4096)

    // (a) Symlink
    try E2ERunner.expectEqual(SafeFileReader.readBoundedRegularFileDetailed(at: symlink), .notRegularFile)

    // (b) FIFO without blocking
    let start = Date()
    let fifoResult = SafeFileReader.readBoundedRegularFileDetailed(at: fifo)
    let elapsed = Date().timeIntervalSince(start)
    try E2ERunner.expectEqual(fifoResult, .notRegularFile)
    try E2ERunner.expect(elapsed < 1.0, "Reading FIFO must return immediately (took \(elapsed)s)")

    // (c) Oversized
    try E2ERunner.expectEqual(
        SafeFileReader.readBoundedRegularFileDetailed(at: bigFile, maxBytes: 1024),
        .oversized(actualSize: 4096, maxBytes: 1024)
    )

    // (d) writePrivateAtomically refuses symlink target
    let wrote = SafeFileReader.writePrivateAtomically(Data("pwned".utf8), to: symlink)
    try E2ERunner.expect(!wrote, "writePrivateAtomically must refuse symlink target")
    try E2ERunner.expectEqual(try String(contentsOf: target, encoding: .utf8), "original-target")

    // (e) sanitizeForDisplay escapes bidi & control characters
    let raw = "bad\u{202E}txt\u{0007}\n\r\t\0\u{2066}x"
    let sanitized = SafeFileReader.sanitizeForDisplay(raw)
    try E2ERunner.expectEqual(sanitized, "bad\\u{202E}txt\\u{0007}\\n\\r\\t\\0\\u{2066}x")
}

runner.register(
    id: "baseline-sizer-symlink-truncation",
    tier: 2,
    feature: "BASE-SIZER",
    name: "DirectorySizer skips symlinks to large external trees and never caches truncated measurements"
) {
    let sandbox = try E2ESandbox(prefix: "base-sizer-trunc")
    defer { sandbox.cleanup() }

    let externalDir = try sandbox.createDirectory("External")
    let externalBig = try sandbox.createExactSizeFile("External/huge.bin", byteCount: 65_536)

    let measuredDir = try sandbox.createDirectory("Measured")
    _ = try sandbox.createExactSizeFile("Measured/local.bin", byteCount: 4096)
    _ = try sandbox.createSymlink(atRelativePath: "Measured/link-to-file", targetURL: externalBig)
    _ = try sandbox.createSymlink(atRelativePath: "Measured/link-to-dir", targetURL: externalDir)

    let sizer = DirectorySizer()
    let m = await sizer.measure(of: measuredDir)
    try E2ERunner.expectEqual(m.bytes, 4096, "Symlinks to external files/dirs must not contribute target bytes")

    let truncDir = try sandbox.createDirectory("Truncated")
    for i in 0..<8 {
        _ = try sandbox.createExactSizeFile("Truncated/f\(i).bin", byteCount: 4096)
    }

    let tm = await sizer.measure(of: truncDir, useCache: true, maxEntries: 2)
    try E2ERunner.expect(tm.isTruncated, "Measuring 8 files with maxEntries: 2 must set isTruncated = true")
    let isCached = await sizer.isCached(path: truncDir.path)
    try E2ERunner.expect(!isCached, "Truncated measurements must not be cached")
}

await runner.runAndExit()

import Foundation
import MacSweepCore

func runRemovalEngineChecks(_ runner: CheckRunner) {
    print("== RemovalEngine & PrivilegedExecutor Checks ==")

    runner.run("Permanent removal deletes target file and leaves symlink target untouched when deleting symlink") {
        let sandbox = try runner.makeTempSandbox(prefix: "rm-symlink")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let realFile = sandbox.appendingPathComponent("precious-real.txt")
        try Data("keep me safe".utf8).write(to: realFile)

        let symlink = sandbox.appendingPathComponent("cache-link")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: realFile)

        let sg = SafetyGuard(homeDirectory: sandbox)
        let engine = RemovalEngine(safetyGuard: sg)

        let report = engine.remove(
            targets: [RemovalTarget(url: symlink, estimatedSize: 12)],
            mode: .permanent,
            allowElevation: false
        )

        try runner.expect(report.isFullSuccess, "Symlink removal should succeed")
        try runner.expect(!fm.fileExists(atPath: symlink.path), "Symlink itself should be gone")
        try runner.expect(fm.fileExists(atPath: realFile.path), "Symlink TARGET must remain intact!")
    }

    runner.run("Trash removal moves sandbox file cleanly to Trash and records cleanup history (isolated from real ~/.Trash)") {
        let sandbox = try runner.makeTempSandbox(prefix: "rm-trash")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let mockTrash = sandbox.appendingPathComponent("MockTrash")
        try fm.createDirectory(at: mockTrash, withIntermediateDirectories: true)
        let sampleFile = sandbox.appendingPathComponent("macsweep-trash-probe-\(UUID().uuidString).txt")
        try Data("hello trash".utf8).write(to: sampleFile)

        let histURL = sandbox.appendingPathComponent("history.json")
        let historyStore = CleanupHistoryStore(fileURL: histURL)
        let sg = SafetyGuard(homeDirectory: sandbox)
        let engine = RemovalEngine(
            safetyGuard: sg,
            historyStore: historyStore,
            localTrashHandler: { url in
                try FileManager.default.moveItem(
                    at: url,
                    to: mockTrash.appendingPathComponent(url.lastPathComponent)
                )
            }
        )

        let report = engine.remove(
            targets: [RemovalTarget(url: sampleFile, estimatedSize: 11)],
            mode: .trash,
            actionTitle: "Sandbox Trash Test",
            allowElevation: false
        )

        try runner.expect(report.isFullSuccess, "Trash move should succeed")
        try runner.expect(!fm.fileExists(atPath: sampleFile.path), "Original file should no longer exist")
        try runner.expect(fm.fileExists(atPath: mockTrash.appendingPathComponent(sampleFile.lastPathComponent).path), "File should be inside isolated mock trash")

        let records = historyStore.load()
        try runner.expectEqual(records.count, 1, "Cleanup history should record 1 entry")
        try runner.expectEqual(records.first?.mode, .trash)
    }

    runner.run("SafetyGuard blocks removal of protected system paths inside RemovalEngine") {
        let sg = SafetyGuard()
        let engine = RemovalEngine(safetyGuard: sg)
        let report = engine.remove(
            targets: [RemovalTarget(url: URL(fileURLWithPath: "/System/Applications/Notes.app"))],
            mode: .permanent,
            allowElevation: false
        )
        try runner.expect(!report.isFullSuccess)
        try runner.expectEqual(report.succeededURLs.count, 0)
        try runner.expectEqual(report.failures.count, 1)
    }

    runner.run("PrivilegedExecutor POSIX single-quoting prevents shell injection and rejects unsafe paths") {
        let sandbox = try runner.makeTempSandbox(prefix: "priv-quote")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let sg = SafetyGuard(homeDirectory: sandbox)
        let exec = PrivilegedExecutor(safetyGuard: sg)

        let trickyURL = sandbox.appendingPathComponent("bad'name$(touch /tmp/pwned);`id`.plist")
        let cmd = try exec.buildPermanentDeleteShellCommand(
            urls: [trickyURL],
            packageIDsToForget: ["com.acme.pkg", "com.apple.pkg.Forbidden", "bad;rm -rf /"]
        )

        // Ensure single quotes are escaped and unsafe package IDs are dropped
        try runner.expect(cmd.contains("'\\''"), "Single quote must be POSIX escaped")
        try runner.expect(cmd.contains("pkgutil --forget 'com.acme.pkg'"), "Valid 3rd-party pkg ID should be included")
        try runner.expect(!cmd.contains("com.apple.pkg.Forbidden"), "Apple system pkg must be filtered out")
        try runner.expect(!cmd.contains("bad;rm"), "Shell injection in pkg ID must be filtered out")

        let finderScript = try exec.buildFinderTrashAppleScript(urls: [trickyURL])
        try runner.expect(finderScript.contains("tell application \"Finder\""))
        try runner.expect(finderScript.contains("delete {"))

        // Reject unsafe path before building any command
        var blocked = false
        do {
            _ = try exec.buildPermanentDeleteShellCommand(urls: [URL(fileURLWithPath: "/Applications")])
        } catch PrivilegedError.blockedBySafetyGuard {
            blocked = true
        }
        try runner.expect(blocked, "PrivilegedExecutor must reject /Applications")
    }
}

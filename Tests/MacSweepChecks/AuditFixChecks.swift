import Darwin
import Foundation
import MacSweepCore

private final class TestLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ initial: Value) {
        self.storage = initial
    }

    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

/// Regression checks covering every P0, P1, and P2 fix from the deep second-round audit.
func runAuditFixChecks(_ runner: CheckRunner) {
    print("== Audit P0/P1/P2 Fix Checks ==")

    let shRunner: PrivilegedExecutor.ScriptRunner = { script in
        ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", script])
    }

    // MARK: P0 #1 — pkgutil must NEVER collapse shared system directories & must filter all `com.apple.*`

    runner.run("P0 #1: pkgutil never collapses /Library/StartupItems, /Library/Printers, /etc/paths.d or sibling apps") {
        let sg = SafetyGuard()
        let rootPkg = PkgInfoRecord(packageID: "com.oray.sunlogin.macclient", volume: "/", location: "")
        let aweLines = [
            "Library/StartupItems",
            "Library/Printers",
            "etc/paths.d",
            "Library/LaunchDaemons",
            "Library/LaunchDaemons/com.oray.awesun.plist",
            "Applications/Google Docs.app/Contents/Info.plist",
        ]
        let resolved = ServiceFileMatcher.resolveAndCollapsePkgFiles(
            relativeLines: aweLines,
            pkgInfo: rootPkg,
            appBundlePath: "/Applications/AweSun.app",
            safetyGuard: sg,
            otherInstalledAppPaths: ["/Applications/Google Docs.app"]
        )
        try runner.expectEqual(resolved, ["/Library/LaunchDaemons/com.oray.awesun.plist"])
        try runner.expect(!resolved.contains("/Library/StartupItems"), "Must never return /Library/StartupItems")
        try runner.expect(!resolved.contains("/Library/Printers"), "Must never return /Library/Printers")
        try runner.expect(!resolved.contains("/etc/paths.d"), "Must never return /etc/paths.d")
        try runner.expect(!resolved.contains("/Applications/Google Docs.app"), "Must never claim sibling .app")

        // All com.apple.* packages (including com.apple.files.data-template) must be filtered
        let sanitized = PrivilegedExecutor.sanitizedPackageIDs([
            "com.apple.files.data-template",
            "com.apple.pkg.Core",
            "com.acme.valid",
        ])
        try runner.expectEqual(sanitized, ["com.acme.valid"])
    }

    // MARK: P0 #2 — Scheme A privileged trash succeeds on valid file, nested dir, and symlink without root chown or TMPDIR

    runner.run("P0 #2: buildPrivilegedTrashShellCommand exits 0 on valid file, nested dir, and symlink (Scheme A, ignores TMPDIR)") {
        let sandbox = try runner.makeTempSandbox(prefix: "p0-trash")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let trash = sandbox.appendingPathComponent("Trash")
        let evilTmp = sandbox.appendingPathComponent("EvilTMPDIR")
        try fm.createDirectory(at: evilTmp, withIntermediateDirectories: true)

        let file = sandbox.appendingPathComponent("single.dat")
        try Data("ok".utf8).write(to: file)

        let dir = sandbox.appendingPathComponent("Nested.app")
        try fm.createDirectory(at: dir.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("bin".utf8).write(to: dir.appendingPathComponent("Contents/MacOS/run"))

        let target = sandbox.appendingPathComponent("keep-target.txt")
        try Data("precious".utf8).write(to: target)
        let link = sandbox.appendingPathComponent("symlink.lnk")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        let exec = PrivilegedExecutor(safetyGuard: SafetyGuard(homeDirectory: sandbox))
        let script = try exec.buildPrivilegedTrashShellCommand(
            urls: [file, dir, link],
            trashDirectory: trash,
            timestamp: "clean"
        )
        try runner.expect(!script.contains("chown"), "Scheme A must completely remove root chown")
        try runner.expect(!script.contains("TMPDIR"), "Privileged trash script must never read TMPDIR")
        try runner.expect(script.contains("umask 077"), "Must set umask 077")
        try runner.expect(script.contains("/private/var/root"), "Root stage base must be /private/var/root")
        let res = ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: ["TMPDIR": evilTmp.path]
        )
        try runner.expectEqual(res.exitCode, 0, "Valid trash move must exit 0; stderr=\(res.stderr)")
        try runner.expect((try fm.contentsOfDirectory(atPath: evilTmp.path)).isEmpty, "Hostile TMPDIR must never be touched")
        try runner.expect(fm.fileExists(atPath: trash.appendingPathComponent("single.dat").path))
        try runner.expect(fm.fileExists(atPath: trash.appendingPathComponent("Nested.app/Contents/MacOS/run").path))
        try runner.expect(RemovalEngine.entryExists(trash.appendingPathComponent("symlink.lnk")))
        try runner.expect(fm.fileExists(atPath: target.path), "Symlink target must remain intact")
    }

    // MARK: P0 #4 — LibraryIndex.removing prunes deleted paths cleanly

    runner.run("P0 #4: LibraryIndex.removing prunes removed entries and their descendants") {
        let sandbox = try runner.makeTempSandbox(prefix: "p0-idx")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let userLib = sandbox.appendingPathComponent("UserLib")
        let keep = userLib.appendingPathComponent("Caches/com.acme.keep")
        let drop = userLib.appendingPathComponent("Caches/com.acme.drop")
        try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)

        let sg = SafetyGuard(homeDirectory: sandbox)
        let idx = LibraryIndex.build(userLibraryURL: userLib, systemLibraryURL: sandbox.appendingPathComponent("SysLib"), safetyGuard: sg)
        try runner.expectEqual(idx.entries.count, 2)
        let pruned = idx.removing(paths: [drop.standardizedFileURL.path])
        try runner.expectEqual(pruned.entries.count, 1)
        try runner.expectEqual(pruned.entries.first?.url.lastPathComponent, "com.acme.keep")
    }

    // MARK: P0 #5 + P1 #8 — Apple vendor folder never expanded; CUPS/OpenJDK/PLCrashReporter protected; containmentNames tightened

    runner.run("P0 #5 + P1 #8: Apple folder not expanded, CUPS/OpenJDK/PLCrashReporter/BTServer ignored, true leftovers not hidden by generic words") {
        let sandbox = try runner.makeTempSandbox(prefix: "p0-leftovers")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let userLib = sandbox.appendingPathComponent("UserLib")
        let sysLib = sandbox.appendingPathComponent("SysLib")
        let appsDir = sandbox.appendingPathComponent("Apps")
        let sysAppsDir = sandbox.appendingPathComponent("System/Applications")

        // Create a mock system app named Preview.app (should NOT pollute containmentNames!)
        let previewInfoDir = sysAppsDir.appendingPathComponent("Preview.app/Contents")
        try fm.createDirectory(at: previewInfoDir, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.apple.Preview", "CFBundleName": "Preview"],
            format: .xml, options: 0
        ).write(to: previewInfoDir.appendingPathComponent("Info.plist"))

        // Create protected OS/runtime entries that must NEVER become leftovers
        let shouldIgnore: [URL] = [
            sysLib.appendingPathComponent("Application Support/Apple/BezelServices"),
            sysLib.appendingPathComponent("Application Support/Apple/Remote Desktop"),
            sysLib.appendingPathComponent("Application Support/Apple/EmbeddedOSInstall"),
            sysLib.appendingPathComponent("Application Support/BTServer"),
            sysLib.appendingPathComponent("Application Support/ApplePushService"),
            sysLib.appendingPathComponent("Application Support/livefsd"),
            userLib.appendingPathComponent("Preferences/org.cups.PrintingPrefs.plist"),
            userLib.appendingPathComponent("Caches/com.plausiblelabs.crashreporter.data"),
            userLib.appendingPathComponent("Preferences/net.java.openjdk.cmd.plist"),
        ]
        for u in shouldIgnore {
            if u.pathExtension == "plist" {
                try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: u)
            } else {
                try fm.createDirectory(at: u, withIntermediateDirectories: true)
            }
        }

        // True leftovers containing words like "preview" or "installer" must NOT be hidden by tightened containmentNames
        let trueLeftovers: [URL] = [
            userLib.appendingPathComponent("Caches/org.libreoffice.script.quicklookpreview"),
            userLib.appendingPathComponent("Caches/com.sogou.SogouInstaller"),
        ]
        for u in trueLeftovers {
            try fm.createDirectory(at: u, withIntermediateDirectories: true)
        }

        let sg = SafetyGuard(homeDirectory: sandbox)
        let idx = LibraryIndex.build(userLibraryURL: userLib, systemLibraryURL: sysLib, safetyGuard: sg)
        // Verify Apple dir was NOT expanded into LibraryIndex
        try runner.expect(!idx.entries.contains { $0.url.path.contains("/Apple/") }, "LibraryIndex must never expand Apple vendor directory")

        let inv = InstalledAppInventory.build(searchRoots: [appsDir, sysAppsDir], libraryIndex: idx)
        try runner.expect(!inv.containmentNames.contains("preview"), "Generic/system word 'preview' must not be in containmentNames")

        let groups = LeftoverScanner(safetyGuard: sg).scan(index: idx, inventory: inv)
        let flaggedNames = Set(groups.flatMap { $0.files.map(\.displayName) })

        for bad in ["BezelServices", "Remote Desktop", "EmbeddedOSInstall", "BTServer", "ApplePushService", "livefsd",
                    "org.cups.PrintingPrefs.plist", "com.plausiblelabs.crashreporter.data", "net.java.openjdk.cmd.plist"] {
            try runner.expect(!flaggedNames.contains(bad), "Protected OS/runtime item must NOT be flagged: \(bad)")
        }
        try runner.expect(flaggedNames.contains("org.libreoffice.script.quicklookpreview"), "Real leftover with 'preview' must be found")
        try runner.expect(flaggedNames.contains("com.sogou.SogouInstaller"), "Real leftover with 'Installer' must be found")
    }

    // MARK: P1 #6 — AppleScript expression preserves CR (\r) and LF (\n)

    runner.run("P1 #6: ProcessRunner.appleScriptExpression preserves CR (Icon\\r) and LF via osascript round-trip") {
        let pathWithCR = "/tmp/Icon\r"
        let expr = ProcessRunner.appleScriptExpression(pathWithCR)
        try runner.expect(expr.contains("return"), "CR must be emitted as AppleScript 'return'")

        // Verify via live osascript evaluation (read-only, no filesystem side effects)
        let probe = ProcessRunner.run(
            executable: "/usr/bin/osascript",
            arguments: ["-e", "POSIX path of (POSIX file (\(expr)))"]
        )
        try runner.expect(probe.succeeded)
        // Compare raw UTF-8 bytes so Swift does not coalesce `\r\n` into a single Character grapheme.
        // osascript prints the POSIX path followed by a trailing LF (0x0A), so exact bytes must end with `0x0D 0x0A`.
        let actualBytes = Array(probe.stdout.utf8)
        let expectedBytes = Array("/tmp/Icon\r\n".utf8)
        try runner.expectEqual(actualBytes, expectedBytes, "AppleScript must preserve literal CR (0x0D) before trailing LF (0x0A)")
    }

    // MARK: P1 #7 — StartupController launchTargets keeps dual plists, enforces allowed roots, and handles unreadable plist

    runner.run("P1 #7: StartupController deduplicates by plist path, validates roots, and builds dynamic PlistBuddy label lookup") {
        let sandbox = try runner.makeTempSandbox(prefix: "p1-launch")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let userLA = sandbox.appendingPathComponent("User/LaunchAgents")
        let sysLA = sandbox.appendingPathComponent("Sys/LaunchAgents")
        let fakeLA = sandbox.appendingPathComponent("Other/LaunchAgents")
        for d in [userLA, sysLA, fakeLA] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let uPlist = userLA.appendingPathComponent("com.google.keystone.agent.plist")
        let sPlist = sysLA.appendingPathComponent("com.google.keystone.agent.plist")
        let fakePlist = fakeLA.appendingPathComponent("com.fake.agent.plist")
        for p in [uPlist, sPlist, fakePlist] {
            try Data("{}".utf8).write(to: p) // no Label key -> falls back to identical filename label
        }

        let targets = StartupController.launchTargets(
            for: [uPlist, sPlist, fakePlist],
            uid: 501,
            allowedLaunchDirs: [userLA, sysLA]
        )
        try runner.expectEqual(targets.count, 2, "Must keep BOTH user & system plists with same label and reject non-allowed dir")
        try runner.expect(targets.contains { $0.plistURL.path == uPlist.standardizedFileURL.path })
        try runner.expect(targets.contains { $0.plistURL.path == sPlist.standardizedFileURL.path })
        try runner.expect(!targets.contains { $0.plistURL.path == fakePlist.standardizedFileURL.path })

        let unloadCmd = StartupController.buildUnloadShellCommand(targets: targets)
        try runner.expect(unloadCmd.contains("PlistBuddy"), "Unreadable/no-Label plist must resolve Label dynamically in script")
    }

    // MARK: P1 #9 — pluginkit blank / = / ? status flags

    runner.run("P1 #9: parsePluginkitOutput treats blank/=/ ? as disabled and strips status markers from identifier") {
        let sample = """
             com.vendor.BlankDefault(1.0)\tU1\t2026-10-01 00:00:00 +0000\t/Applications/Foo.app/Contents/PlugIns/Blank.appex
        +    com.vendor.ExplicitOn(2.0)\tU2\t2026-10-01 00:00:00 +0000\t/Applications/Foo.app/Contents/PlugIns/On.appex
        =    com.vendor.Superseded(1.0)\tU3\t2026-10-01 00:00:00 +0000\t/Applications/Foo.app/Contents/PlugIns/Old.appex
        ?    com.vendor.Unknown(1.0)\tU4\t2026-10-01 00:00:00 +0000\t/Applications/Foo.app/Contents/PlugIns/Unk.appex
        """
        let parsed = ExtensionScanner.parsePluginkitOutput(sample)
        try runner.expectEqual(parsed.count, 4)
        try runner.expectEqual(parsed[0].identifier, "com.vendor.BlankDefault")
        try runner.expectEqual(parsed[0].isEnabled, false, "Blank flag must be disabled (not opted-in)")
        try runner.expectEqual(parsed[1].isEnabled, true, "+ flag must be enabled")
        try runner.expectEqual(parsed[2].identifier, "com.vendor.Superseded")
        try runner.expectEqual(parsed[2].isEnabled, false, "= flag must be stripped & disabled")
        try runner.expectEqual(parsed[3].identifier, "com.vendor.Unknown")
        try runner.expectEqual(parsed[3].isEnabled, false, "? flag must be stripped & disabled")
    }

    // MARK: P1 #11 — Privileged batch runs BEFORE normal items (atomic cancellation) & wider Finder fallback

    runner.run("P1 #11: Cancelling admin prompt leaves normal files untouched; Finder -1728 falls back to admin trash") {
        let sandbox = try runner.makeTempSandbox(prefix: "p1-order")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let normalFile = sandbox.appendingPathComponent("normal.txt")
        let privFile = sandbox.appendingPathComponent("priv.txt")
        try Data("n".utf8).write(to: normalFile)
        try Data("p".utf8).write(to: privFile)

        let sg = SafetyGuard(homeDirectory: sandbox)
        let cancelRunner: PrivilegedExecutor.ScriptRunner = { _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "User canceled. (-128)")
        }
        let cancelExec = PrivilegedExecutor(safetyGuard: sg, adminShellRunner: cancelRunner, finderAppleScriptRunner: cancelRunner)
        let cancelReport = RemovalEngine(safetyGuard: sg, privilegedExecutor: cancelExec).remove(
            targets: [
                RemovalTarget(url: normalFile, estimatedSize: 1, requiresAdmin: false),
                RemovalTarget(url: privFile, estimatedSize: 1, requiresAdmin: true),
            ],
            mode: .trash
        )
        try runner.expect(cancelReport.cancelledByUser)
        try runner.expect(fm.fileExists(atPath: normalFile.path), "Normal file MUST remain untouched when elevation is cancelled!")
        try runner.expect(fm.fileExists(atPath: privFile.path))

        // Now verify Finder -1728 error falls back to moveToTrashPrivileged
        let mockTrash = sandbox.appendingPathComponent("Trash")
        let finder1728: PrivilegedExecutor.ScriptRunner = { _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "execution error: Finder got an error: Can't get POSIX file. (-1728)")
        }
        let fallbackExec = PrivilegedExecutor(
            safetyGuard: sg,
            trashDirectory: mockTrash,
            adminShellRunner: shRunner,
            finderAppleScriptRunner: finder1728
        )
        let fbReport = RemovalEngine(safetyGuard: sg, privilegedExecutor: fallbackExec).remove(
            targets: [RemovalTarget(url: privFile, estimatedSize: 1, requiresAdmin: true)],
            mode: .trash
        )
        try runner.expect(fbReport.isFullSuccess, "Finder -1728 must fall back to admin mv cleanly")
        try runner.expect(fbReport.usedFinderFallbackToAdmin)
        try runner.expect(fm.fileExists(atPath: mockTrash.appendingPathComponent("priv.txt").path))
    }

    // MARK: P1 #13 — Cross-app bundle ID prefix collision + strict extractEnclosingApp

    runner.run("P1 #13: Shorter bundle ID does not claim files of longer installed sibling; extractEnclosingApp uses strict path segments") {
        let sandbox = try runner.makeTempSandbox(prefix: "p1-prefix")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let userLib = sandbox.appendingPathComponent("UserLib")
        try FileManager.default.createDirectory(at: userLib.appendingPathComponent("Caches/com.acme.suite"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userLib.appendingPathComponent("Caches/com.acme.suite.proxy"), withIntermediateDirectories: true)

        let sg = SafetyGuard(homeDirectory: sandbox)
        let idx = LibraryIndex.build(userLibraryURL: userLib, systemLibraryURL: sandbox.appendingPathComponent("Sys"), safetyGuard: sg)
        let matcher = ServiceFileMatcher(safetyGuard: sg)
        let mainApp = AppItem(
            url: sandbox.appendingPathComponent("Suite.app"),
            name: "Suite",
            localizedName: "Suite",
            bundleID: "com.acme.suite",
            version: "1.0"
        )
        let allIDs: Set<String> = ["com.acme.suite", "com.acme.suite.proxy"]
        let matched = matcher.matchInMemory(app: mainApp, index: idx, allInstalledBundleIDs: allIDs)
        let names = Set(matched.map(\.displayName))
        try runner.expect(names.contains("com.acme.suite"))
        try runner.expect(!names.contains("com.acme.suite.proxy"), "Longer installed bundle ID must win")

        // extractEnclosingApp strict component checks
        try runner.expectEqual(StartupScanner.extractEnclosingApp(from: ["/Library/com.apple.foo/bin"])?.name, nil)
        try runner.expectEqual(StartupScanner.extractEnclosingApp(from: ["/Library/My.application/bin"])?.name, nil)
        try runner.expectEqual(StartupScanner.extractEnclosingApp(from: ["/Library/PlugIns/Ext.appex/Contents/MacOS/Ext"])?.name, nil)
        try runner.expectEqual(StartupScanner.extractEnclosingApp(from: ["/Applications/Real.app/Contents/MacOS/Real"])?.name, "Real")
    }

    // MARK: P2 #14 / #16 / #17 / #20 — Self protection, embedded LaunchAgents, protectedBundleID prefix, ByHost UUID, Firefox profiles.ini

    runner.run("P2: Self-data protection, sub-ID user protection, embedded LaunchAgents, ByHost dot-UUID, and Firefox profiles.ini") {
        let sandbox = try runner.makeTempSandbox(prefix: "p2-misc")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default

        let sg = SafetyGuard(
            homeDirectory: sandbox,
            selfBundlePath: "/Applications/MacSweep.app",
            protectedBundleIDs: ["com.acme.keep"]
        )
        try runner.expect(!sg.validateForRemoval(sandbox.appendingPathComponent("Library/Preferences/local.macsweep.plist")).isAllowed)
        try runner.expect(!sg.validateForRemoval(sandbox.appendingPathComponent("Library/Caches/local.macsweep")).isAllowed)
        try runner.expect(sg.isProtectedFromLeftoverScan(name: "com.acme.keep.helper", bundleID: "com.acme.keep.helper"))

        // Embedded Contents/Library/LaunchAgents inside subfolder app
        let subApp = sandbox.appendingPathComponent("Apps/Suite/Embedded.app/Contents/Library/LaunchAgents")
        try fm.createDirectory(at: subApp, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.acme.embedded.agent", "ProgramArguments": ["/bin/true"]],
            format: .xml, options: 0
        ).write(to: subApp.appendingPathComponent("com.acme.embedded.agent.plist"))
        let startupItems = StartupScanner(
            userLaunchAgentsURL: sandbox.appendingPathComponent("empty1"),
            systemLaunchAgentsURL: sandbox.appendingPathComponent("empty2"),
            systemLaunchDaemonsURL: sandbox.appendingPathComponent("empty3"),
            appSearchRoots: [sandbox.appendingPathComponent("Apps")],
            safetyGuard: sg
        ).scanAll(userDisabledMap: [:], systemDisabledMap: [:])
        try runner.expect(startupItems.contains { $0.label == "com.acme.embedded.agent" && $0.scope == .appLoginItem },
                          "StartupScanner must find Contents/Library/LaunchAgents in 1-level subfolder apps")

        // ByHost dot-separated UUID stripping
        let byHostStem = "com.acme.Tool.11111111-2222-3333-4444-555555555555"
        try runner.expectEqual(InstalledAppInventory.stripUUIDSuffix(byHostStem), "com.acme.Tool")

        // Firefox profiles.ini parsing (relative & absolute)
        let ini = """
        [General]
        StartWithLastProfile=1

        [Profile0]
        Name=default-release
        IsRelative=1
        Path=Profiles/abc.default-release

        [Profile1]
        Name=custom
        IsRelative=0
        Path=/tmp/custom-ff-profile
        """
        let ffBase = URL(fileURLWithPath: "/Users/test/Library/Application Support/Firefox")
        let dirs = ExtensionScanner.parseFirefoxProfilesINI(ini, firefoxBaseURL: ffBase)
        try runner.expectEqual(dirs.count, 2)
        try runner.expectEqual(dirs[0].path, "/Users/test/Library/Application Support/Firefox/Profiles/abc.default-release")
        try runner.expectEqual(dirs[1].path, "/tmp/custom-ff-profile")
    }

    // MARK: N1 & N2 — Mixed user/system leftover group toggle protection & exact 37-char UUID suffix

    runner.run("N1: Mixed user+system leftover group toggle and selectHighConfidenceOnly never auto-check /Library items") {
        let sandbox = try runner.makeTempSandbox(prefix: "n1-mixed")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let userLib = sandbox.appendingPathComponent("UserLib")
        let sysLib = sandbox.appendingPathComponent("SysLib")

        // Same >=4-segment reverse-DNS ID present in both User and System scope -> merges into one group
        try fm.createDirectory(at: userLib.appendingPathComponent("Caches/com.gone.tool.editor"), withIntermediateDirectories: true)
        try fm.createDirectory(at: sysLib.appendingPathComponent("Caches/com.gone.tool.editor"), withIntermediateDirectories: true)

        let sg = SafetyGuard(homeDirectory: sandbox)
        let idx = LibraryIndex.build(userLibraryURL: userLib, systemLibraryURL: sysLib, safetyGuard: sg)
        let inv = InstalledAppInventory.build(searchRoots: [], libraryIndex: idx)
        let groups = LeftoverScanner(safetyGuard: sg).scan(index: idx, inventory: inv)

        guard var mixed = groups.first(where: { $0.id == "com.gone.tool" }) else {
            throw CheckFailure(message: "Expected merged mixed group com.gone.tool")
        }
        try runner.expectEqual(mixed.files.count, 2)
        try runner.expectEqual(mixed.confidence, .high)
        try runner.expect(mixed.hasSystemScopeFiles && mixed.hasUserScopeFiles)

        let userFileBefore = mixed.files.first { !$0.isSystemScope }
        let sysFileBefore = mixed.files.first { $0.isSystemScope }
        try runner.expectEqual(userFileBefore?.isSelected, true)
        try runner.expectEqual(sysFileBefore?.isSelected, false, "System-scope file must start unselected")

        // 1. Clicking 'High Only' must NOT select the system-scope file
        mixed.selectHighConfidenceOnly()
        try runner.expectEqual(mixed.files.first { !$0.isSystemScope }?.isSelected, true)
        try runner.expectEqual(mixed.files.first { $0.isSystemScope }?.isSelected, false, "High Only must never select /Library file")

        // 2. Unchecking then re-checking the group checkbox must NOT select the system-scope file
        mixed.applyGroupToggle(false)
        try runner.expectEqual(mixed.isChecked, false)
        try runner.expect(mixed.files.allSatisfy { !$0.isSelected })

        mixed.applyGroupToggle(true)
        try runner.expectEqual(mixed.isChecked, true)
        try runner.expectEqual(mixed.files.first { !$0.isSystemScope }?.isSelected, true)
        try runner.expectEqual(mixed.files.first { $0.isSystemScope }?.isSelected, false, "Group toggle ON must never auto-check /Library file")

        // 3. System-only group toggle ON must also keep /Library files unchecked (requires per-file opt-in)
        var sysOnly = LeftoverGroup(
            id: "com.gone.sysonly",
            groupName: "Sysonly",
            suspectedBundleID: "com.gone.sysonly",
            confidence: .medium,
            files: [
                ServiceFile(
                    url: sysLib.appendingPathComponent("Caches/com.gone.sysonly"),
                    category: .caches,
                    isSelected: false,
                    requiresAdmin: true,
                    isSystemScope: true,
                    confidence: .medium
                ),
            ],
            isChecked: false
        )
        sysOnly.applyGroupToggle(true)
        try runner.expectEqual(sysOnly.isChecked, false)
        try runner.expectEqual(sysOnly.files.first?.isSelected, false)
    }

    runner.run("N2: stripUUIDSuffix handles exact 37-char separator+UUID strings without off-by-one") {
        let exact37Underscore = "_11111111-2222-3333-4444-555555555555"
        let exact37Dash = "-11111111-2222-3333-4444-555555555555"
        let exact37Dot = ".11111111-2222-3333-4444-555555555555"
        try runner.expectEqual(exact37Underscore.count, 37)
        try runner.expectEqual(InstalledAppInventory.stripUUIDSuffix(exact37Underscore), "")
        try runner.expectEqual(InstalledAppInventory.stripUUIDSuffix(exact37Dash), "")
        try runner.expectEqual(InstalledAppInventory.stripUUIDSuffix(exact37Dot), "")
        try runner.expectEqual(InstalledAppInventory.stripUUIDSuffix("A" + exact37Underscore), "A")
    }

    // MARK: Security Audit Round 2 — M-01 through M-06 regressions

    runner.run("M-01: privileged trash avoids root chown (Scheme A), blocks symlink trash, and blocks parent-symlink TOCTOU") {
        let sandbox = try runner.makeTempSandbox(prefix: "m01-lpe")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let sg = SafetyGuard(homeDirectory: sandbox)
        let exec = PrivilegedExecutor(safetyGuard: sg)

        // 1. Under Scheme A, no root chown / find -links +1 exists, so a directory containing a hardlink
        //    cannot trigger any ownership change on the outside inode.
        let trash = sandbox.appendingPathComponent("Trash")
        let victimDir = sandbox.appendingPathComponent("HardlinkApp.app")
        try fm.createDirectory(at: victimDir, withIntermediateDirectories: true)
        let outsideFile = sandbox.appendingPathComponent("outside-root-like.dat")
        try Data("secret".utf8).write(to: outsideFile)
        let plantedHardlink = victimDir.appendingPathComponent("link.dat")
        try fm.linkItem(at: outsideFile, to: plantedHardlink)

        let hardlinkScript = try exec.buildPrivilegedTrashShellCommand(
            urls: [victimDir],
            trashDirectory: trash,
            timestamp: "hl"
        )
        try runner.expect(!hardlinkScript.contains("chown"), "Scheme A must not invoke chown")
        try runner.expect(!hardlinkScript.contains("-links +1"), "Scheme A must not rely on fragile find -links +1 guard")
        let hlRes = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", hardlinkScript])
        try runner.expectEqual(hlRes.exitCode, 0, "Moving dir without chown should succeed cleanly; stderr=\(hlRes.stderr)")
        try runner.expect(fm.fileExists(atPath: outsideFile.path), "Outside hardlink target must remain intact")

        // 2. Symlink Trash directory must fail immediately
        let realDir = sandbox.appendingPathComponent("RealDir")
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        let symlinkTrash = sandbox.appendingPathComponent("SymTrash")
        try fm.createSymbolicLink(at: symlinkTrash, withDestinationURL: realDir)
        let victim2 = sandbox.appendingPathComponent("victim2.txt")
        try Data("x".utf8).write(to: victim2)
        let symTrashScript = try exec.buildPrivilegedTrashShellCommand(urls: [victim2], trashDirectory: symlinkTrash)
        let symTrashRes = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", symTrashScript])
        try runner.expect(symTrashRes.exitCode != 0, "Symlink Trash dir must be rejected")
        try runner.expect(fm.fileExists(atPath: victim2.path), "Victim must not move into symlinked Trash")

        // 3. Parent-symlink TOCTOU swap between command build and execution must block rm -rf
        let swapParent = sandbox.appendingPathComponent("swap-parent")
        let protectedSibling = sandbox.appendingPathComponent("decoy-target")
        try fm.createDirectory(at: swapParent, withIntermediateDirectories: true)
        try fm.createDirectory(at: protectedSibling, withIntermediateDirectories: true)
        let targetInParent = swapParent.appendingPathComponent("item.txt")
        let targetInDecoy = protectedSibling.appendingPathComponent("item.txt")
        try Data("orig".utf8).write(to: targetInParent)
        try Data("precious".utf8).write(to: targetInDecoy)

        let rmScript = try exec.buildPermanentDeleteShellCommand(urls: [targetInParent])
        // Simulate attacker replacing swapParent with symlink to protectedSibling during auth window
        try fm.removeItem(at: swapParent)
        try fm.createSymbolicLink(at: swapParent, withDestinationURL: protectedSibling)
        let rmRes = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", rmScript])
        try runner.expect(rmRes.exitCode != 0, "Parent-symlink swap must abort rm -rf")
        try runner.expect(fm.fileExists(atPath: targetInDecoy.path), "Decoy file behind swapped parent symlink must stay intact")
    }

    runner.run("M-02: unsigned .app cannot spoof isAppleAppStoreApp or broad bundle prefixes like 'com' / 'com.apple'") {
        let sandbox = try runner.makeTempSandbox(prefix: "m02-spoof")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let sg = SafetyGuard(homeDirectory: sandbox)

        // Unsigned fake app claiming CFBundleIdentifier = "com.apple.Safari"
        let fakeApple = sandbox.appendingPathComponent("FakeSafari.app")
        try fm.createDirectory(at: fakeApple.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let fakePlist: [String: Any] = ["CFBundleIdentifier": "com.apple.Safari", "CFBundleName": "FakeSafari"]
        try PropertyListSerialization.data(fromPropertyList: fakePlist, format: .xml, options: 0)
            .write(to: fakeApple.appendingPathComponent("Contents/Info.plist"))

        let scanner = AppScanner(safetyGuard: sg)
        let inspected = scanner.inspectApp(at: fakeApple)
        try runner.expect(inspected != nil)
        try runner.expectEqual(inspected?.isAppleAppStoreApp, false, "Unsigned .app must NEVER be marked isAppleAppStoreApp")
        try runner.expect(!sg.isAppleBundleID("com.apple"), "Bare 'com.apple' must not be treated as Apple bundle ID")

        // ServiceFileMatcher must reject overly broad prefixes ("com", "org", "com.apple", "com.google")
        try runner.expect(!ServiceFileMatcher.isMatchableBundleID("com"))
        try runner.expect(!ServiceFileMatcher.isMatchableBundleID("org"))
        try runner.expect(!ServiceFileMatcher.isMatchableBundleID("com.apple"))
        try runner.expect(!ServiceFileMatcher.isMatchableBundleID("com.google"))
        try runner.expect(!ServiceFileMatcher.isMatchableBundleID("-evil.app"))
        try runner.expect(ServiceFileMatcher.isMatchableBundleID("com.acme.tool"))
        try runner.expect(ServiceFileMatcher.isMatchableBundleID("local.myapp"))

        let userLib = sandbox.appendingPathComponent("UserLib")
        try fm.createDirectory(at: userLib.appendingPathComponent("Caches/com.apple.Notes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: userLib.appendingPathComponent("Caches/com.thirdparty.Widget"), withIntermediateDirectories: true)
        let idx = LibraryIndex.build(userLibraryURL: userLib, systemLibraryURL: sandbox.appendingPathComponent("SysLib"), safetyGuard: sg)
        let matcher = ServiceFileMatcher(safetyGuard: sg)

        let broadApp = AppItem(url: fakeApple, name: "Fake", localizedName: "Fake", bundleID: "com", version: "1.0")
        try runner.expect(matcher.matchInMemory(app: broadApp, index: idx).isEmpty, "Broad 'com' bundleID must match nothing")
        try runner.expect(ServiceFileMatcher.findMatchingPackageIDs(bundleID: "com", allPackageIDs: ["com.thirdparty.pkg"]).isEmpty)
        try runner.expect(matcher.matchInMemory(app: inspected!, index: idx).isEmpty, "Unsigned spoofed com.apple.Safari must not match com.apple.*")
    }

    runner.run("M-03: SafetyGuard blocks shared vendor dirs, keychains/ssh/etc/TCC, self ancestors, case variants, and NUL") {
        let sandbox = try runner.makeTempSandbox(prefix: "m03-sg")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let appParent = sandbox.appendingPathComponent("MyApps")
        let selfApp = appParent.appendingPathComponent("MacSweep.app")
        let protectedSub = sandbox.appendingPathComponent("KeepRoot/Sub")
        let sg = SafetyGuard(
            homeDirectory: sandbox,
            selfBundlePath: selfApp.path,
            protectedPaths: [protectedSub.path]
        )

        let mustBlock = [
            sandbox.appendingPathComponent("Library/Application Support/Google").path,
            sandbox.appendingPathComponent("Library/Application Support/Microsoft").path,
            "/Library/Keychains",
            "/Library/Keychains/System.keychain",
            sandbox.appendingPathComponent("Library/Keychains/login.keychain-db").path,
            sandbox.appendingPathComponent(".ssh/id_ed25519").path,
            sandbox.appendingPathComponent(".gnupg/secring.gpg").path,
            "/etc/hosts",
            "/private/etc/sudoers",
            "/private/var/db/dslocal/nodes/Default",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Preferences/SystemConfiguration/preferences.plist",
            "/LIBRARY/APPLE/SomeNonexistentFile",
            appParent.path, // ancestor of selfBundlePath
            sandbox.appendingPathComponent("KeepRoot").path, // ancestor of protectedPaths
            protectedSub.appendingPathComponent("child.dat").path, // descendant of protectedPaths
        ]
        for p in mustBlock {
            try runner.expect(!sg.validateForRemoval(URL(fileURLWithPath: p)).isAllowed, "Must block: \(p)")
        }
        try runner.expect(!sg.validateForRemoval(URL(fileURLWithPath: sandbox.path + "/bad\u{0000}name")).isAllowed,
                          "Must block NUL byte in path")
        try runner.expect(sg.validateForRemoval(sandbox.appendingPathComponent("literal%00ok.txt")).isAllowed,
                          "Literal '%00' characters in filename should still be allowed")
    }

    runner.run("M-04 & M-05: Firefox path confinement, Chromium locale validation, ProcessRunner NUL safety, StartupController & pkgutil guards") {
        let sandbox = try runner.makeTempSandbox(prefix: "m04-ext")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let sg = SafetyGuard(homeDirectory: sandbox)

        // Firefox profiles.ini rejects relative '..' escape
        let evilIni = """
        [Profile0]
        Name=escape
        IsRelative=1
        Path=../../outside
        """
        let ffBase = sandbox.appendingPathComponent("Firefox")
        try runner.expect(ExtensionScanner.parseFirefoxProfilesINI(evilIni, firefoxBaseURL: ffBase).isEmpty,
                          "IsRelative=1 '..' traversal must be dropped")

        // Firefox extensions.json rejects path outside <profile>/extensions/
        let profileDir = ffBase.appendingPathComponent("Profiles/abc.default")
        let extDir = profileDir.appendingPathComponent("extensions")
        try fm.createDirectory(at: extDir, withIntermediateDirectories: true)
        let validXpi = extDir.appendingPathComponent("good@example.org.xpi")
        let outsideFile = sandbox.appendingPathComponent("secret.txt")
        try Data("ok".utf8).write(to: validXpi)
        try Data("secret".utf8).write(to: outsideFile)
        let ffJSON = """
        {
          "addons": [
            {"id":"good@example.org","location":"app-profile","type":"extension","path":"\(validXpi.path)"},
            {"id":"evil@example.org","location":"app-profile","type":"extension","path":"\(outsideFile.path)"}
          ]
        }
        """
        let ffItems = ExtensionScanner.parseFirefoxExtensionsJSON(
            Data(ffJSON.utf8),
            profileName: "abc.default",
            computeSize: false,
            profileDirectory: profileDir,
            safetyGuard: sg
        )
        try runner.expectEqual(ffItems.count, 1)
        try runner.expectEqual(ffItems.first?.identifier, "good@example.org")

        // ProcessRunner rejects NUL byte cleanly without crashing via ObjC exception
        let nulRes = ProcessRunner.run(executable: "/bin/echo", arguments: ["hello\0world"])
        try runner.expectEqual(nulRes.exitCode, -1, "NUL arg must return exitCode -1 without SIGABRT")

        // sanitizedPackageIDs rejects leading '-' and bare 'com.apple'
        let pkgs = PrivilegedExecutor.sanitizedPackageIDs(["--volume", "-v", "com.apple", "com.apple.pkg.X", "com.acme.ok"])
        try runner.expectEqual(pkgs, ["com.acme.ok"])

        // StartupController root PlistBuddy branch rejects com.apple.* labels dynamically
        let unloadCmd = StartupController.buildUnloadShellCommand(targets: [
            LaunchServiceTarget(
                label: "com.acme.fallback",
                domain: "system",
                plistURL: URL(fileURLWithPath: "/Library/LaunchDaemons/com.acme.fallback.plist"),
                labelFromPlist: nil
            )
        ])
        try runner.expect(unloadCmd.contains("'com.apple.'*"), "Root PlistBuddy label script must guard against com.apple.*")

        // CleanupHistoryStore & PreferencesStore enforce 0700 / 0600 permissions
        let storeDir = sandbox.appendingPathComponent("StorePerms")
        let histFile = storeDir.appendingPathComponent("history.json")
        let prefFile = storeDir.appendingPathComponent("preferences.json")
        CleanupHistoryStore(fileURL: histFile).clear()
        PreferencesStore(fileURL: prefFile).save(SweepPreferences())
        let dirPerm = (try fm.attributesOfItem(atPath: storeDir.path)[.posixPermissions] as? NSNumber)?.intValue
        let histPerm = (try fm.attributesOfItem(atPath: histFile.path)[.posixPermissions] as? NSNumber)?.intValue
        let prefPerm = (try fm.attributesOfItem(atPath: prefFile.path)[.posixPermissions] as? NSNumber)?.intValue
        try runner.expectEqual(dirPerm, 0o700)
        try runner.expectEqual(histPerm, 0o600)
        try runner.expectEqual(prefPerm, 0o600)
    }

    // MARK: Security Audit Round 3 — MS-V01 through MS-V09 & MS-H02..H04 regressions

    runner.run("R3 MS-V01/V04: Trash TOCTOU rollback, trash-move-failed accounting, root-owned-trash warning, and Phase 2->3 TOCTOU guard") {
        let sandbox = try runner.makeTempSandbox(prefix: "r3-v01-v04")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let sg = SafetyGuard(homeDirectory: sandbox)

        // 1. Read-only Trash causes 2nd mv to fail -> staged item rolls back to original parent and emits trash-move-failed:
        let roTrash = sandbox.appendingPathComponent("ROTrash")
        try fm.createDirectory(at: roTrash, withIntermediateDirectories: true)
        let item1 = sandbox.appendingPathComponent("rollback-me.dat")
        try Data("important".utf8).write(to: item1)

        let exec = PrivilegedExecutor(safetyGuard: sg)
        let roScript = try exec.buildPrivilegedTrashShellCommand(urls: [item1], trashDirectory: roTrash, timestamp: "ro")
        chmod(roTrash.path, 0o555)
        defer { chmod(roTrash.path, 0o755) }
        let roRes = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", roScript])
        chmod(roTrash.path, 0o755)
        try runner.expect(roRes.exitCode != 0, "Unwritable Trash must exit non-zero")
        try runner.expect(roRes.stderr.contains("trash-move-failed-idx:0") && roRes.stderr.contains("trash-move-failed:"),
                          "Failed 2nd mv must emit trash-move-failed markers; stderr=\(roRes.stderr)")
        try runner.expect(fm.fileExists(atPath: item1.path), "Failed 2nd mv must roll staged item back to original parent")

        // 2. Post-build Trash symlink swap (real dir -> symlink to decoy) must be blocked by pinned Trash verification
        let swappableTrash = sandbox.appendingPathComponent("SwapTrash")
        let decoyDir = sandbox.appendingPathComponent("DecoyRootDir")
        try fm.createDirectory(at: swappableTrash, withIntermediateDirectories: true)
        try fm.createDirectory(at: decoyDir, withIntermediateDirectories: true)
        let item2 = sandbox.appendingPathComponent("dont-plant.dat")
        try Data("payload".utf8).write(to: item2)
        let swapTrashScript = try exec.buildPrivilegedTrashShellCommand(urls: [item2], trashDirectory: swappableTrash, timestamp: "sw")
        try fm.removeItem(at: swappableTrash)
        try fm.createSymbolicLink(at: swappableTrash, withDestinationURL: decoyDir)
        let swapTrashRes = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", swapTrashScript])
        try runner.expect(swapTrashRes.exitCode != 0, "Swapped Trash symlink must fail")
        try runner.expect((try fm.contentsOfDirectory(atPath: decoyDir.path)).isEmpty, "Decoy directory behind swapped Trash must receive nothing")
        try runner.expect(fm.fileExists(atPath: item2.path), "Item must remain rolled back when Trash was swapped")

        // 3. Even if original item disappeared (stranded in $stage), RemovalEngine treats trash-move-failed as failure
        let stranded = sandbox.appendingPathComponent("stranded.dat")
        try Data("x".utf8).write(to: stranded)
        let finderFail: PrivilegedExecutor.ScriptRunner = { _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "Not authorized (-1743)")
        }
        let strandedRunner: PrivilegedExecutor.ScriptRunner = { _ in
            try? FileManager.default.removeItem(at: stranded)
            return ProcessResult(exitCode: 1, stdout: "", stderr: "trash-move-failed-idx:0\ntrash-move-failed:\(stranded.path)\n")
        }
        let strandedExec = PrivilegedExecutor(safetyGuard: sg, trashDirectory: roTrash, adminShellRunner: strandedRunner, finderAppleScriptRunner: finderFail)
        let strandedReport = RemovalEngine(safetyGuard: sg, privilegedExecutor: strandedExec).remove(
            targets: [RemovalTarget(url: stranded, estimatedSize: 42, requiresAdmin: true)],
            mode: .trash
        )
        try runner.expect(!strandedReport.isFullSuccess, "Stranded staged item must NOT report full success")
        try runner.expect(strandedReport.succeededURLs.isEmpty, "Stranded staged item must NOT appear in succeededURLs")
        try runner.expectEqual(strandedReport.failures.count, 1)
        try runner.expectEqual(strandedReport.freedBytes, 0)

        // 4. `root-owned-trash:` marker triggers user warning on successful fallback trash move
        let rootish = sandbox.appendingPathComponent("RootDir.app")
        try fm.createDirectory(at: rootish, withIntermediateDirectories: true)
        let rootWarnRunner: PrivilegedExecutor.ScriptRunner = { _ in
            try? FileManager.default.removeItem(at: rootish)
            return ProcessResult(exitCode: 0, stdout: "root-owned-trash:RootDir.app\n", stderr: "")
        }
        let warnExec = PrivilegedExecutor(safetyGuard: sg, trashDirectory: roTrash, adminShellRunner: rootWarnRunner, finderAppleScriptRunner: finderFail)
        let warnReport = RemovalEngine(safetyGuard: sg, privilegedExecutor: warnExec).remove(
            targets: [RemovalTarget(url: rootish, estimatedSize: 10, requiresAdmin: true)],
            mode: .trash
        )
        try runner.expect(warnReport.isFullSuccess)
        try runner.expect(!warnReport.warnings.isEmpty, "root-owned-trash marker must populate RemovalReport.warnings")

        // 5. Phase 2 -> Phase 3 TOCTOU: swapping a normal target's parent during admin prompt must block local deletion
        let privDummy = sandbox.appendingPathComponent("priv-trigger.dat")
        try Data("p".utf8).write(to: privDummy)
        let normalParent = sandbox.appendingPathComponent("mutable-parent")
        let docsDir = sandbox.appendingPathComponent("Documents")
        try fm.createDirectory(at: normalParent, withIntermediateDirectories: true)
        try fm.createDirectory(at: docsDir, withIntermediateDirectories: true)
        let normalTarget = normalParent.appendingPathComponent("secret.txt")
        let docsVictim = docsDir.appendingPathComponent("secret.txt")
        try Data("normal".utf8).write(to: normalTarget)
        try Data("protected-docs".utf8).write(to: docsVictim)

        let swapDuringPhase2: PrivilegedExecutor.ScriptRunner = { _ in
            try? FileManager.default.removeItem(at: privDummy)
            try? FileManager.default.removeItem(at: normalParent)
            try? FileManager.default.createSymbolicLink(at: normalParent, withDestinationURL: docsDir)
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
        let phase2Exec = PrivilegedExecutor(safetyGuard: sg, adminShellRunner: swapDuringPhase2)
        let toctouReport = RemovalEngine(safetyGuard: sg, privilegedExecutor: phase2Exec).remove(
            targets: [
                RemovalTarget(url: privDummy, estimatedSize: 1, requiresAdmin: true),
                RemovalTarget(url: normalTarget, estimatedSize: 1, requiresAdmin: false),
            ],
            mode: .permanent
        )
        try runner.expect(!toctouReport.isFullSuccess, "Swapped normal target must fail Phase 3 re-validation")
        try runner.expect(toctouReport.failures.contains { $0.url.path == normalTarget.standardizedFileURL.path })
        try runner.expect(fm.fileExists(atPath: docsVictim.path), "Protected Documents file behind swapped symlink MUST stay intact")
    }

    runner.run("R3 MS-V02: blocks group.com.apple, 2-segment vendor prefixes, spoofed CFBundleExecutable, cross-TeamID containers, and protectedBundleIDs") {
        let sandbox = try runner.makeTempSandbox(prefix: "r3-v02-matcher")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let userLib = sandbox.appendingPathComponent("UserLib")
        let sysLib = sandbox.appendingPathComponent("SysLib")

        // Create sensitive targets that malicious apps attempt to claim
        let pathsToCreate: [URL] = [
            userLib.appendingPathComponent("Group Containers/group.com.apple.notes"),
            userLib.appendingPathComponent("Group Containers/ABCDE12345.com.apple.notes"),
            userLib.appendingPathComponent("Group Containers/2BUA8C4S2C.com.1password.1password"),
            userLib.appendingPathComponent("Group Containers/UBF8T346G9.Office"),
            userLib.appendingPathComponent("Group Containers/TEAM999999.com.acme.Tool"),
            userLib.appendingPathComponent("Group Containers/TEAM111111.com.acme.Tool"),
            userLib.appendingPathComponent("Caches/com.docker.docker"),
            userLib.appendingPathComponent("Preferences/com.docker.docker.plist"),
            userLib.appendingPathComponent("Caches/local.myapp"),
            userLib.appendingPathComponent("Preferences/ByHost/local.myapp.11111111-2222-3333-4444-555555555555.plist"),
            userLib.appendingPathComponent("Application Support/Google/Chrome"),
            userLib.appendingPathComponent("Application Support/MobileSync"),
            userLib.appendingPathComponent("Application Support/AddressBook"),
            userLib.appendingPathComponent("Application Support/com.1password.1password"),
            userLib.appendingPathComponent("Caches/com.acme.protected"),
            userLib.appendingPathComponent("Group Containers/group.com.acme.protected"),
        ]
        for u in pathsToCreate {
            if u.pathExtension == "plist" {
                try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: u)
            } else {
                try fm.createDirectory(at: u, withIntermediateDirectories: true)
            }
        }
        // System LaunchDaemons
        let sysLD = sysLib.appendingPathComponent("LaunchDaemons")
        try fm.createDirectory(at: sysLD, withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.docker.vmnetd", "Program": "/usr/bin/true"],
            format: .xml, options: 0
        ).write(to: sysLD.appendingPathComponent("com.docker.vmnetd.plist"))
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.apple.notes.helper", "Program": "/usr/bin/true"],
            format: .xml, options: 0
        ).write(to: sysLD.appendingPathComponent("com.helper.applelabel.plist"))

        let sg = SafetyGuard(homeDirectory: sandbox, protectedBundleIDs: ["com.acme.protected"])
        let idx = LibraryIndex.build(userLibraryURL: userLib, systemLibraryURL: sysLib, safetyGuard: sg)
        let matcher = ServiceFileMatcher(safetyGuard: sg)

        // 1. group.com.apple and unsigned com.apple.notes must be rejected
        try runner.expect(!ServiceFileMatcher.isMatchableBundleID("group.com.apple"))
        try runner.expect(!ServiceFileMatcher.isMatchableBundleID("group.com.acme.app"))
        try runner.expect(!ServiceFileMatcher.isMatchableBundleID("com.apple.notes"))
        try runner.expect(ServiceFileMatcher.isMatchableBundleID("com.apple.iWork.Pages", allowApple: true))
        try runner.expect(!ServiceFileMatcher.isMatchableBundleID("com.apple", allowApple: true))

        let groupAppleApp = AppItem(url: sandbox.appendingPathComponent("EvilGroup.app"), name: "EvilGroup", localizedName: "EvilGroup", bundleID: "group.com.apple", version: "1")
        try runner.expect(matcher.matchInMemory(app: groupAppleApp, index: idx).isEmpty, "group.com.apple must match nothing")

        let spoofAppleApp = AppItem(url: sandbox.appendingPathComponent("EvilNotes.app"), name: "EvilNotes", localizedName: "EvilNotes", bundleID: "com.apple.notes", version: "1", isAppleAppStoreApp: false)
        try runner.expect(matcher.matchInMemory(app: spoofAppleApp, index: idx).isEmpty, "Unsigned com.apple.notes must not match Apple Group Containers or LaunchDaemons")

        // 2. 2-segment vendor prefixes cannot prefix-match 3-segment siblings, LaunchDaemons, or pkgutil receipts
        try runner.expect(!ServiceFileMatcher.allowsPrefixMatching(forBundleID: "com.docker"))
        try runner.expect(!ServiceFileMatcher.allowsPrefixMatching(forBundleID: "com.1password"))
        try runner.expect(!ServiceFileMatcher.allowsPrefixMatching(forBundleID: "org.python"))
        try runner.expect(!ServiceFileMatcher.allowsPrefixMatching(forBundleID: "us.zoom"))
        try runner.expect(ServiceFileMatcher.allowsPrefixMatching(forBundleID: "com.acme.tool"))

        let spoofDocker = AppItem(url: sandbox.appendingPathComponent("EvilDocker.app"), name: "EvilDocker", localizedName: "EvilDocker", bundleID: "com.docker", version: "1")
        try runner.expect(matcher.matchInMemory(app: spoofDocker, index: idx).isEmpty, "2-segment com.docker must not claim com.docker.docker or com.docker.vmnetd")
        try runner.expect(ServiceFileMatcher.findMatchingPackageIDs(bundleID: "com.docker", allPackageIDs: ["com.docker.pkg.Docker", "com.docker.cli"]).isEmpty,
                          "2-segment com.docker must not prefix-match 3-segment pkg receipts")

        // 2-segment local.myapp still exact-matches its own Cache and ByHost UUID preference
        let localApp = AppItem(url: sandbox.appendingPathComponent("MyApp.app"), name: "MyApp", localizedName: "MyApp", bundleID: "local.myapp", version: "1")
        let localMatches = Set(matcher.matchInMemory(app: localApp, index: idx).map(\.displayName))
        try runner.expect(localMatches.contains("local.myapp"))
        try runner.expect(localMatches.contains("local.myapp.11111111-2222-3333-4444-555555555555.plist"))

        // 3. TeamID restriction & TeamID-spoofed CFBundleIdentifier / app-name blocking on Group Containers
        try runner.expect(ServiceFileMatcher.matchesGroupContainer(entryName: "TEAM111111.com.acme.Tool", bundleID: "com.acme.Tool", teamID: "TEAM111111"))
        try runner.expect(!ServiceFileMatcher.matchesGroupContainer(entryName: "TEAM999999.com.acme.Tool", bundleID: "com.acme.Tool", teamID: "TEAM111111"),
                          "Signed app with TeamID must not match another TeamID's container")
        try runner.expect(!ServiceFileMatcher.matchesGroupContainer(entryName: "group.com.apple.notes", bundleID: "com.apple.notes", teamID: nil, allowApple: false))

        let teamIDSpoofApps: [AppItem] = [
            AppItem(url: sandbox.appendingPathComponent("Spoof1PFull.app"), name: "Spoof1PFull", localizedName: "Spoof1PFull", bundleID: "2BUA8C4S2C.com.1password.1password", version: "1"),
            AppItem(url: sandbox.appendingPathComponent("Spoof1PShort.app"), name: "Spoof1PShort", localizedName: "Spoof1PShort", bundleID: "2BUA8C4S2C.com.1password", version: "1"),
            AppItem(url: sandbox.appendingPathComponent("SpoofOfficeID.app"), name: "SpoofOfficeID", localizedName: "SpoofOfficeID", bundleID: "UBF8T346G9.Office", version: "1"),
            AppItem(url: sandbox.appendingPathComponent("UBF8T346G9.Office.app"), name: "UBF8T346G9.Office", localizedName: "UBF8T346G9.Office", bundleID: "com.evil.spoofoffice", version: "1"),
        ]
        for spoof in teamIDSpoofApps {
            let groupHits = matcher.matchInMemory(app: spoof, index: idx).filter { $0.category == .groupContainers }
            try runner.expect(groupHits.isEmpty, "TeamID-spoofed app '\(spoof.name)' (\(spoof.bundleID)) must match zero Group Containers, got \(groupHits.map(\.displayName))")
        }

        // 4. AppScanner.inspectApp validates CFBundleExecutable via lstat & Rule 3 rejects spoofed executables / TCC / reverse-DNS / protected IDs
        let fakeExecApp = sandbox.appendingPathComponent("Innocent.app")
        try fm.createDirectory(at: fakeExecApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.evil.innocent", "CFBundleName": "Innocent", "CFBundleExecutable": "MobileSync"],
            format: .xml, options: 0
        ).write(to: fakeExecApp.appendingPathComponent("Contents/Info.plist"))
        let inspectedMissingExec = AppScanner(safetyGuard: sg).inspectApp(at: fakeExecApp)
        try runner.expectEqual(inspectedMissingExec?.executableName, nil, "Missing Contents/MacOS/<exec> must yield nil executableName")

        for spoofedExec in ["Chrome", "MobileSync", "AddressBook", "com.1password.1password", "com.docker.vmnetd"] {
            let spoofApp = AppItem(
                url: fakeExecApp,
                name: "Innocent",
                localizedName: "Innocent",
                bundleID: "com.evil.innocent",
                version: "1",
                executableName: spoofedExec
            )
            let hits = matcher.matchInMemory(app: spoofApp, index: idx, allInstalledBundleIDs: ["com.1password.1password"])
            try runner.expect(hits.isEmpty, "Spoofed executableName '\(spoofedExec)' must match nothing, got \(hits.map(\.displayName))")
        }

        // 5. Protected bundle IDs are skipped by ServiceFileMatcher even when app matches them
        let protApp = AppItem(url: sandbox.appendingPathComponent("Protected.app"), name: "Protected", localizedName: "Protected", bundleID: "com.acme.protected", version: "1")
        try runner.expect(matcher.matchInMemory(app: protApp, index: idx).isEmpty, "protectedBundleIDs must never be matched for removal")

        // 6. Case-insensitive sibling app exclusion in resolveAndCollapsePkgFiles (MS-H02)
        let pkg = PkgInfoRecord(packageID: "com.acme.suite", volume: "/", location: "")
        let resolved = ServiceFileMatcher.resolveAndCollapsePkgFiles(
            relativeLines: ["Applications/Google Docs.app/Contents/Info.plist", "Library/LaunchDaemons/com.acme.suite.plist"],
            pkgInfo: pkg,
            appBundlePath: "/APPLICATIONS/MAIN.APP",
            safetyGuard: sg,
            otherInstalledAppPaths: ["/APPLICATIONS/GOOGLE DOCS.APP"]
        )
        try runner.expectEqual(resolved, ["/Library/LaunchDaemons/com.acme.suite.plist"])
    }

    runner.run("R3 MS-V03 & MS-H03: Firefox extensions symlink escape, profiles.ini confinement, ExtensionController & protected plugins") {
        let sandbox = try runner.makeTempSandbox(prefix: "r3-v03-ff")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let sg = SafetyGuard(homeDirectory: sandbox, protectedBundleIDs: ["com.acme.keepplugin"])

        // 1. `<profile>/extensions` replaced by symlink pointing outside profile -> 0 items
        let ffBase = sandbox.appendingPathComponent("Library/Application Support/Firefox")
        let profileDir = ffBase.appendingPathComponent("Profiles/abc.default")
        let outsideTarget = sandbox.appendingPathComponent("OutsideSecret")
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: outsideTarget, withIntermediateDirectories: true)
        let secretFile = outsideTarget.appendingPathComponent("precious.dat")
        try Data("secret".utf8).write(to: secretFile)
        let extLink = profileDir.appendingPathComponent("extensions")
        try fm.createSymbolicLink(at: extLink, withDestinationURL: outsideTarget)

        let craftedViaSymlink = extLink.appendingPathComponent("precious.dat")
        let evilJSON = """
        {
          "addons": [
            {"id":"fake@evil.org","location":"app-profile","type":"extension","path":"\(craftedViaSymlink.path)"}
          ]
        }
        """
        try Data(evilJSON.utf8).write(to: profileDir.appendingPathComponent("extensions.json"))

        let parsedDirect = ExtensionScanner.parseFirefoxExtensionsJSON(
            Data(evilJSON.utf8),
            profileName: "abc.default",
            computeSize: false,
            profileDirectory: profileDir,
            safetyGuard: sg
        )
        try runner.expect(parsedDirect.isEmpty, "Symlinked <profile>/extensions must return 0 items")
        let scannedFF = ExtensionScanner(homeDirectory: sandbox, safetyGuard: sg).scanFirefoxBase(at: ffBase, computeSize: false)
        try runner.expect(scannedFF.isEmpty, "scanFirefoxBase must return 0 items when extensions is a symlink")

        // 2. profiles.ini IsRelative=0 outside allowedAbsoluteRoot & IsRelative=1 symlink escape rejected
        let symlinkProf = ffBase.appendingPathComponent("Profiles/escape.prof")
        try fm.createSymbolicLink(at: symlinkProf, withDestinationURL: outsideTarget)
        let ini = """
        [Profile0]
        IsRelative=1
        Path=Profiles/escape.prof
        [Profile1]
        IsRelative=0
        Path=/tmp/outside-home-profile
        """
        let constrained = ExtensionScanner.parseFirefoxProfilesINI(ini, firefoxBaseURL: ffBase, allowedAbsoluteRoot: sandbox)
        try runner.expect(constrained.isEmpty, "Symlink relative profile and outside-home absolute profile must be rejected")

        // 3. ExtensionController.setPluginEnabled rejects bare com.apple, Apple groups, leading '-', whitespace/control chars
        //    while allowing legitimate third-party `group.*` and 2-segment vendor extension IDs (MS-H03).
        for badID in ["com.apple", "com.apple.Safari", "group.com.apple.x", "-evil.ext", "com.acme.bad id", "com.acme.bad\n", "single"] {
            var threw = false
            do {
                try ExtensionController.setPluginEnabled(false, identifier: badID)
            } catch ExtensionControlError.notToggleable {
                threw = true
            }
            try runner.expect(threw, "setPluginEnabled must reject '\(badID)'")
            try runner.expect(!ExtensionController.isValidPluginKitIdentifier(badID), "isValidPluginKitIdentifier must reject '\(badID)'")
        }
        for validID in ["group.com.acme.ext", "com.google", "com.microsoft", "local.ext", "com.vendor.app.ShareExt"] {
            try runner.expect(ExtensionController.isValidPluginKitIdentifier(validID), "isValidPluginKitIdentifier must accept '\(validID)'")
        }

        // 4. scanSystemPluginDirectories skips protectedBundleIDs
        let sysLib = sandbox.appendingPathComponent("SysLib")
        let keepPlugin = sysLib.appendingPathComponent("QuickLook/com.acme.keepplugin.qlgenerator")
        let okPlugin = sysLib.appendingPathComponent("QuickLook/com.other.ok.qlgenerator")
        try fm.createDirectory(at: keepPlugin, withIntermediateDirectories: true)
        try fm.createDirectory(at: okPlugin, withIntermediateDirectories: true)
        let sysPlugins = ExtensionScanner(homeDirectory: sandbox, systemLibraryURL: sysLib, safetyGuard: sg)
            .scanSystemPluginDirectories(computeSize: false)
        try runner.expectEqual(sysPlugins.map(\.identifier), ["com.other.ok"], "Protected plugin bundle ID must be skipped")
    }

    runner.run("R3 MS-V05: SafetyGuard blocks /var/db, /Volumes, /var/root, user TCC, protectedBundleIDs, UF_IMMUTABLE, and case variants") {
        let sandbox = try runner.makeTempSandbox(prefix: "r3-v05-sg")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default

        let keepApp = sandbox.appendingPathComponent("KeepApp.app")
        let selfApp = sandbox.appendingPathComponent("MacSweep.app")
        let sg = SafetyGuard(
            homeDirectory: sandbox,
            selfBundlePath: selfApp.path,
            protectedPaths: [keepApp.path],
            protectedBundleIDs: ["com.acme.keep"]
        )

        let mustBlock = [
            "/var/db",
            "/private/var/db",
            "/Library/Apple",
            "/usr/bin",
            "/usr/sbin",
            "/usr/lib",
            "/Volumes",
            "/var/root",
            "/private/var/root",
            "/var/root/secret",
            "/var/folders",
            "/private/var/folders",
            "/var/tmp",
            "/private/var/tmp",
            "/dev",
            "/Library/SystemExtensions",
            "/Library/SystemExtensions/ext.systemextension",
            "/Library/Security",
            "/Library/Security/Trust Settings/Admin.plist",
            sandbox.appendingPathComponent("Library/Application Support/com.apple.TCC").path,
            sandbox.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path,
            sandbox.appendingPathComponent("Library/Caches/com.acme.keep").path,
            sandbox.appendingPathComponent("Library/Group Containers/group.com.acme.keep").path,
            sandbox.appendingPathComponent("Library/LaunchAgents/com.acme.keep.helper.plist").path,
        ]
        for p in mustBlock {
            try runner.expect(!sg.validateForRemoval(URL(fileURLWithPath: p)).isAllowed, "Must block: \(p)")
        }

        // Case-insensitive helper checks & exact /Library/Apple symlink
        try runner.expect(sg.isUserProtected(bundleID: nil, url: URL(fileURLWithPath: keepApp.path.uppercased())))
        try runner.expect(sg.isSelfApp(bundleID: nil, url: URL(fileURLWithPath: selfApp.path.uppercased())))
        try runner.expect(sg.isSystemProtectedApp(at: URL(fileURLWithPath: "/LIBRARY/APPLE")))

        let appleExactLink = sandbox.appendingPathComponent("link-to-lib-apple")
        try fm.createSymbolicLink(at: appleExactLink, withDestinationURL: URL(fileURLWithPath: "/Library/Apple"))
        try runner.expect(sg.pointsToSystemVolume(appleExactLink), "Symlink to exact /Library/Apple must be detected")
        try runner.expect(sg.isProtectedFromLeftoverScan(name: "ABCDE12345.com.apple.notes", bundleID: nil),
                          "TeamID-prefixed Apple Group Container must be protected in leftover scan")
        try runner.expect(sg.isProtectedFromLeftoverScan(name: "unrelated", bundleID: "com.apple"),
                          "Bare com.apple bundleID must be protected in leftover scan")

        // UF_IMMUTABLE (uchg) is user-controlled: NOT classified as SIP, detected by isUserImmutable, remains removable
        let uchgFile = sandbox.appendingPathComponent("immutable.dat")
        try Data("locked".utf8).write(to: uchgFile)
        if chflags(uchgFile.path, UInt32(UF_IMMUTABLE)) == 0 {
            defer { _ = chflags(uchgFile.path, 0) }
            try runner.expect(!sg.isSIPRestricted(uchgFile), "UF_IMMUTABLE file must NOT be misclassified as SIP")
            try runner.expect(sg.isUserImmutable(uchgFile), "UF_IMMUTABLE file must be detected by isUserImmutable")
            try runner.expect(sg.validateForRemoval(uchgFile).isAllowed, "UF_IMMUTABLE non-system file must remain removable")
        }
    }

    runner.run("R3 MS-V06: StartupController blocks symlink LaunchDaemons domain elevation, newline paths, and StartupScanner protects bundleIDs") {
        let sandbox = try runner.makeTempSandbox(prefix: "r3-v06-startup")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default

        let userLA = sandbox.appendingPathComponent("Library/LaunchAgents")
        try fm.createDirectory(at: userLA, withIntermediateDirectories: true)
        let validPlist = userLA.appendingPathComponent("com.acme.agent.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.acme.agent", "Program": "/usr/bin/true"],
            format: .xml, options: 0
        ).write(to: validPlist)

        // 1. Symlink named "LaunchDaemons" pointing to userLA must be rejected (never escalated to `system`!)
        let symlinkLD = sandbox.appendingPathComponent("LaunchDaemons")
        try fm.createSymbolicLink(at: symlinkLD, withDestinationURL: userLA)
        let spoofedURL = symlinkLD.appendingPathComponent("com.acme.agent.plist")
        let targets = StartupController.launchTargets(for: [spoofedURL], uid: 501, allowedLaunchDirs: [userLA])
        try runner.expect(targets.isEmpty, "Symlinked LaunchDaemons parent must be rejected")

        // 2. Non-symlink directory named "LaunchDaemons" that is NOT systemLaunchDaemonsURL gets gui/<uid>, never system
        let fakeRealLD = sandbox.appendingPathComponent("Fake/LaunchDaemons")
        try fm.createDirectory(at: fakeRealLD, withIntermediateDirectories: true)
        let fakePlist = fakeRealLD.appendingPathComponent("com.acme.fake.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.acme.fake", "Program": "/usr/bin/true"],
            format: .xml, options: 0
        ).write(to: fakePlist)
        let nonSysTargets = StartupController.launchTargets(for: [fakePlist], uid: 501, allowedLaunchDirs: [fakeRealLD])
        try runner.expectEqual(nonSysTargets.first?.domain, "gui/501", "Non-/Library/LaunchDaemons dir must never elevate to system domain")

        // 3. Newline in plist filename rejected by launchTargets and buildToggleShellCommand
        let nlPlist = userLA.appendingPathComponent("com.acme.bad\nname.plist")
        try Data("{}".utf8).write(to: nlPlist)
        try runner.expect(StartupController.launchTargets(for: [nlPlist], uid: 501, allowedLaunchDirs: [userLA]).isEmpty,
                          "Plist path with newline must be rejected")

        // 4. buildUnloadShellCommand independently validates domain & label, checks [ ! -L ] and LC_ALL=C, emits index markers
        let badCmd = StartupController.buildUnloadShellCommand(targets: [
            LaunchServiceTarget(label: "com.apple.evil", domain: "system", plistURL: validPlist, labelFromPlist: "com.apple.evil"),
            LaunchServiceTarget(label: "com.acme.ok", domain: "invalid/domain", plistURL: validPlist, labelFromPlist: "com.acme.ok"),
        ])
        try runner.expect(!badCmd.contains("bootout"), "Invalid targets must fail closed without invoking bootout")
        try runner.expect(badCmd.contains("still-loaded-idx:0") && badCmd.contains("still-loaded-idx:1"))

        let unreadableCmd = StartupController.buildUnloadShellCommand(targets: [
            LaunchServiceTarget(label: "com.acme.root", domain: "system", plistURL: URL(fileURLWithPath: "/Library/LaunchDaemons/com.acme.root.plist"), labelFromPlist: nil),
        ])
        try runner.expect(unreadableCmd.contains("[ ! -L "), "Root PlistBuddy branch must verify non-symlink")
        try runner.expect(unreadableCmd.contains("LC_ALL=C"), "Unload script must pin LC_ALL=C")
        try runner.expectEqual(StartupController.parseStillLoadedIndices(from: "0:42: execution error: still-loaded-idx:2 (1)"), [2])

        // 5. StartupScanner rejects bare 'com.apple' and marks protectedBundleIDs as canRemove = false
        let bareApplePlist = userLA.appendingPathComponent("com.apple.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.apple", "Program": "/usr/bin/true"],
            format: .xml, options: 0
        ).write(to: bareApplePlist)
        let protPlist = userLA.appendingPathComponent("com.acme.protected.agent.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.acme.protected.agent", "Program": "/usr/bin/true"],
            format: .xml, options: 0
        ).write(to: protPlist)
        let sg = SafetyGuard(homeDirectory: sandbox, protectedBundleIDs: ["com.acme.protected"])
        let scanned = StartupScanner(
            userLaunchAgentsURL: userLA,
            systemLaunchAgentsURL: sandbox.appendingPathComponent("none1"),
            systemLaunchDaemonsURL: sandbox.appendingPathComponent("none2"),
            appSearchRoots: [],
            safetyGuard: sg
        ).scanAll(userDisabledMap: [:], systemDisabledMap: [:])
        try runner.expect(!scanned.contains { $0.label.lowercased() == "com.apple" }, "Bare com.apple must be filtered")
        let protItem = scanned.first { $0.label == "com.acme.protected.agent" }
        try runner.expect(protItem != nil)
        try runner.expectEqual(protItem?.canRemove, false, "Protected startup item must have canRemove = false")
    }

    runner.run("R3 MS-V08: safeProcessMatchBundleID blocks dropped, shared, and spoofed Apple apps from matching processes by bundle ID") {
        let sandbox = try runner.makeTempSandbox(prefix: "r3-v08-proc")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let droppedSpoof = AppItem(
            url: sandbox.appendingPathComponent("Downloads/Evil.app"),
            name: "Evil", localizedName: "Evil",
            bundleID: "com.1password.1password", version: "1"
        )
        try runner.expectEqual(AppScanner.safeProcessMatchBundleID(for: droppedSpoof, homeDirectory: sandbox), nil)

        let stdAppsDir = sandbox.appendingPathComponent("Applications")
        var sharedApp = AppItem(
            url: stdAppsDir.appendingPathComponent("Copy.app"),
            name: "Copy", localizedName: "Copy",
            bundleID: "com.acme.realapp", version: "1"
        )
        sharedApp.sharesBundleIDWithOtherApp = true
        try runner.expectEqual(AppScanner.safeProcessMatchBundleID(for: sharedApp, homeDirectory: sandbox), nil)

        let spoofAppleInStd = AppItem(
            url: stdAppsDir.appendingPathComponent("FakeFinder.app"),
            name: "FakeFinder", localizedName: "FakeFinder",
            bundleID: "com.apple.finder", version: "1",
            isAppleAppStoreApp: false
        )
        try runner.expectEqual(AppScanner.safeProcessMatchBundleID(for: spoofAppleInStd, homeDirectory: sandbox), nil)

        let legitApp = AppItem(
            url: stdAppsDir.appendingPathComponent("RealTool.app"),
            name: "RealTool", localizedName: "RealTool",
            bundleID: "com.acme.realtool", version: "1"
        )
        try runner.expectEqual(AppScanner.safeProcessMatchBundleID(for: legitApp, homeDirectory: sandbox), "com.acme.realtool")
    }

    runner.run("R3 MS-V09 & MS-H04: SafeFileReader blocks FIFOs/symlinks/oversize, DirectorySizer caps entries, display sanitizer & atomic 0600 store") {
        let sandbox = try runner.makeTempSandbox(prefix: "r3-v09-h04")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default

        // 1. FIFO must return nil immediately without blocking in SafeFileReader & scanners
        let fifo = sandbox.appendingPathComponent("hang.plist")
        try runner.expectEqual(mkfifo(fifo.path, 0o600), 0, "mkfifo should succeed")
        let t0 = Date()
        try runner.expectEqual(SafeFileReader.readBoundedRegularFile(at: fifo), nil, "FIFO must return nil")
        try runner.expectEqual(LibraryIndex.parseLaunchPlistMetadata(at: fifo).label, nil, "LibraryIndex must not hang on FIFO")
        try runner.expectEqual(StartupScanner(safetyGuard: SafetyGuard(homeDirectory: sandbox)).parseLaunchPlist(at: fifo, scope: .userAgent, disabledOverrides: [:]), nil)
        try runner.expect(Date().timeIntervalSince(t0) < 1.0, "FIFO reads must return instantaneously without blocking")

        // 2. Oversized file & symlink rejected
        let bigFile = sandbox.appendingPathComponent("big.bin")
        try Data(repeating: 0x41, count: 4096).write(to: bigFile)
        try runner.expectEqual(SafeFileReader.readBoundedRegularFile(at: bigFile, maxBytes: 1024), nil, "Oversized file must return nil")
        let exactRead = SafeFileReader.readBoundedRegularFile(at: bigFile, maxBytes: 4096)
        try runner.expectEqual(exactRead?.count, 4096)

        let linkToBig = sandbox.appendingPathComponent("link.bin")
        try fm.createSymbolicLink(at: linkToBig, withDestinationURL: bigFile)
        try runner.expectEqual(SafeFileReader.readBoundedRegularFile(at: linkToBig, maxBytes: 8192), nil, "Symlink must be rejected")

        // 3. DirectorySizer maxEntries cap
        let capDir = sandbox.appendingPathComponent("CapDir")
        try fm.createDirectory(at: capDir, withIntermediateDirectories: true)
        for i in 0..<10 {
            try Data(repeating: 0x42, count: 4096).write(to: capDir.appendingPathComponent("f\(i).dat"))
        }
        let capped = DirectorySizer.computeSizeSync(of: capDir, maxEntries: 2)
        let full = DirectorySizer.computeSizeSync(of: capDir, maxEntries: 100)
        try runner.expect(capped > 0 && capped < full, "maxEntries cap must bound directory traversal")

        // 4. Display sanitizer visibly escapes control chars & Unicode Bidi overrides (prevents visual path spoofing)
        let dirty = "/tmp/bad\u{202E}txt.app\u{0007}\n\u{2066}hidden"
        try runner.expectEqual(
            SafeFileReader.sanitizeForDisplay(dirty),
            "/tmp/bad\\u{202E}txt.app\\u{0007}\\n\\u{2066}hidden"
        )
        try runner.expect(SafeFileReader.sanitizeForDisplay("Evil\n.app") != "Evil.app",
                          "Control-char filename must remain visually distinct after sanitization")

        // 5. writePrivateAtomically refuses symlink targets & CleanupHistoryStore stays 0600 across concurrent appends
        let targetReal = sandbox.appendingPathComponent("real-protected.txt")
        try Data("orig".utf8).write(to: targetReal)
        let targetLink = sandbox.appendingPathComponent("evil-link.json")
        try fm.createSymbolicLink(at: targetLink, withDestinationURL: targetReal)
        try runner.expect(!SafeFileReader.writePrivateAtomically(Data("pwn".utf8), to: targetLink),
                          "writePrivateAtomically must refuse overwriting through a symlink")
        try runner.expectEqual(try String(contentsOf: targetReal, encoding: .utf8), "orig")

        let histURL = sandbox.appendingPathComponent("ConcurrentStore/history.json")
        let store = CleanupHistoryStore(fileURL: histURL)
        let group = DispatchGroup()
        for i in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                store.append(CleanupRecord(actionTitle: "Item \(i)", mode: .trash, itemCount: 1, freedBytes: 1, removedPaths: ["/tmp/\(i)"]))
                group.leave()
            }
        }
        group.wait()
        try runner.expectEqual(store.load().count, 8, "Locked CleanupHistoryStore must preserve all concurrent appends")
        let perm = (try fm.attributesOfItem(atPath: histURL.path)[.posixPermissions] as? NSNumber)?.intValue
        try runner.expectEqual(perm, 0o600)
    }

    // MARK: Security Audit Round 4 (R2) — P0/P1/P2 Hardening Regressions

    runner.run("R4 P0 MS-V02: blocks non-com.apple Apple Group Containers, plural groups., spoofed group.* & sensitive ~/Library TCC data") {
        let sandbox = try runner.makeTempSandbox(prefix: "r4-v02-groups")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default

        // 1. Plural `groups.` prefix stripping
        try runner.expectEqual(
            InstalledAppInventory.stripContainerPrefixes("243LU875E5.groups.com.apple.podcasts"),
            "com.apple.podcasts"
        )
        try runner.expectEqual(
            InstalledAppInventory.stripContainerPrefixes("groups.com.apple.podcasts"),
            "com.apple.podcasts"
        )
        try runner.expectEqual(
            InstalledAppInventory.stripContainerPrefixes("K36BKF7T3D.group.com.apple.configurator"),
            "com.apple.configurator"
        )

        // 2. Apple Group Container denylist + dynamic system app group harvesting
        let appleGroups = [
            "group.is.workflow.shortcuts",
            "group.is.workflow.my.app",
            "group.tvappservices.container",
            "243LU875E5.groups.com.apple.podcasts",
            "74J34U3R6X.com.apple.iWork",
            "K36BKF7T3D.group.com.apple.configurator",
            ".SiriTodayViewExtension",
            "AirPort",
            "cookies",
            "group.com.apple.notes",
            "com.apple.bird",
        ]
        for g in appleGroups {
            try runner.expect(SafetyGuard.isAppleGroupContainerName(g), "Must identify Apple Group Container: \(g)")
        }
        try runner.expect(!SafetyGuard.systemAppleApplicationGroups.isEmpty,
                          "Dynamic Apple system app-group harvester should find system groups on macOS")

        // 3. ServiceFileMatcher blocks spoofed Apple & third-party group.* containers (unsigned OR arbitrarily signed)
        let userLib = sandbox.appendingPathComponent("UserLib")
        let groupDir = userLib.appendingPathComponent("Group Containers")
        let mockGroupDirs = appleGroups + [
            "group.net.whatsapp.WhatsApp.shared",
            "group.com.acme.Tool",
            "group.com.acme.Tool.shared",
            "TEAM111111.com.acme.Tool",
            "TEAM111111.group.com.acme.Tool",
        ]
        for name in mockGroupDirs {
            try fm.createDirectory(at: groupDir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let sg = SafetyGuard(homeDirectory: sandbox)
        let idx = LibraryIndex.build(userLibraryURL: userLib, systemLibraryURL: sandbox.appendingPathComponent("SysLib"), safetyGuard: sg)
        let matcher = ServiceFileMatcher(safetyGuard: sg)

        let spoofApps: [AppItem] = [
            AppItem(url: sandbox.appendingPathComponent("SpoofWF1.app"), name: "SpoofWF1", localizedName: "SpoofWF1", bundleID: "is.workflow.shortcuts", version: "1"),
            AppItem(url: sandbox.appendingPathComponent("SpoofWF2.app"), name: "SpoofWF2", localizedName: "SpoofWF2", bundleID: "is.workflow.my.app", version: "1"),
            AppItem(url: sandbox.appendingPathComponent("SpoofTV.app"), name: "SpoofTV", localizedName: "SpoofTV", bundleID: "tvappservices.container", version: "1"),
            AppItem(url: sandbox.appendingPathComponent("SpoofPod.app"), name: "SpoofPod", localizedName: "SpoofPod", bundleID: "groups.com.apple.podcasts", version: "1"),
            AppItem(url: sandbox.appendingPathComponent("SpoofWAUnsigned.app"), name: "SpoofWAUnsigned", localizedName: "SpoofWAUnsigned", bundleID: "net.whatsapp.WhatsApp.shared", version: "1"),
            AppItem(url: sandbox.appendingPathComponent("SpoofWASigned.app"), name: "SpoofWASigned", localizedName: "SpoofWASigned", bundleID: "net.whatsapp.WhatsApp.shared", version: "1", teamIdentifier: "EVIL123456"),
            AppItem(url: sandbox.appendingPathComponent("SpoofTeamEnt.app"), name: "SpoofTeamEnt", localizedName: "SpoofTeamEnt", bundleID: "com.evil.ent", version: "1", teamIdentifier: "EVIL123456", applicationGroups: ["group.is.workflow.shortcuts", "TEAM111111.com.acme.Tool", "group.net.whatsapp.WhatsApp.shared"]),
        ]
        for spoof in spoofApps {
            let hits = matcher.matchInMemory(app: spoof, index: idx, allInstalledBundleIDs: ["net.whatsapp.WhatsApp"])
            try runner.expect(hits.isEmpty, "Spoofed app '\(spoof.name)' must match zero containers, got \(hits.map(\.displayName))")
        }

        // Direct matchesGroupContainer checks
        try runner.expect(!ServiceFileMatcher.matchesGroupContainer(entryName: "group.com.acme.Tool", bundleID: "com.acme.Tool", teamID: nil),
                          "Unsigned app without entitlement must NOT match group.<bundleID>")
        try runner.expect(!ServiceFileMatcher.matchesGroupContainer(entryName: "group.com.acme.Tool", bundleID: "com.acme.Tool", teamID: "EVIL123456"),
                          "Signed app without entitlement must NOT match group.<bundleID>")
        try runner.expect(!ServiceFileMatcher.matchesGroupContainer(entryName: "TEAM111111.com.acme.Tool", bundleID: "com.acme.Tool", teamID: nil),
                          "Unsigned app must NOT wildcard-match <TeamID>.<bundleID>")
        try runner.expect(ServiceFileMatcher.matchesGroupContainer(entryName: "group.com.acme.Tool.shared", bundleID: "com.acme.Tool", teamID: "TEAM111111", applicationGroups: ["group.com.acme.Tool.shared"]),
                          "Verified applicationGroups entitlement must match its declared group container")
        try runner.expect(ServiceFileMatcher.matchesGroupContainer(entryName: "TEAM111111.group.com.acme.Tool", bundleID: "com.acme.Tool", teamID: "TEAM111111"),
                          "Verified TeamID must match <TeamID>.group.<bundleID>")

        // 4. SafetyGuard recursively protects sensitive user/TCC dirs, Apple containers, and *.photoslibrary
        let sensitiveBlocked = [
            "Library/Mobile Documents/com~apple~CloudDocs/notes.txt",
            "Library/Application Support/AddressBook/Sources",
            "Library/Application Support/CallHistoryDB/CallHistory.storedata",
            "Library/Application Support/CallHistoryTransactions/tx.db",
            "Library/Application Support/MobileSync/Backup/device1",
            "Library/Application Support/CloudDocs/session",
            "Library/Application Support/FileProvider/db",
            "Library/Application Support/iCloud/Accounts",
            "Library/Application Support/FaceTime/cache",
            "Library/Application Support/Knowledge/knowledgeC.db",
            "Library/Application Support/Apple/AssetCache",
            "Library/Application Support/com.apple.ProtectedCloudStorage/key",
            "Library/Calendars/Calendar.sqlitedb",
            "Library/Reminders/Container_v1",
            "Library/Contacts/data",
            "Library/Accounts/Accounts4.sqlite",
            "Library/Biome/streams",
            "Library/Photos/Libraries",
            "Library/HomeKit/datastore",
            "Library/IdentityServices/ids.db",
            "Library/Passes/Cards",
            "Library/Finance/data",
            "Library/Shortcuts/Shortcuts.sqlite",
            "Library/Suggestions/snippets.db",
            "Library/CloudStorage/iCloudDrive",
            "Library/Daemon Containers/abc",
            "Pictures/Photos Library.photoslibrary",
            "Pictures/Photos Library.photoslibrary/database/Photos.sqlite",
            "CustomArchive/Family.photoslibrary/originals/img.jpg",
            "Library/Group Containers/group.is.workflow.shortcuts",
            "Library/Group Containers/group.is.workflow.my.app/data",
            "Library/Group Containers/group.tvappservices.container",
            "Library/Group Containers/243LU875E5.groups.com.apple.podcasts/DB",
            "Library/Group Containers/74J34U3R6X.com.apple.iWork",
            "Library/Group Containers/K36BKF7T3D.group.com.apple.configurator",
            "Library/Group Containers/.SiriTodayViewExtension",
            "Library/Group Containers/AirPort",
            "Library/Group Containers/cookies",
            "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite",
            "Library/Group Containers/com.apple.bird/data",
            "Library/Containers/com.apple.Safari/Data/Library/Preferences/com.apple.Safari.plist",
            "Library/Cookies/Cookies.binarycookies",
            "Library/Cookies/HSTS.plist",
        ]
        for rel in sensitiveBlocked {
            let url = sandbox.appendingPathComponent(rel)
            try runner.expect(!sg.validateForRemoval(url).isAllowed, "SafetyGuard must block sensitive user path: \(rel)")
        }

        // Legitimate third-party paths & Apple App Store preference plist remain allowed
        for rel in [
            "Library/Containers/com.acme.Tool",
            "Library/Group Containers/TEAM111111.com.acme.Tool",
            "Library/Cookies/com.acme.Tool.binarycookies",
            "Library/Preferences/com.apple.iWork.Pages.plist",
        ] {
            let url = sandbox.appendingPathComponent(rel)
            try runner.expect(sg.validateForRemoval(url).isAllowed, "SafetyGuard must still allow: \(rel)")
        }

        // 5. LeftoverScanner never flags non-com.apple Apple Group Containers
        let inv = InstalledAppInventory.build(searchRoots: [], libraryIndex: idx)
        let leftoverGroups = LeftoverScanner(safetyGuard: sg).scan(index: idx, inventory: inv)
        let leftoverNames = Set(leftoverGroups.flatMap { $0.files.map(\.displayName) })
        for g in appleGroups {
            try runner.expect(!leftoverNames.contains(g), "LeftoverScanner must not flag Apple Group Container: \(g)")
        }
    }

    runner.run("R4 P0 MS-V03/V04: scan-to-confirm parent TOCTOU blocked across normal/privileged/Firefox, deep trees (>64), and user EACCES without root") {
        let sandbox = try runner.makeTempSandbox(prefix: "r4-v03-v04-toctou")
        defer {
            // Ensure permissions are restored before cleanup
            if let enumerator = FileManager.default.enumerator(at: sandbox, includingPropertiesForKeys: nil) {
                for case let u as URL in enumerator {
                    _ = chmod(u.path, 0o755)
                }
            }
            _ = chmod(sandbox.path, 0o755)
            try? FileManager.default.removeItem(at: sandbox)
        }
        let fm = FileManager.default
        let sg = SafetyGuard(homeDirectory: sandbox)

        // 1. Scan-to-confirm TOCTOU: Firefox ExtensionItem & RemovalTarget scanned while parent is real,
        //    then parent is swapped to symlink pointing to sibling decoy BEFORE RemovalEngine.remove() runs.
        let ffProfile = sandbox.appendingPathComponent("Firefox/Profiles/p1")
        let ffExtDir = ffProfile.appendingPathComponent("extensions")
        let decoyDir = sandbox.appendingPathComponent("UserSiblingDecoy")
        try fm.createDirectory(at: ffExtDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: decoyDir, withIntermediateDirectories: true)

        let extFile = ffExtDir.appendingPathComponent("addon.xpi")
        let decoyVictim = decoyDir.appendingPathComponent("addon.xpi")
        try Data("orig-addon".utf8).write(to: extFile)
        try Data("precious-user-data".utf8).write(to: decoyVictim)

        let ffJSON = """
        {"addons":[{"id":"addon@test","location":"app-profile","type":"extension","path":"\(extFile.path)"}]}
        """
        let scannedExts = ExtensionScanner.parseFirefoxExtensionsJSON(
            Data(ffJSON.utf8),
            profileName: "p1",
            computeSize: false,
            profileDirectory: ffProfile,
            safetyGuard: sg
        )
        try runner.expectEqual(scannedExts.count, 1)
        let extItem = scannedExts[0]
        let scanTimeTarget = RemovalTarget(
            url: extItem.path,
            estimatedSize: extItem.size,
            requiresAdmin: false,
            expectedCanonicalParent: extItem.expectedCanonicalParent
        )
        let privScanTimeTarget = RemovalTarget(
            url: extItem.path,
            estimatedSize: extItem.size,
            requiresAdmin: true,
            expectedCanonicalParent: extItem.expectedCanonicalParent
        )

        // Attacker swaps <profile>/extensions -> symlink to decoyDir DURING user confirmation window!
        try fm.removeItem(at: ffExtDir)
        try fm.createSymbolicLink(at: ffExtDir, withDestinationURL: decoyDir)

        let privilegedInvoked = TestLockedBox(false)
        let spyExec = PrivilegedExecutor(
            safetyGuard: sg,
            trashDirectory: sandbox.appendingPathComponent("MockTrash"),
            adminShellRunner: { _ in
                privilegedInvoked.value = true
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            },
            finderAppleScriptRunner: { _ in
                privilegedInvoked.value = true
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        )
        let engine = RemovalEngine(safetyGuard: sg, privilegedExecutor: spyExec)

        for mode in [RemovalMode.permanent, RemovalMode.trash] {
            let r1 = engine.remove(targets: [scanTimeTarget], mode: mode, allowElevation: false)
            try runner.expect(!r1.isFullSuccess && r1.succeededURLs.isEmpty, "Normal \(mode) must block scan-to-confirm TOCTOU")
            try runner.expect(fm.fileExists(atPath: decoyVictim.path), "Decoy file must stay intact after normal \(mode)")

            let r2 = engine.remove(targets: [privScanTimeTarget], mode: mode, allowElevation: true)
            try runner.expect(!r2.isFullSuccess && r2.succeededURLs.isEmpty, "Privileged \(mode) must block scan-to-confirm TOCTOU")
            try runner.expect(!privilegedInvoked.value, "Privileged executor must NOT even be invoked when scan-time parent drifted")
            try runner.expect(fm.fileExists(atPath: decoyVictim.path), "Decoy file must stay intact after privileged \(mode)")
        }

        // Direct PrivilegedExecutor build methods must also reject stale expectedCanonicalParents
        let staleParents = [extItem.path.standardizedFileURL.path: extItem.expectedCanonicalParent]
        for checkName in ["permanent", "trash", "finder"] {
            var blocked = false
            do {
                switch checkName {
                case "permanent":
                    _ = try spyExec.buildPermanentDeleteShellCommand(urls: [extItem.path], expectedCanonicalParents: staleParents)
                case "trash":
                    _ = try spyExec.buildPrivilegedTrashShellCommand(urls: [extItem.path], trashDirectory: sandbox.appendingPathComponent("MockTrash"), expectedCanonicalParents: staleParents)
                default:
                    _ = try spyExec.buildFinderTrashAppleScript(urls: [extItem.path], expectedCanonicalParents: staleParents)
                }
            } catch PrivilegedError.blockedBySafetyGuard {
                blocked = true
            }
            try runner.expect(blocked, "PrivilegedExecutor.\(checkName) must reject stale scan-time expectedCanonicalParent")
        }

        // 2. Deep directory tree (> 64, e.g. depth 85) deletes cleanly with zero mid-deletion ELOOP failure
        let deepRoot = sandbox.appendingPathComponent("DeepTree")
        var cur = deepRoot
        for i in 0..<85 {
            cur = cur.appendingPathComponent("d\(i)")
        }
        try fm.createDirectory(at: cur, withIntermediateDirectories: true)
        try Data("leaf".utf8).write(to: cur.appendingPathComponent("leaf.txt"))
        try Data("mid".utf8).write(to: deepRoot.appendingPathComponent("d0/d1/mid.txt"))

        let deepReport = engine.remove(targets: [RemovalTarget(url: deepRoot)], mode: .permanent, allowElevation: false)
        try runner.expect(deepReport.isFullSuccess, "Depth-85 tree must delete cleanly without depth-64 ELOOP cliff: \(deepReport.failures.map(\.reason))")
        try runner.expect(!RemovalEngine.entryExists(deepRoot), "DeepTree must be completely removed")

        // 3. User-owned unreadable (0000) & read-only (0500) subdirs AND -wx (0300) parent delete WITHOUT escalating to root
        let permTree = sandbox.appendingPathComponent("UserPermTree")
        let dir000 = permTree.appendingPathComponent("unreadable000")
        let dir0500 = permTree.appendingPathComponent("readonly0500")
        try fm.createDirectory(at: dir000, withIntermediateDirectories: true)
        try fm.createDirectory(at: dir0500, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: dir000.appendingPathComponent("inside000.txt"))
        try Data("b".utf8).write(to: dir0500.appendingPathComponent("inside0500.txt"))
        chmod(dir000.path, 0o000)
        chmod(dir0500.path, 0o500)

        let wxParent = sandbox.appendingPathComponent("wx-parent")
        try fm.createDirectory(at: wxParent, withIntermediateDirectories: true)
        let wxChild = wxParent.appendingPathComponent("target-in-wx.txt")
        try Data("c".utf8).write(to: wxChild)
        let wxTarget = RemovalTarget(url: wxChild)
        chmod(wxParent.path, 0o300)
        defer { chmod(wxParent.path, 0o755) }

        privilegedInvoked.value = false
        let permReport = engine.remove(
            targets: [RemovalTarget(url: permTree), wxTarget],
            mode: .permanent,
            allowElevation: true
        )
        try runner.expect(permReport.isFullSuccess, "User-owned 0000/0500 subdirs & 0300 parent must delete locally: \(permReport.failures.map(\.reason))")
        try runner.expect(!privilegedInvoked.value, "Must NOT blindly escalate to root for user-owned unreadable subdirs or -wx parent")
        try runner.expect(!RemovalEngine.entryExists(permTree))
        try runner.expect(!RemovalEngine.entryExists(wxChild))
    }

    runner.run("R4 P1 MS-V05: user-locked (uchg) non-system app/LaunchAgent stays visible, canUninstall=true, and unlocks cleanly on removal") {
        let sandbox = try runner.makeTempSandbox(prefix: "r4-v05-uchg")
        defer {
            if let enumerator = FileManager.default.enumerator(at: sandbox, includingPropertiesForKeys: nil) {
                for case let u as URL in enumerator {
                    _ = chflags(u.path, 0)
                }
            }
            try? FileManager.default.removeItem(at: sandbox)
        }
        let fm = FileManager.default
        let sg = SafetyGuard(homeDirectory: sandbox)

        let appsDir = sandbox.appendingPathComponent("Applications")
        let lockedApp = appsDir.appendingPathComponent("AdwareLocked.app")
        try fm.createDirectory(at: lockedApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.adware.locked", "CFBundleName": "AdwareLocked", "CFBundleExecutable": "AdwareLocked"],
            format: .xml, options: 0
        ).write(to: lockedApp.appendingPathComponent("Contents/Info.plist"))
        try Data("#!/bin/sh\n".utf8).write(to: lockedApp.appendingPathComponent("Contents/MacOS/AdwareLocked"))

        let userLA = sandbox.appendingPathComponent("Library/LaunchAgents")
        try fm.createDirectory(at: userLA, withIntermediateDirectories: true)
        let lockedPlist = userLA.appendingPathComponent("com.adware.locked.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.adware.locked", "Program": "/usr/bin/true"],
            format: .xml, options: 0
        ).write(to: lockedPlist)

        guard chflags(lockedApp.path, UInt32(UF_IMMUTABLE)) == 0,
              chflags(lockedPlist.path, UInt32(UF_IMMUTABLE)) == 0 else {
            return
        }

        // 1. Not classified as SIP or system-protected; visible in scanApplications(showSystemApps: false)
        try runner.expect(!sg.isSIPRestricted(lockedApp))
        try runner.expect(sg.isUserImmutable(lockedApp))
        try runner.expect(!sg.isSystemProtectedApp(at: lockedApp))
        try runner.expect(sg.validateForRemoval(lockedApp).isAllowed)

        let scannedApps = AppScanner(searchRoots: [appsDir], showSystemApps: false, safetyGuard: sg).scanApplications()
        try runner.expectEqual(scannedApps.count, 1, "User-locked (uchg) non-system app must stay visible")
        try runner.expectEqual(scannedApps.first?.canUninstall, true, "User-locked non-system app must have canUninstall = true")

        let scannedStartups = StartupScanner(
            userLaunchAgentsURL: userLA,
            systemLaunchAgentsURL: sandbox.appendingPathComponent("none1"),
            systemLaunchDaemonsURL: sandbox.appendingPathComponent("none2"),
            appSearchRoots: [],
            safetyGuard: sg
        ).scanAll(userDisabledMap: [:], systemDisabledMap: [:])
        try runner.expectEqual(scannedStartups.first?.canRemove, true, "User-locked LaunchAgent must have canRemove = true")

        // 2. Confirmed removal unlocks uchg cleanly in BOTH permanent & trash modes
        let mockTrash = sandbox.appendingPathComponent("MockTrash")
        try fm.createDirectory(at: mockTrash, withIntermediateDirectories: true)
        let engine = RemovalEngine(
            safetyGuard: sg,
            localTrashHandler: { url in
                try FileManager.default.moveItem(at: url, to: mockTrash.appendingPathComponent(url.lastPathComponent))
            }
        )
        let permRep = engine.remove(targets: [RemovalTarget(url: lockedApp)], mode: .permanent, allowElevation: false)
        try runner.expect(permRep.isFullSuccess, "Permanent removal must unlock and delete uchg app: \(permRep.failures.map(\.reason))")
        try runner.expect(!RemovalEngine.entryExists(lockedApp))

        let trashRep = engine.remove(targets: [RemovalTarget(url: lockedPlist)], mode: .trash, allowElevation: false)
        try runner.expect(trashRep.isFullSuccess, "Trash removal must unlock and move uchg plist: \(trashRep.failures.map(\.reason))")
        try runner.expect(!RemovalEngine.entryExists(lockedPlist))
        try runner.expect(fm.fileExists(atPath: mockTrash.appendingPathComponent(lockedPlist.lastPathComponent).path))
    }

    runner.run("R4 P1 MS-V02 & MS-V08: anchor apple generic TeamID, executableName no TeamID bypass, Rule 2 LaunchDaemon unselected, PID signing verification") {
        let sandbox = try runner.makeTempSandbox(prefix: "r4-v02-v08")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let sg = SafetyGuard(homeDirectory: sandbox)

        // 1. Ad-hoc signed app fails `anchor apple generic` -> extractTeamIdentifier == nil, extractApplicationGroups == []
        let adhocApp = sandbox.appendingPathComponent("Adhoc.app")
        try fm.createDirectory(at: adhocApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.evil.adhoc", "CFBundleName": "Adhoc", "CFBundleExecutable": "Adhoc"],
            format: .xml, options: 0
        ).write(to: adhocApp.appendingPathComponent("Contents/Info.plist"))
        try fm.copyItem(atPath: "/usr/bin/true", toPath: adhocApp.appendingPathComponent("Contents/MacOS/Adhoc").path)
        _ = ProcessRunner.run(executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", adhocApp.path])
        try runner.expectEqual(AppScanner.extractTeamIdentifier(at: adhocApp), nil, "Ad-hoc signed app must not satisfy anchor apple generic")
        try runner.expect(AppScanner.extractApplicationGroups(at: adhocApp).isEmpty)
        try runner.expectEqual(AppScanner.extractAppSigningIdentity(at: adhocApp), nil)

        // Real Apple system app (Shortcuts.app) satisfies anchor apple generic and exposes its application-groups
        let shortcutsURL = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
        if fm.fileExists(atPath: shortcutsURL.path) {
            let shortcutsMeta = AppScanner.extractSigningMetadata(at: shortcutsURL)
            try runner.expectEqual(shortcutsMeta.identity?.isAppleSigned, true)
            try runner.expect(shortcutsMeta.applicationGroups.contains { $0.lowercased() == "group.is.workflow.shortcuts" },
                              "Shortcuts.app must expose group.is.workflow.shortcuts entitlement")
        }

        // 2. Signed app with non-empty TeamID still enforces isExecutableNameRelated (no free-pass bypass!)
        let userLib = sandbox.appendingPathComponent("UserLib")
        let sysLib = sandbox.appendingPathComponent("SysLib")
        try fm.createDirectory(at: userLib.appendingPathComponent("Application Support/Google/Chrome"), withIntermediateDirectories: true)
        try fm.createDirectory(at: sysLib.appendingPathComponent("LaunchDaemons"), withIntermediateDirectories: true)
        try fm.createDirectory(at: userLib.appendingPathComponent("LaunchAgents"), withIntermediateDirectories: true)

        let signedEvilExec = AppItem(
            url: sandbox.appendingPathComponent("Innocent.app"),
            name: "Innocent",
            localizedName: "Innocent",
            bundleID: "com.evil.innocent",
            version: "1",
            executableName: "Chrome",
            teamIdentifier: "EVIL123456"
        )
        try runner.expect(!ServiceFileMatcher.nameCandidates(for: signedEvilExec).contains("chrome"),
                          "Signed app with TeamID must NOT bypass isExecutableNameRelated")

        // 3. Rule 2 LaunchDaemon & LaunchAgent (matched only by label without Rule 1 binary inside .app) default isSelected = false
        let realToolApp = sandbox.appendingPathComponent("AcmeTool.app")
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.acme.tool.daemon", "Program": "/usr/local/bin/unrelated"],
            format: .xml, options: 0
        ).write(to: sysLib.appendingPathComponent("LaunchDaemons/com.acme.tool.daemon.plist"))
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.acme.tool.agent", "Program": "/usr/local/bin/unrelated"],
            format: .xml, options: 0
        ).write(to: userLib.appendingPathComponent("LaunchAgents/com.acme.tool.agent.plist"))
        try PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.helper.verified", "ProgramArguments": [realToolApp.appendingPathComponent("Contents/MacOS/Helper").path]],
            format: .xml, options: 0
        ).write(to: userLib.appendingPathComponent("LaunchAgents/com.helper.verified.plist"))

        let idx = LibraryIndex.build(userLibraryURL: userLib, systemLibraryURL: sysLib, safetyGuard: sg)
        let matcher = ServiceFileMatcher(safetyGuard: sg)
        try runner.expect(matcher.matchInMemory(app: signedEvilExec, index: idx).isEmpty,
                          "Signed app with spoofed executableName 'Chrome' must match nothing")

        let acmeApp = AppItem(url: realToolApp, name: "AcmeTool", localizedName: "AcmeTool", bundleID: "com.acme.tool", version: "1")
        let acmeMatches = matcher.matchInMemory(app: acmeApp, index: idx)
        let rule2Daemon = acmeMatches.first { $0.displayName == "com.acme.tool.daemon.plist" }
        let rule2Agent = acmeMatches.first { $0.displayName == "com.acme.tool.agent.plist" }
        let rule1Agent = acmeMatches.first { $0.displayName == "com.helper.verified.plist" }
        try runner.expect(rule2Daemon != nil && rule2Daemon?.isSelected == false, "Rule 2 LaunchDaemon must default isSelected = false")
        try runner.expect(rule2Agent != nil && rule2Agent?.isSelected == false, "Rule 2 LaunchAgent must default isSelected = false")
        try runner.expect(rule1Agent != nil && rule1Agent?.isSelected == true, "Rule 1 binary-owned LaunchAgent must default isSelected = true")

        // 4. MS-V08 PID signing verification refuses mismatched TeamID / unsigned spoofed .app, allows in-bundle & matching TeamID
        let fakeInStd = sandbox.appendingPathComponent("Applications/Fake1P.app")
        let victimIdentity = CodeSigningIdentity(teamIdentifier: "2BUA8C4S2C", signingIdentifier: "com.1password.1password", isAppleSigned: false)
        let evilIdentity = CodeSigningIdentity(teamIdentifier: "EVIL123456", signingIdentifier: "com.evil.spoof", isAppleSigned: false)

        // Unsigned app in standard ~/Applications cannot terminate unrelated PID by bundleID
        let fakePID: pid_t = getpid() == 1 ? 2 : (getpid() - 1)
        try runner.expect(!AppScanner.isProcessAuthorizedForAppMatch(
            pid: fakePID,
            processBundleID: "com.1password.1password",
            processBundleURL: URL(fileURLWithPath: "/Applications/1Password.app"),
            processExecutableURL: URL(fileURLWithPath: "/Applications/1Password.app/Contents/MacOS/1Password"),
            targetBundleIDs: ["com.1password.1password"],
            targetAppURLs: [fakeInStd],
            cachedAppIdentities: [],
            processIdentityOverride: victimIdentity
        ), "Unsigned spoofed app must NEVER be authorized to terminate unrelated PID by bundleID")

        // Differently signed app cannot terminate unrelated PID by bundleID
        try runner.expect(!AppScanner.isProcessAuthorizedForAppMatch(
            pid: fakePID,
            processBundleID: "com.1password.1password",
            processBundleURL: URL(fileURLWithPath: "/Applications/1Password.app"),
            processExecutableURL: URL(fileURLWithPath: "/Applications/1Password.app/Contents/MacOS/1Password"),
            targetBundleIDs: ["com.1password.1password"],
            targetAppURLs: [fakeInStd],
            cachedAppIdentities: [evilIdentity],
            processIdentityOverride: victimIdentity
        ), "App with different TeamID must NEVER terminate victim PID by bundleID")

        // Shared-TeamID Apple apps (Pages vs Keynote) must NOT cross-terminate
        let pagesID = CodeSigningIdentity(teamIdentifier: "74J34U3R6X", signingIdentifier: "com.apple.iWork.Pages", isAppleSigned: true)
        let keynoteID = CodeSigningIdentity(teamIdentifier: "74J34U3R6X", signingIdentifier: "com.apple.iWork.Keynote", isAppleSigned: true)
        try runner.expect(!keynoteID.matchesAppIdentity(pagesID), "Distinct Apple signed identifiers must not cross-match")

        // Process running FROM inside the uninstalling unsigned app IS authorized
        try runner.expect(AppScanner.isProcessAuthorizedForAppMatch(
            pid: fakePID,
            processBundleID: "com.evil.helper",
            processBundleURL: fakeInStd.appendingPathComponent("Contents/Library/LoginItems/Helper.app"),
            processExecutableURL: fakeInStd.appendingPathComponent("Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper"),
            targetBundleIDs: [],
            targetAppURLs: [fakeInStd],
            cachedAppIdentities: [],
            processIdentityOverride: nil
        ), "In-bundle process must be authorized even for unsigned app")

        // Matching verified TeamID + matching bundleID IS authorized
        try runner.expect(AppScanner.isProcessAuthorizedForAppMatch(
            pid: fakePID,
            processBundleID: "com.1password.1password",
            processBundleURL: URL(fileURLWithPath: "/Applications/1Password.app"),
            processExecutableURL: nil,
            targetBundleIDs: ["com.1password.1password"],
            targetAppURLs: [URL(fileURLWithPath: "/Applications/1Password.app")],
            cachedAppIdentities: [victimIdentity],
            processIdentityOverride: victimIdentity
        ), "Matching verified TeamID + bundleID must be authorized")

        // Self PID is never authorized for termination
        try runner.expect(!AppScanner.isProcessAuthorizedForAppMatch(
            pid: getpid(),
            processBundleID: "com.1password.1password",
            processBundleURL: URL(fileURLWithPath: "/Applications/1Password.app"),
            processExecutableURL: nil,
            targetBundleIDs: ["com.1password.1password"],
            targetAppURLs: [URL(fileURLWithPath: "/Applications/1Password.app")],
            cachedAppIdentities: [victimIdentity],
            processIdentityOverride: victimIdentity
        ), "Current process PID must never be authorized for self-termination")

        // Live SecCodeCopyGuestWithAttributes check against a real running process (Finder / launchd)
        let launchdIdentity = AppScanner.extractProcessSigningIdentity(pid: 1)
        if let launchdIdentity {
            try runner.expect(launchdIdentity.isAppleSigned, "PID 1 (launchd) must be verified as Apple-signed")
        }
        try runner.expect(!AppScanner.isProcessAuthorizedForAppMatch(
            pid: 1,
            processBundleID: "com.apple.finder",
            processBundleURL: nil,
            processExecutableURL: nil,
            targetBundleIDs: ["com.apple.finder"],
            targetAppURLs: [adhocApp]
        ), "Ad-hoc spoofed app must NEVER be authorized against a real Apple-signed PID")

        // Empty bundleURLs with default allowBundleIDOnlyWithoutAppURL=false refuses to terminate anything
        let sem = DispatchSemaphore(value: 0)
        let emptyResult = TestLockedBox<[String]>(["sentinel"])
        Task {
            emptyResult.value = await RemovalEngine.terminateRunningApps(bundleIDs: ["com.apple.finder"], bundleURLs: [])
            sem.signal()
        }
        sem.wait()
        try runner.expect(emptyResult.value.isEmpty, "terminateRunningApps with empty bundleURLs must refuse by default")
    }

    runner.run("R4 P2 MS-V09/H04/V01: oversized stores refuse overwrite, >1MB plist truncated preview, DirectorySizer no-cache on truncation, stranded trash path surfaced") {
        let sandbox = try runner.makeTempSandbox(prefix: "r4-p2-polish")
        defer {
            _ = chmod(sandbox.appendingPathComponent("unreadable-prefs.json").path, 0o600)
            try? FileManager.default.removeItem(at: sandbox)
        }
        let fm = FileManager.default

        // 1. MS-V09: Oversized PreferencesStore (>1 MB) refuses to overwrite on save() (preserves protectedBundleIDs!)
        let bigPrefURL = sandbox.appendingPathComponent("preferences.json")
        let padding = String(repeating: "x", count: 1_100_000)
        let bigPrefPayload = "{\"protectedBundleIDs\":[\"com.acme.precious\"],\"note\":\"\(padding)\"}"
        try Data(bigPrefPayload.utf8).write(to: bigPrefURL)
        let prefStore = PreferencesStore(fileURL: bigPrefURL)
        _ = prefStore.load()
        try runner.expect(prefStore.isWriteBlockedDueToLoadError, "Oversized preferences.json must activate write-block")
        try runner.expectEqual(prefStore.save(SweepPreferences()), false, "save() must refuse overwriting oversized preferences.json")
        let onDiskPref = try Data(contentsOf: bigPrefURL)
        try runner.expectEqual(onDiskPref.count, bigPrefPayload.utf8.count, "Original oversized preferences.json must remain intact")

        // Unreadable preferences.json (chmod 000) also activates write-block
        let unreadablePrefURL = sandbox.appendingPathComponent("unreadable-prefs.json")
        try Data("{\"protectedBundleIDs\":[\"com.acme.keep\"]}".utf8).write(to: unreadablePrefURL)
        chmod(unreadablePrefURL.path, 0o000)
        let unreadableStore = PreferencesStore(fileURL: unreadablePrefURL)
        _ = unreadableStore.load()
        try runner.expect(unreadableStore.isWriteBlockedDueToLoadError)
        try runner.expectEqual(unreadableStore.save(SweepPreferences()), false)
        chmod(unreadablePrefURL.path, 0o600)
        try runner.expect(try String(contentsOf: unreadablePrefURL, encoding: .utf8).contains("com.acme.keep"))

        // 2. MS-V09: Oversized CleanupHistoryStore (>4 MB) refuses overwrite on append() and clear()
        let bigHistURL = sandbox.appendingPathComponent("history.json")
        let bigHistData = Data(repeating: 0x20, count: 4_200_000)
        try bigHistData.write(to: bigHistURL)
        let histStore = CleanupHistoryStore(fileURL: bigHistURL)
        _ = histStore.load()
        try runner.expect(histStore.isWriteBlockedDueToLoadError)
        try runner.expectEqual(
            histStore.append(CleanupRecord(actionTitle: "New", mode: .trash, itemCount: 1, freedBytes: 1, removedPaths: ["/tmp/x"])),
            false,
            "append() must refuse overwriting oversized history.json"
        )
        try runner.expectEqual(histStore.clear(), false, "clear() must refuse overwriting oversized history.json")
        try runner.expectEqual(try Data(contentsOf: bigHistURL).count, bigHistData.count)

        // 3. MS-V09: >1 MB XML and binary plists produce clear truncated previews instead of blank nil
        let bigXMLPlist = sandbox.appendingPathComponent("big-xml.plist")
        let xmlHead = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist><dict><key>Label</key><string>com.acme.big</string>"
        let xmlBody = String(repeating: "<string>aaaa</string>", count: 60_000)
        try Data((xmlHead + xmlBody + "</dict></plist>").utf8).write(to: bigXMLPlist)
        let xmlPreview = StartupScanner.loadPlistPreview(at: bigXMLPlist)
        try runner.expect(xmlPreview != nil, ">1 MB XML plist must return bounded preview, not nil")
        try runner.expect(xmlPreview?.contains("com.acme.big") == true)
        try runner.expect(xmlPreview?.contains("Preview truncated") == true)

        let bigBinPlist = sandbox.appendingPathComponent("big-bin.plist")
        var binData = Data("bplist00".utf8)
        binData.append(Data(repeating: 0x00, count: 1_100_000))
        try binData.write(to: bigBinPlist)
        let binPreview = StartupScanner.loadPlistPreview(at: bigBinPlist)
        try runner.expect(binPreview?.contains("Preview truncated") == true && binPreview?.contains("binary plist") == true,
                          ">1 MB binary plist must display a clear truncation notice")

        // 4. MS-H04: DirectorySizer tracks isTruncated and refuses to permanently cache truncated undercounts
        let capDir = sandbox.appendingPathComponent("SizerTruncDir")
        try fm.createDirectory(at: capDir, withIntermediateDirectories: true)
        for i in 0..<8 {
            try Data(repeating: 0x42, count: 4096).write(to: capDir.appendingPathComponent("f\(i).dat"))
        }
        let truncMeas = DirectorySizer.measureSizeSync(of: capDir, maxEntries: 2)
        let fullMeas = DirectorySizer.measureSizeSync(of: capDir, maxEntries: 100)
        try runner.expect(truncMeas.isTruncated, "Capped measurement must set isTruncated = true")
        try runner.expect(!fullMeas.isTruncated, "Uncapped measurement must set isTruncated = false")

        let sizer = DirectorySizer()
        let sem = DispatchSemaphore(value: 0)
        let firstBytes = TestLockedBox<Int64>(0)
        let cachedAfterTrunc = TestLockedBox<Bool>(true)
        let secondBytes = TestLockedBox<Int64>(0)
        let cachedAfterFull = TestLockedBox<Bool>(false)
        Task {
            firstBytes.value = await sizer.size(of: capDir, useCache: true, maxEntries: 2)
            cachedAfterTrunc.value = await sizer.isCached(path: capDir.path)
            secondBytes.value = await sizer.size(of: capDir, useCache: true, maxEntries: 100)
            cachedAfterFull.value = await sizer.isCached(path: capDir.path)
            sem.signal()
        }
        sem.wait()
        try runner.expect(!cachedAfterTrunc.value, "Truncated undercount MUST NOT be cached")
        try runner.expect(secondBytes.value > firstBytes.value && secondBytes.value == fullMeas.bytes, "Subsequent full sizing must return true full size")
        try runner.expect(cachedAfterFull.value, "Authoritative full measurement should be cached")

        // 5. MS-V01: PrivilegedExecutor checks regular files for root-owned-trash AND surfaces stranded staging path
        let sg = SafetyGuard(homeDirectory: sandbox)
        let regularTarget = sandbox.appendingPathComponent("root-file.plist")
        try Data("p".utf8).write(to: regularTarget)
        let trashScript = try PrivilegedExecutor(safetyGuard: sg).buildPrivilegedTrashShellCommand(
            urls: [regularTarget],
            trashDirectory: sandbox.appendingPathComponent("Trash"),
            timestamp: "v01"
        )
        try runner.expect(trashScript.contains("[ -d \"$staged\" ] || [ -f \"$staged\" ]"),
                          "root-owned-trash check must cover regular files as well as directories")
        try runner.expect(trashScript.contains("trash-stranded-idx:"),
                          "Privileged trash script must emit trash-stranded-idx when rollback fails or is skipped")

        let strandedStagePath = "/private/var/root/.macsweep-trash.xyz/item_0"
        let finderFail: PrivilegedExecutor.ScriptRunner = { _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "Not authorized (-1743)")
        }
        let strandedRunner: PrivilegedExecutor.ScriptRunner = { _ in
            try? FileManager.default.removeItem(at: regularTarget)
            return ProcessResult(
                exitCode: 1,
                stdout: "",
                stderr: "trash-stranded-idx:0:\(strandedStagePath)\ntrash-move-failed-idx:0\ntrash-move-failed:\(regularTarget.path)\n"
            )
        }
        let strandedExec = PrivilegedExecutor(
            safetyGuard: sg,
            trashDirectory: sandbox.appendingPathComponent("Trash"),
            adminShellRunner: strandedRunner,
            finderAppleScriptRunner: finderFail
        )
        let strandedRep = RemovalEngine(safetyGuard: sg, privilegedExecutor: strandedExec).remove(
            targets: [RemovalTarget(url: regularTarget, estimatedSize: 1, requiresAdmin: true)],
            mode: .trash
        )
        try runner.expect(!strandedRep.isFullSuccess)
        try runner.expect(strandedRep.failures.first?.reason.contains(strandedStagePath) == true,
                          "Failure message must surface exact stranded staging path")
        try runner.expect(strandedRep.warnings.contains { $0.contains(strandedStagePath) },
                          "Warnings must surface exact stranded staging path")
    }

    runner.run("R4-V2 Verifier Regressions: group.* entitlement spoof, shared Office suite containers, symlink .app kill/sig-borrow, and external 0300 parent mode preservation") {
        let sandbox = try runner.makeTempSandbox(prefix: "r4-v2-regress")
        defer {
            if let enumerator = FileManager.default.enumerator(at: sandbox, includingPropertiesForKeys: nil) {
                for case let u as URL in enumerator {
                    _ = chflags(u.path, 0)
                    _ = chmod(u.path, 0o755)
                }
            }
            _ = chmod(sandbox.path, 0o755)
            try? FileManager.default.removeItem(at: sandbox)
        }
        let fm = FileManager.default
        let sg = SafetyGuard(homeDirectory: sandbox)

        // 1. MS-V02: Arbitrary Apple Development signer declaring unrelated third-party `group.*` entitlements
        //    AND shared Microsoft Office suite containers across Word/Excel/PowerPoint
        let userLib = sandbox.appendingPathComponent("UserLib")
        let groupDir = userLib.appendingPathComponent("Group Containers")
        let spoofedThirdPartyGroups = [
            "group.net.whatsapp.family",
            "group.com.facebook.family",
            "group.com.firecore.shared",
            "group.com.jinghaoshe.qspace.shared",
        ]
        let sharedOfficeGroups = [
            "UBF8T346G9.Office",
            "UBF8T346G9.ms",
            "UBF8T346G9.com.microsoft.entrabroker",
            "UBF8T346G9.com.microsoft.oneauth",
            "UBF8T346G9.group.com.microsoft.shared",
            "UBF8T346G9.OfficeOsfWebHost",
            "UBF8T346G9.OfficeOneDriveSyncIntegration",
        ]
        for g in spoofedThirdPartyGroups + sharedOfficeGroups + ["UBF8T346G9.com.microsoft.Word.only"] {
            try fm.createDirectory(at: groupDir.appendingPathComponent(g), withIntermediateDirectories: true)
        }
        let idx = LibraryIndex.build(userLibraryURL: userLib, systemLibraryURL: sandbox.appendingPathComponent("SysLib"), safetyGuard: sg)
        let matcher = ServiceFileMatcher(safetyGuard: sg)

        // 1a. `com.evil.spoof` with arbitrary Apple Dev TeamID + self-declared `group.*` entitlements matches ZERO even without other apps installed
        let evilSpoofApp = AppItem(
            url: sandbox.appendingPathComponent("Applications/EvilSpoof.app"),
            name: "EvilSpoof",
            localizedName: "EvilSpoof",
            bundleID: "com.evil.spoof",
            version: "1",
            teamIdentifier: "ZA54QAYB93",
            applicationGroups: spoofedThirdPartyGroups
        )
        let evilHits = matcher.matchInMemory(app: evilSpoofApp, index: idx)
        try runner.expect(evilHits.isEmpty, "com.evil.spoof must NOT claim unrelated group.* via self-declared entitlements, got \(evilHits.map(\.displayName))")

        // 1b. Even if attacker sets bundleID = `net.whatsapp.family`, installed WhatsApp owning `group.net.whatsapp.family` blocks it
        let whatsApp = AppItem(
            url: sandbox.appendingPathComponent("Applications/WhatsApp.app"),
            name: "WhatsApp",
            localizedName: "WhatsApp",
            bundleID: "net.whatsapp.WhatsApp",
            version: "1",
            teamIdentifier: "57T9237FN3",
            applicationGroups: ["group.net.whatsapp.family"]
        )
        let evilSameSubID = AppItem(
            url: sandbox.appendingPathComponent("Applications/EvilWA.app"),
            name: "EvilWA",
            localizedName: "EvilWA",
            bundleID: "net.whatsapp.family",
            version: "1",
            teamIdentifier: "ZA54QAYB93",
            applicationGroups: ["group.net.whatsapp.family"]
        )
        let waOwners = ServiceFileMatcher.applicationGroupOwners(across: [whatsApp, evilSameSubID])
        let waOtherGroups = ServiceFileMatcher.otherInstalledApplicationGroups(for: evilSameSubID, groupOwners: waOwners)
        let evilWAHits = matcher.matchInMemory(
            app: evilSameSubID,
            index: idx,
            allInstalledBundleIDs: ["net.whatsapp.whatsapp"],
            otherInstalledAppGroups: waOtherGroups
        )
        try runner.expect(evilWAHits.isEmpty, "Installed WhatsApp's declared group.* must block spoofed app claiming net.whatsapp.family")

        // 1c. Shared Microsoft Office containers must NOT be claimed when Excel/PowerPoint remain installed
        let wordApp = AppItem(
            url: sandbox.appendingPathComponent("Applications/Microsoft Word.app"),
            name: "Microsoft Word",
            localizedName: "Microsoft Word",
            bundleID: "com.microsoft.Word",
            version: "16",
            teamIdentifier: "UBF8T346G9",
            applicationGroups: sharedOfficeGroups + ["UBF8T346G9.com.microsoft.Word.only"]
        )
        let excelApp = AppItem(
            url: sandbox.appendingPathComponent("Applications/Microsoft Excel.app"),
            name: "Microsoft Excel",
            localizedName: "Microsoft Excel",
            bundleID: "com.microsoft.Excel",
            version: "16",
            teamIdentifier: "UBF8T346G9",
            applicationGroups: sharedOfficeGroups
        )
        let officeOwners = ServiceFileMatcher.applicationGroupOwners(across: [wordApp, excelApp])
        let wordOtherGroups = ServiceFileMatcher.otherInstalledApplicationGroups(for: wordApp, groupOwners: officeOwners)
        let wordHits = matcher.matchInMemory(
            app: wordApp,
            index: idx,
            allInstalledBundleIDs: ["com.microsoft.word", "com.microsoft.excel"],
            otherInstalledAppGroups: wordOtherGroups
        )
        let wordHitNames = Set(wordHits.map(\.displayName))
        for sharedG in sharedOfficeGroups {
            try runner.expect(!wordHitNames.contains(sharedG), "Uninstalling Word must NOT claim shared Office container '\(sharedG)' while Excel is installed")
        }
        try runner.expect(wordHitNames.contains("UBF8T346G9.com.microsoft.Word.only"), "Word's own non-shared container should still match")

        // 2. MS-V08: Symlink `.app` must NEVER borrow target's code signature/entitlements or authorize killing target PID
        let stdAppsDir = sandbox.appendingPathComponent("Applications")
        let realTargetApp = stdAppsDir.appendingPathComponent("RealTarget.app")
        try fm.createDirectory(at: realTargetApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let fakeSymlinkApp = stdAppsDir.appendingPathComponent("FakeLink.app")
        try fm.createSymbolicLink(at: fakeSymlinkApp, withDestinationURL: realTargetApp)

        let fakePID: pid_t = getpid() == 1 ? 2 : (getpid() - 1)
        let targetExec = realTargetApp.appendingPathComponent("Contents/MacOS/RealTarget")
        try runner.expect(!AppScanner.isProcessURL(realTargetApp, insideAnyOf: [fakeSymlinkApp]),
                          "isProcessURL must skip symlink .app targets")
        try runner.expect(!AppScanner.isProcessURL(targetExec, insideAnyOf: [fakeSymlinkApp]),
                          "isProcessURL must not follow symlink .app to match target's executable")
        try runner.expect(!AppScanner.isProcessAuthorizedForAppMatch(
            pid: fakePID,
            processBundleID: "com.acme.realtarget",
            processBundleURL: realTargetApp,
            processExecutableURL: targetExec,
            targetBundleIDs: ["com.acme.realtarget"],
            targetAppURLs: [fakeSymlinkApp],
            cachedAppIdentities: nil,
            processIdentityOverride: CodeSigningIdentity(teamIdentifier: "TEAM111111", signingIdentifier: "com.acme.realtarget", isAppleSigned: false)
        ), "Symlink .app must NEVER authorize terminating its target process")

        let symlinkAppItem = AppItem(
            url: fakeSymlinkApp,
            name: "FakeLink",
            localizedName: "FakeLink",
            bundleID: "com.acme.realtarget",
            version: "1"
        )
        try runner.expectEqual(AppScanner.safeProcessMatchBundleID(for: symlinkAppItem, homeDirectory: sandbox), nil,
                               "safeProcessMatchBundleID must return nil for symlink .app")

        let shortcutsURL = URL(fileURLWithPath: "/System/Applications/Shortcuts.app")
        if fm.fileExists(atPath: shortcutsURL.path) {
            let linkToShortcuts = sandbox.appendingPathComponent("BorrowedShortcuts.app")
            try fm.createSymbolicLink(at: linkToShortcuts, withDestinationURL: shortcutsURL)
            try runner.expectEqual(AppScanner.extractAppSigningIdentity(at: linkToShortcuts), nil,
                                   "Symlink .app must NOT borrow target's signing identity")
            try runner.expect(AppScanner.extractApplicationGroups(at: linkToShortcuts).isEmpty,
                              "Symlink .app must NOT borrow target's applicationGroups")
            try runner.expect(!AppScanner.hasValidAppleSignature(at: linkToShortcuts, expectedBundleID: "com.apple.shortcuts"),
                              "Symlink .app must NOT borrow target's Apple signature")
        }

        // 3. P2: Deleting a uchg file or uchg directory inside an external 0300 (-wx) parent must NOT widen parent mode to 0700
        let wxParent = sandbox.appendingPathComponent("External0300Parent")
        try fm.createDirectory(at: wxParent, withIntermediateDirectories: true)
        let uchgInWX = wxParent.appendingPathComponent("locked-file.dat")
        try Data("locked".utf8).write(to: uchgInWX)
        let uchgDirInWX = wxParent.appendingPathComponent("locked-dir")
        try fm.createDirectory(at: uchgDirInWX, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: uchgDirInWX.appendingPathComponent("child.txt"))

        let tFile = RemovalTarget(url: uchgInWX)
        let tDir = RemovalTarget(url: uchgDirInWX)
        if chflags(uchgInWX.path, UInt32(UF_IMMUTABLE)) == 0,
           chflags(uchgDirInWX.path, UInt32(UF_IMMUTABLE)) == 0 {
            chmod(wxParent.path, 0o300)
            defer { chmod(wxParent.path, 0o755) }

            let rmReport = RemovalEngine(safetyGuard: sg).remove(
                targets: [tFile, tDir],
                mode: .permanent,
                allowElevation: false
            )
            try runner.expect(rmReport.isFullSuccess, "uchg entries in 0300 parent must delete cleanly: \(rmReport.failures.map(\.reason))")
            try runner.expect(!RemovalEngine.entryExists(uchgInWX))
            try runner.expect(!RemovalEngine.entryExists(uchgDirInWX))

            var parentStat = stat()
            try runner.expectEqual(lstat(wxParent.path, &parentStat), 0)
            let parentPerms = parentStat.st_mode & 0o7777
            try runner.expectEqual(parentPerms, mode_t(0o300),
                                   "External 0300 parent mode must remain 0300 (must NOT be widened to 0700)")
        }
    }

    runner.run("App Detail Enrichment: signed parent group, embedded app & vendor prefix matching, home dot-folder safety, and DirectorySizer item counts") {
        let sandbox = try runner.makeTempSandbox(prefix: "detail-enrich")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let userLib = sandbox.appendingPathComponent("Library")
        let sysLib = sandbox.appendingPathComponent("SysLibrary")
        let appSupport = userLib.appendingPathComponent("Application Support")
        let caches = userLib.appendingPathComponent("Caches")
        let prefs = userLib.appendingPathComponent("Preferences")
        let groupsDir = userLib.appendingPathComponent("Group Containers")
        let launchAgents = userLib.appendingPathComponent("LaunchAgents")

        for d in [appSupport, caches, prefs, groupsDir, launchAgents, sysLib] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }

        // Mock Docker-style artifacts
        let desktopSupport = appSupport.appendingPathComponent("Docker Desktop")
        let installSupport = appSupport.appendingPathComponent("com.docker.install")
        let desktopCache = caches.appendingPathComponent("Docker Desktop")
        let electronPref = prefs.appendingPathComponent("com.electron.dockerdesktop.plist")
        let dockerGroup = groupsDir.appendingPathComponent("group.com.docker")
        let dotDocker = sandbox.appendingPathComponent(".docker")
        let dotSSH = sandbox.appendingPathComponent(".ssh")
        let dotConfig = sandbox.appendingPathComponent(".config")
        let assocPlist = launchAgents.appendingPathComponent("com.docker.useragent.plist")

        for d in [desktopSupport, installSupport, desktopCache, dockerGroup, dotDocker, dotSSH, dotConfig] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try Data("cfg".utf8).write(to: dotDocker.appendingPathComponent("config.json"))
        try Data("key".utf8).write(to: dotSSH.appendingPathComponent("id_ed25519"))
        try Data("pref".utf8).write(to: electronPref)
        let assocXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>AssociatedBundleIdentifiers</key><array><string>com.docker.docker</string></array>
            <key>Label</key><string>com.docker.useragent</string>
            <key>Program</key><string>/Applications/Docker.app/Contents/MacOS/Docker</string>
        </dict></plist>
        """
        try Data(assocXML.utf8).write(to: assocPlist)

        let sg = SafetyGuard(homeDirectory: sandbox)
        let index = LibraryIndex.build(userLibraryURL: userLib, systemLibraryURL: sysLib, safetyGuard: sg)

        // Protected dotfiles (.ssh, .config) MUST NEVER enter LibraryIndex; .docker enters as isHomeDotEntry
        try runner.expect(!index.entries.contains { $0.url.lastPathComponent == ".ssh" || $0.url.lastPathComponent == ".config" },
                          "Protected dotfiles (.ssh/.config) must never be indexed")
        try runner.expect(index.entries.contains { $0.url.lastPathComponent == ".docker" && $0.isHomeDotEntry },
                          "Non-protected app dot-folder (.docker) should be indexed as home dot entry")

        // LeftoverScanner must skip home dot entries so ~/.docker is never flagged as an orphan leftover
        let leftovers = LeftoverScanner(safetyGuard: sg).scan(
            index: index,
            inventory: InstalledAppInventory(bundleIDs: [], baseBundlePrefixes: [], appNames: [], compactAppNames: [])
        )
        try runner.expect(!leftovers.flatMap(\.files).contains { $0.url.lastPathComponent == ".docker" },
                          "Home dot-folders must never appear in Leftovers scan")

        // Signed Docker-style app matches group.com.docker, Docker Desktop, com.electron.dockerdesktop, com.docker.install, .docker, and AssociatedBundleIdentifiers plist
        let signedDocker = AppItem(
            url: URL(fileURLWithPath: "/Applications/Docker.app"),
            name: "Docker",
            localizedName: "Docker",
            bundleID: "com.docker.docker",
            version: "4.96.0",
            teamIdentifier: "9BNSXJN65R",
            developerName: "Docker Inc",
            verificationStatus: .notarized,
            architectures: ["arm64"],
            applicationGroups: ["group.com.docker"],
            embeddedBundleIDs: ["com.electron.dockerdesktop"],
            embeddedAppNames: ["Docker Desktop"]
        )
        let matcher = ServiceFileMatcher(safetyGuard: sg)
        let matched = matcher.matchInMemory(app: signedDocker, index: index, allInstalledBundleIDs: ["com.docker.docker"])
        let matchedNames = Set(matched.map { $0.url.lastPathComponent })
        try runner.expect(matchedNames.contains("group.com.docker"), "Signed Docker declaring group.com.docker must match its Group Container")
        try runner.expect(matchedNames.contains("Docker Desktop"), "Verified embedded app name 'Docker Desktop' must match support/cache folders")
        try runner.expect(matchedNames.contains("com.electron.dockerdesktop.plist"), "Verified embedded bundleID must match preferences")
        try runner.expect(matchedNames.contains("com.docker.install"), "Unique repeated-token vendor prefix com.docker.* must match com.docker.install")
        try runner.expect(matchedNames.contains(".docker"), "Exact non-ambiguous app name must match ~/.docker")
        try runner.expect(matchedNames.contains("com.docker.useragent.plist"), "AssociatedBundleIdentifiers plist must match")

        // Unsigned app with spoofed embeddedBundleIDs / embeddedAppNames / group.com.docker MUST NOT match those items
        let unsignedSpoof = AppItem(
            url: sandbox.appendingPathComponent("Fake.app"),
            name: "Fake",
            localizedName: "Fake",
            bundleID: "com.evil.fake",
            version: "1.0",
            teamIdentifier: nil,
            applicationGroups: ["group.com.docker"],
            embeddedBundleIDs: ["com.electron.dockerdesktop"],
            embeddedAppNames: ["Docker Desktop"]
        )
        let spoofMatched = matcher.matchInMemory(app: unsignedSpoof, index: index, allInstalledBundleIDs: ["com.docker.docker", "com.evil.fake"])
        try runner.expect(spoofMatched.isEmpty, "Unsigned spoofed app must match zero Docker files, got: \(spoofMatched.map(\.displayName))")

        // DirectorySizer counts files and subfolders accurately
        let countDir = sandbox.appendingPathComponent("count-probe")
        let subA = countDir.appendingPathComponent("subA")
        let subB = subA.appendingPathComponent("subB")
        try fm.createDirectory(at: subB, withIntermediateDirectories: true)
        try Data("1234".utf8).write(to: countDir.appendingPathComponent("f1.txt"))
        try Data("5678".utf8).write(to: subA.appendingPathComponent("f2.txt"))
        try Data("90".utf8).write(to: subB.appendingPathComponent("f3.txt"))
        let meas = DirectorySizer.measureSizeSync(of: countDir)
        try runner.expectEqual(meas.fileCount, 3, "DirectorySizer must report exact fileCount")
        try runner.expectEqual(meas.folderCount, 2, "DirectorySizer must report exact folderCount")
        try runner.expect(!meas.isTruncated)
    }
}

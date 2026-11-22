import Darwin
import Foundation
import MacSweepCore

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

    // MARK: P0 #2 — F3 BSD chown argument order (`--` BEFORE owner) succeeds with rc == 0

    runner.run("P0 #2: buildPrivilegedTrashShellCommand exits 0 on valid file, nested dir, and symlink (BSD chown order)") {
        let sandbox = try runner.makeTempSandbox(prefix: "p0-chown")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let trash = sandbox.appendingPathComponent("Trash")

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
        try runner.expect(script.contains("chown -R -P -- "), "BSD chown requires -- BEFORE owner")
        let res = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", script])
        try runner.expectEqual(res.exitCode, 0, "Valid trash move + chown must exit 0; stderr=\(res.stderr)")
        try runner.expect(!res.stderr.contains("chown-failed:"), "chown must not fail")
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

    runner.run("M-01: privileged trash refuses hardlink chown, symlink trash, and parent-symlink TOCTOU") {
        let sandbox = try runner.makeTempSandbox(prefix: "m01-lpe")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let sg = SafetyGuard(homeDirectory: sandbox)
        let exec = PrivilegedExecutor(safetyGuard: sg)

        // 1. Hardlink inside directory must trigger chown-failed:(hardlink) and non-zero exit
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
        let hlRes = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", hardlinkScript])
        try runner.expect(hlRes.exitCode != 0, "Hardlink entry must fail chown guard")
        try runner.expect(hlRes.stderr.contains("chown-failed:") && hlRes.stderr.contains("hardlink"),
                          "Hardlink refusal must emit chown-failed hardlink marker; stderr=\(hlRes.stderr)")

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
}

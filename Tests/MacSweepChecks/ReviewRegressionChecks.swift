import Darwin
import Foundation
import MacSweepCore

/// Regression checks for issues confirmed in the implementation review (F1–F8 + leftover/matcher findings).
func runReviewRegressionChecks(_ runner: CheckRunner) {
    print("== Review Regression Checks ==")

    let shRunner: PrivilegedExecutor.ScriptRunner = { script in
        ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", script])
    }

    // MARK: F1 — `rm` failure must not be masked by `|| true`

    runner.run("F1: permanent-delete script propagates rm failure even with pkg receipts") {
        let sandbox = try runner.makeTempSandbox(prefix: "f1")
        let locked = sandbox.appendingPathComponent("locked")
        let victim = locked.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        chmod(locked.path, 0o555)
        defer {
            chmod(locked.path, 0o755)
            try? FileManager.default.removeItem(at: sandbox)
        }

        let exec = PrivilegedExecutor(safetyGuard: SafetyGuard(homeDirectory: sandbox))
        let failing = try exec.buildPermanentDeleteShellCommand(urls: [victim], packageIDsToForget: ["com.example.none"])
        let res = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", failing])
        try runner.expect(res.exitCode != 0, "rm failure must yield non-zero exit, got \(res.exitCode)")
        try runner.expect(FileManager.default.fileExists(atPath: victim.path), "victim should still exist")
        try runner.expect(failing.contains("if [ \"$ec\" -eq 0 ]"), "receipt forgetting must be gated on rm success")

        let okTarget = sandbox.appendingPathComponent("ok-file")
        try Data("x".utf8).write(to: okTarget)
        let passing = try exec.buildPermanentDeleteShellCommand(urls: [okTarget])
        let okRes = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", passing])
        try runner.expectEqual(okRes.exitCode, 0)
        try runner.expect(!FileManager.default.fileExists(atPath: okTarget.path))
    }

    // MARK: F1 + F6 — engine reconciles per item instead of trusting the batch

    runner.run("F6: privileged batch reports only items that really disappeared") {
        let sandbox = try runner.makeTempSandbox(prefix: "f6")
        let locked = sandbox.appendingPathComponent("locked")
        let stuck = locked.appendingPathComponent("stuck.dat")
        let gone = sandbox.appendingPathComponent("gone.dat")
        let missing = sandbox.appendingPathComponent("never-existed.dat")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: stuck)
        try Data("b".utf8).write(to: gone)
        chmod(locked.path, 0o555)
        defer {
            chmod(locked.path, 0o755)
            try? FileManager.default.removeItem(at: sandbox)
        }

        let sg = SafetyGuard(homeDirectory: sandbox)
        let exec = PrivilegedExecutor(safetyGuard: sg, adminShellRunner: shRunner)
        let engine = RemovalEngine(safetyGuard: sg, privilegedExecutor: exec)
        let report = engine.remove(
            targets: [
                RemovalTarget(url: stuck, estimatedSize: 100, requiresAdmin: true),
                RemovalTarget(url: gone, estimatedSize: 10, requiresAdmin: true),
                RemovalTarget(url: missing, estimatedSize: 999, requiresAdmin: true),
            ],
            mode: .permanent
        )
        let okPaths = report.succeededURLs.map(\.path)
        try runner.expect(okPaths.contains(gone.path), "really removed item must be reported")
        try runner.expect(!okPaths.contains(stuck.path), "item still on disk must NOT be reported as removed")
        try runner.expect(!okPaths.contains(missing.path), "never-existing item must not be counted")
        try runner.expectEqual(report.freedBytes, 10, "freed bytes must only include really removed items")
        try runner.expect(report.failures.contains { $0.url.path == stuck.path }, "stuck item must be a failure")
    }

    // MARK: F3 — privileged Trash fallback: independent items, recursive chown, collision naming

    runner.run("F3: privileged-trash script is per-item, recursive-chown, and reports partial failure") {
        let sandbox = try runner.makeTempSandbox(prefix: "f3")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let trash = sandbox.appendingPathComponent("Trash")
        let appDir = sandbox.appendingPathComponent("Tool.app/Contents/Resources")
        try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
        let toolApp = sandbox.appendingPathComponent("Tool.app")
        let plain = sandbox.appendingPathComponent("note.txt")
        try Data("n".utf8).write(to: plain)
        try fm.createDirectory(at: trash.appendingPathComponent("note.txt"), withIntermediateDirectories: true) // collision
        let missing = sandbox.appendingPathComponent("missing.bin")

        let exec = PrivilegedExecutor(safetyGuard: SafetyGuard(homeDirectory: sandbox))
        let script = try exec.buildPrivilegedTrashShellCommand(
            urls: [missing, toolApp, plain],
            trashDirectory: trash,
            timestamp: "T"
        )
        try runner.expect(script.contains("chown -R -P"), "must chown recursively without following symlinks")
        let res = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", script])
        try runner.expect(res.exitCode != 0, "a failing item must make the script exit non-zero")
        try runner.expect(fm.fileExists(atPath: trash.appendingPathComponent("Tool.app/Contents/Resources").path),
                          "later items must still be processed after an earlier failure")
        try runner.expect(fm.fileExists(atPath: trash.appendingPathComponent("note.txt_T_2").path),
                          "name collision must use the unique fallback name")
    }

    runner.run("F3: Finder-denied fallback moves into injected trash and engine reconciles") {
        let sandbox = try runner.makeTempSandbox(prefix: "f3b")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let trash = sandbox.appendingPathComponent("Trash")
        let item = sandbox.appendingPathComponent("rootish.dat")
        try Data("r".utf8).write(to: item)

        let sg = SafetyGuard(homeDirectory: sandbox)
        let finderDenied: PrivilegedExecutor.ScriptRunner = { _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "execution error: Not authorized to send Apple events to Finder. (-1743)")
        }
        let exec = PrivilegedExecutor(
            safetyGuard: sg,
            trashDirectory: trash,
            adminShellRunner: shRunner,
            finderAppleScriptRunner: finderDenied
        )
        let report = RemovalEngine(safetyGuard: sg, privilegedExecutor: exec).remove(
            targets: [RemovalTarget(url: item, estimatedSize: 1, requiresAdmin: true)],
            mode: .trash
        )
        try runner.expect(report.isFullSuccess, "fallback should succeed: \(report.failures.map(\.reason))")
        try runner.expect(report.usedFinderFallbackToAdmin, "must record the fallback")
        try runner.expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("rootish.dat").path))
    }

    // MARK: F4 — launchctl bootstrap failure must surface

    runner.run("F4: enable fails when bootstrap fails and service is not loaded; tolerated if already loaded") {
        let sandbox = try runner.makeTempSandbox(prefix: "f4")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let stub = sandbox.appendingPathComponent("launchctl-stub")
        try """
        #!/bin/sh
        case "$1" in
          enable) exit ${STUB_ENABLE:-0} ;;
          disable) exit ${STUB_DISABLE:-0} ;;
          bootstrap) exit ${STUB_BOOTSTRAP:-0} ;;
          bootout) exit ${STUB_BOOTOUT:-0} ;;
          print) exit ${STUB_PRINT:-1} ;;
        esac
        exit 99
        """.write(to: stub, atomically: true, encoding: .utf8)
        chmod(stub.path, 0o755)

        let item = StartupItem(
            label: "com.acme.agent",
            plistURL: sandbox.appendingPathComponent("com.acme.agent.plist"),
            programPath: "/usr/bin/true",
            scope: .userAgent,
            isEnabled: false
        )
        let (_, enableCmd) = try StartupController.buildToggleShellCommand(item: item, enable: true, uid: 501, launchctl: stub.path)
        let (_, disableCmd) = try StartupController.buildToggleShellCommand(item: item, enable: false, uid: 501, launchctl: stub.path)

        func run(_ cmd: String, _ env: [String: String]) -> Int32 {
            ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", cmd], environment: env).exitCode
        }
        try runner.expect(run(enableCmd, ["STUB_BOOTSTRAP": "5", "STUB_PRINT": "1"]) != 0, "bootstrap failure must surface")
        try runner.expectEqual(run(enableCmd, ["STUB_BOOTSTRAP": "5", "STUB_PRINT": "0"]), 0, "already-loaded is OK")
        try runner.expect(run(enableCmd, ["STUB_ENABLE": "3"]) != 0, "enable failure must surface")
        try runner.expectEqual(run(disableCmd, ["STUB_BOOTOUT": "3"]), 0, "bootout is best-effort on disable")
        try runner.expect(run(disableCmd, ["STUB_DISABLE": "3"]) != 0, "disable failure must surface")
    }

    // MARK: F2 — removal unloads the launchd job first (live, user domain, self-cleaning)

    runner.run("F2: unloadBeforeRemoval boots out a live user LaunchAgent and verifies it is gone") {
        let sandbox = try runner.makeTempSandbox(prefix: "f2")
        let agentsDir = sandbox.appendingPathComponent("LaunchAgents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let label = "local.macsweep.selftest.\(UUID().uuidString.prefix(8).lowercased())"
        let plist = agentsDir.appendingPathComponent("\(label).plist")
        let dict: [String: Any] = ["Label": label, "ProgramArguments": ["/bin/sleep", "600"], "RunAtLoad": true]
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0).write(to: plist)
        let target = "gui/\(getuid())/\(label)"
        defer {
            _ = ProcessRunner.run(executable: "/bin/launchctl", arguments: ["bootout", target])
            try? FileManager.default.removeItem(at: sandbox)
        }

        let boot = ProcessRunner.run(executable: "/bin/launchctl", arguments: ["bootstrap", "gui/\(getuid())", plist.path])
        try runner.expect(boot.succeeded, "test setup: bootstrap failed: \(boot.stderr)")
        try runner.expect(ProcessRunner.run(executable: "/bin/launchctl", arguments: ["print", target]).succeeded,
                          "test setup: service should be loaded")

        let targets = StartupController.launchTargets(for: [plist])
        try runner.expectEqual(targets.count, 1)
        try runner.expectEqual(targets.first?.serviceTarget, target)
        let report = StartupController().unloadBeforeRemoval(targets)
        if report.unloadedPlists.isEmpty {
            print("    [diag] still=\(report.stillLoadedPlists) err=\(report.errorMessage ?? "nil") script=\(StartupController.buildUnloadShellCommand(targets: targets))")
        }
        try runner.expect(report.unloadedPlists.contains(plist.standardizedFileURL.path), "plist must be confirmed unloaded")
        try runner.expect(report.stillLoadedPlists.isEmpty)
        try runner.expect(!ProcessRunner.run(executable: "/bin/launchctl", arguments: ["print", target]).succeeded,
                          "service must no longer be loaded after removal prep")
    }

    runner.run("F2: still-loaded markers are parsed from raw stderr and osascript errors") {
        let raw = "still-loaded:/Library/LaunchDaemons/a.plist\nother noise"
        let osa = "0:120: execution error: still-loaded:/Library/LaunchDaemons/b.plist (1)"
        try runner.expectEqual(StartupController.parseStillLoadedPlists(from: raw), ["/Library/LaunchDaemons/a.plist"])
        try runner.expectEqual(StartupController.parseStillLoadedPlists(from: osa), ["/Library/LaunchDaemons/b.plist"])
    }

    // MARK: F7 — environment is merged, not replaced

    runner.run("F7: ProcessRunner merges custom environment with the inherited one") {
        let res = ProcessRunner.run(executable: "/usr/bin/env", arguments: [], environment: ["MSW_PROBE": "1"])
        try runner.expect(res.stdout.contains("MSW_PROBE=1"), "custom var must be present")
        try runner.expect(res.stdout.contains("PATH="), "inherited PATH must be preserved")
        try runner.expect(res.stdout.contains("HOME="), "inherited HOME must be preserved")
    }

    // MARK: Leftovers — installed-app data, localized names, UUID suffix, system scope (F5)

    runner.run("Leftovers: renamed bundle data, localized names, UUID suffixes, shared vendor SDK, system scope") {
        let sandbox = try runner.makeTempSandbox(prefix: "lo-review")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fm = FileManager.default
        let apps = sandbox.appendingPathComponent("Apps")
        let userLib = sandbox.appendingPathComponent("UserLib")
        let sysLib = sandbox.appendingPathComponent("SysLib")

        func makeApp(_ name: String, bundleID: String, exec: String, zhName: String? = nil) throws {
            let contents = apps.appendingPathComponent("\(name).app/Contents")
            try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleExecutable": exec]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            if let zhName {
                let lproj = contents.appendingPathComponent("Resources/zh_CN.lproj")
                try fm.createDirectory(at: lproj, withIntermediateDirectories: true)
                try "\"CFBundleName\" = \"\(zhName)\";\n\"CFBundleDisplayName\" = \"\(zhName)\";\n"
                    .write(to: lproj.appendingPathComponent("InfoPlist.strings"), atomically: true, encoding: .utf16)
            }
        }
        try makeApp("BaiduNetdisk", bundleID: "com.baidu.netdisk", exec: "BaiduNetdisk")
        try makeApp("aDrive", bundleID: "com.alicloud.smartdrive", exec: "aDrive", zhName: "阿里云盘")
        try makeApp("WorkBuddy", bundleID: "com.tencent.workbuddy.mac", exec: "Electron")
        try makeApp("WeWork", bundleID: "com.tencent.WeWorkMac", exec: "WeWork", zhName: "企业微信")

        let uuid = "269F5995-70FC-5B55-BCF5-D7E491D2E457"
        for rel in [
            "Application Support/com.baidu.BaiduNetdisk-mac",   // renamed bundle id of installed app -> NOT leftover
            "Application Support/阿里云盘",                        // localized name of installed app -> NOT leftover
            "Application Support/企业微信_\(uuid)",                 // localized name + UUID suffix -> NOT leftover
            "Application Support/com.tencent.bugly",             // shared vendor SDK -> medium, unchecked
            "Logs/BaiduNetdisk_mac",                             // plain name containing installed app name -> NOT leftover
            "Caches/com.gone.OldEditor",                         // truly orphaned -> high, checked
        ] {
            try fm.createDirectory(at: userLib.appendingPathComponent(rel), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: sysLib.appendingPathComponent("Application Support/com.gone.SysTool"), withIntermediateDirectories: true)

        let sg = SafetyGuard(homeDirectory: sandbox)
        let index = LibraryIndex.build(userLibraryURL: userLib, systemLibraryURL: sysLib, safetyGuard: sg)
        let inventory = InstalledAppInventory.build(searchRoots: [apps], libraryIndex: index)
        try runner.expect(inventory.appNames.contains("阿里云盘"), "localized InfoPlist.strings name must be indexed")
        let groups = LeftoverScanner(safetyGuard: sg).scan(index: index, inventory: inventory)
        let allPaths = groups.flatMap { $0.files.map(\.url.lastPathComponent) }

        try runner.expect(!allPaths.contains("com.baidu.BaiduNetdisk-mac"), "installed BaiduNetdisk data must not be a leftover")
        try runner.expect(!allPaths.contains("阿里云盘"), "localized-name data of aDrive must not be a leftover")
        try runner.expect(!allPaths.contains("企业微信_\(uuid)"), "UUID-suffixed localized data must not be a leftover")
        try runner.expect(!allPaths.contains("BaiduNetdisk_mac"), "plain name containing an installed app name must not be a leftover")

        let bugly = groups.first { $0.files.contains { $0.url.lastPathComponent == "com.tencent.bugly" } }
        try runner.expectEqual(bugly?.confidence, .medium, "shared vendor SDK data must be review-only")
        try runner.expectEqual(bugly?.isChecked, false, "shared vendor SDK data must not be pre-checked")

        let old = groups.first { $0.files.contains { $0.url.lastPathComponent == "com.gone.OldEditor" } }
        try runner.expectEqual(old?.confidence, .high)
        try runner.expectEqual(old?.isChecked, true)

        let sys = groups.first { $0.files.contains { $0.url.lastPathComponent == "com.gone.SysTool" } }
        try runner.expectEqual(sys?.confidence, .medium, "F5: system-scope leftovers are capped at medium")
        try runner.expectEqual(sys?.files.first?.isSelected, false, "F5: system-scope leftovers must not be pre-selected")
    }

    // MARK: Matcher — generic / ambiguous executable names

    runner.run("Matcher: generic runtime executables and names shared by ≥2 apps are not used for name matching") {
        let sandbox = try runner.makeTempSandbox(prefix: "amb")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let userLib = sandbox.appendingPathComponent("UserLib")
        let fm = FileManager.default
        for rel in [
            "Application Support/Electron",
            "Application Support/CrashReporter/Electron_269F5995-70FC-5B55-BCF5-D7E491D2E457.plist",
            "Application Support/SharedEngine",
            "Application Support/WorkThing",
        ] {
            let url = userLib.appendingPathComponent(rel)
            if url.pathExtension == "plist" {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: url)
            } else {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
        let sg = SafetyGuard(homeDirectory: sandbox)
        let index = LibraryIndex.build(userLibraryURL: userLib, systemLibraryURL: sandbox.appendingPathComponent("Sys"), safetyGuard: sg)

        let work = AppItem(url: sandbox.appendingPathComponent("WorkThing.app"), name: "WorkThing", localizedName: "WorkThing",
                           bundleID: "com.acme.workthing", version: "1", executableName: "Electron")
        let a = AppItem(url: sandbox.appendingPathComponent("Alpha.app"), name: "Alpha", localizedName: "Alpha",
                        bundleID: "com.acme.alpha", version: "1", executableName: "SharedEngine")
        let b = AppItem(url: sandbox.appendingPathComponent("Bravo.app"), name: "Bravo", localizedName: "Bravo",
                        bundleID: "com.acme.bravo", version: "1", executableName: "SharedEngine")
        let ambiguous = ServiceFileMatcher.ambiguousNameCandidates(across: [work, a, b])
        try runner.expect(ambiguous.contains("sharedengine"))

        let matcher = ServiceFileMatcher(safetyGuard: sg)
        let workNames = Set(matcher.matchInMemory(app: work, index: index, ambiguousNames: ambiguous).map(\.displayName))
        try runner.expect(workNames.contains("WorkThing"), "own name must still match")
        try runner.expect(!workNames.contains("Electron"), "generic runtime folder must not be claimed")
        try runner.expect(!workNames.contains { $0.hasPrefix("Electron_") }, "shared Electron crash file must not be claimed")
        let alphaNames = Set(matcher.matchInMemory(app: a, index: index, ambiguousNames: ambiguous).map(\.displayName))
        try runner.expect(!alphaNames.contains("SharedEngine"), "ambiguous shared executable name must not be claimed")
    }
}

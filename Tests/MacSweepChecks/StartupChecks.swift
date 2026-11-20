import Foundation
import MacSweepCore

func runStartupChecks(_ runner: CheckRunner) {
    print("== StartupScanner & StartupController Checks ==")

    runner.run("Parses launchctl print-disabled output accurately") {
        let sample = """
        disabled services = {
            "com.google.keystone.user.xpcservice" => disabled
            "com.logi.optionsplus" => enabled
            "com.brother.LOGINserver" => disabled
            "com.legacy.booltrue" => true
            "com.legacy.boolfalse" => false
        }
        """
        let map = StartupScanner.parseLaunchctlDisabledOutput(sample)
        try runner.expectEqual(map["com.google.keystone.user.xpcservice"], true)
        try runner.expectEqual(map["com.logi.optionsplus"], false)
        try runner.expectEqual(map["com.brother.LOGINserver"], true)
        try runner.expectEqual(map["com.legacy.booltrue"], true)
        try runner.expectEqual(map["com.legacy.boolfalse"], false)
    }

    runner.run("Scans mock LaunchAgents, detects orphaned binaries, merges launchctl overrides, and associates app") {
        let sandbox = try runner.makeTempSandbox(prefix: "startup-test")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let userLA = sandbox.appendingPathComponent("UserLaunchAgents")
        let sysLA = sandbox.appendingPathComponent("SysLaunchAgents")
        let sysLD = sandbox.appendingPathComponent("SysLaunchDaemons")
        try fm.createDirectory(at: userLA, withIntermediateDirectories: true)

        let existingBin = sandbox.appendingPathComponent("CoolApp.app/Contents/MacOS/CoolAgent")
        try fm.createDirectory(at: existingBin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: existingBin)

        // Agent 1: valid binary, plist says Disabled=false, launchctl override says disabled=true
        let p1: [String: Any] = [
            "Label": "com.acme.coolagent",
            "ProgramArguments": [existingBin.path, "--bg"],
            "RunAtLoad": true,
            "Disabled": false,
        ]
        try PropertyListSerialization.data(fromPropertyList: p1, format: .xml, options: 0)
            .write(to: userLA.appendingPathComponent("com.acme.coolagent.plist"))

        // Agent 2: orphaned missing binary
        let p2: [String: Any] = [
            "Label": "com.ghost.updater",
            "Program": sandbox.appendingPathComponent("GhostApp.app/Contents/MacOS/Ghost").path,
            "KeepAlive": true,
        ]
        try PropertyListSerialization.data(fromPropertyList: p2, format: .xml, options: 0)
            .write(to: userLA.appendingPathComponent("com.ghost.updater.plist"))

        // Agent 3: Apple label should be filtered out
        let p3: [String: Any] = [
            "Label": "com.apple.system.test",
            "Program": "/bin/echo",
        ]
        try PropertyListSerialization.data(fromPropertyList: p3, format: .xml, options: 0)
            .write(to: userLA.appendingPathComponent("com.apple.system.test.plist"))

        let scanner = StartupScanner(
            userLaunchAgentsURL: userLA,
            systemLaunchAgentsURL: sysLA,
            systemLaunchDaemonsURL: sysLD,
            appSearchRoots: [],
            safetyGuard: SafetyGuard(homeDirectory: sandbox)
        )
        let items = scanner.scanAll(
            userDisabledMap: ["com.acme.coolagent": true],
            systemDisabledMap: [:]
        )

        try runner.expectEqual(items.count, 2, "Apple item must be excluded")
        let cool = items.first(where: { $0.label == "com.acme.coolagent" })
        let ghost = items.first(where: { $0.label == "com.ghost.updater" })

        try runner.expect(cool != nil)
        try runner.expectEqual(cool?.isEnabled, false, "launchctl disabled override must win over plist Disabled=false")
        try runner.expectEqual(cool?.isOrphanedBinary, false)
        try runner.expectEqual(cool?.associatedAppName, "CoolApp")

        try runner.expect(ghost != nil)
        try runner.expectEqual(ghost?.isOrphanedBinary, true, "Missing binary must be flagged orphaned")
        try runner.expectEqual(ghost?.keepAlive, true)
    }

    runner.run("StartupController builds safe launchctl commands and rejects system/login items") {
        let userItem = StartupItem(
            label: "com.acme.helper",
            plistURL: URL(fileURLWithPath: "/tmp/com.acme.helper.plist"),
            programPath: "/usr/bin/true",
            scope: .userAgent,
            isEnabled: true
        )
        let (dom, cmd) = try StartupController.buildToggleShellCommand(item: userItem, enable: false, uid: 501)
        try runner.expectEqual(dom, "gui/501")
        try runner.expect(cmd.contains("launchctl disable 'gui/501/com.acme.helper'"))
        try runner.expect(cmd.contains("launchctl bootout 'gui/501/com.acme.helper'"))

        let daemonItem = StartupItem(
            label: "com.acme.daemon",
            plistURL: URL(fileURLWithPath: "/Library/LaunchDaemons/com.acme.daemon.plist"),
            programPath: "/usr/bin/true",
            scope: .systemDaemon,
            isEnabled: false,
            requiresAdmin: true
        )
        let (sysDom, sysCmd) = try StartupController.buildToggleShellCommand(item: daemonItem, enable: true, uid: 501)
        try runner.expectEqual(sysDom, "system")
        try runner.expect(sysCmd.contains("launchctl enable 'system/com.acme.daemon'"))
        try runner.expect(sysCmd.contains("launchctl bootstrap 'system'"))
    }
}

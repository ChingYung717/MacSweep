import Foundation
import MacSweepCore

func runExtensionChecks(_ runner: CheckRunner) {
    print("== ExtensionScanner Checks ==")

    runner.run("Parses Chromium manifest.json and resolves __MSG_*__ localized name") {
        let sandbox = try runner.makeTempSandbox(prefix: "ext-chromium")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let extDir = sandbox.appendingPathComponent("Default/Extensions/abcdefghijklmnop")
        let verDir = extDir.appendingPathComponent("1.4.2_0")
        let localeDir = verDir.appendingPathComponent("_locales/en")
        try fm.createDirectory(at: localeDir, withIntermediateDirectories: true)

        let manifest = """
        {
            "name": "__MSG_appName__",
            "version": "1.4.2",
            "default_locale": "en"
        }
        """
        try Data(manifest.utf8).write(to: verDir.appendingPathComponent("manifest.json"))

        let messages = """
        {
            "appName": { "message": "Super Privacy Blocker" }
        }
        """
        try Data(messages.utf8).write(to: localeDir.appendingPathComponent("messages.json"))

        let scanner = ExtensionScanner(homeDirectory: sandbox)
        let items = scanner.scanChromiumUserData(
            at: sandbox,
            category: .browserChrome,
            browserBundleID: "com.google.Chrome"
        )

        try runner.expectEqual(items.count, 1)
        try runner.expectEqual(items.first?.name, "Super Privacy Blocker")
        try runner.expectEqual(items.first?.version, "1.4.2")
        try runner.expectEqual(items.first?.profileName, "Default")
        try runner.expectEqual(items.first?.canRemove, true)
    }

    runner.run("Parses Firefox extensions.json and keeps only user app-profile add-ons") {
        let sandbox = try runner.makeTempSandbox(prefix: "ext-firefox")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let xpi = sandbox.appendingPathComponent("ublock@raymondhill.net.xpi")
        try Data("zipbytes".utf8).write(to: xpi)

        let json = """
        {
            "addons": [
                {
                    "id": "ublock@raymondhill.net",
                    "location": "app-profile",
                    "type": "extension",
                    "version": "1.60.0",
                    "active": true,
                    "path": "\(xpi.path)",
                    "defaultLocale": { "name": "uBlock Origin" }
                },
                {
                    "id": "builtin@mozilla.org",
                    "location": "app-builtin",
                    "type": "extension",
                    "version": "1.0",
                    "active": true,
                    "path": "/Applications/Firefox.app/builtin"
                }
            ]
        }
        """
        let items = ExtensionScanner.parseFirefoxExtensionsJSON(Data(json.utf8), profileName: "abc.default-release")
        try runner.expectEqual(items.count, 1)
        try runner.expectEqual(items.first?.name, "uBlock Origin")
        try runner.expectEqual(items.first?.canRemove, true)
    }

    runner.run("Parses pluginkit -m -v output, excludes /System extensions, and preserves enabled flags") {
        let sample = """
             com.apple.wallpaper.agent.WallpaperIntents(1.0)\tUUID1\t2026-11-11 11:59:18 +0000\t/System/Library/CoreServices/WallpaperAgent.app/Contents/PlugIns/WallpaperIntents.appex
        +    com.charliemonroe.Downie-4.Share-Extension(4.13.1)\tUUID2\t2026-10-29 14:07:52 +0000\t/Applications/Downie 4.app/Contents/PlugIns/Share Extension.appex
        -    com.yinxiang.Mac.SafariExtension(8.0.10)\tUUID3\t2026-10-29 14:07:53 +0000\t/Applications/印象笔记.app/Contents/PlugIns/SafariExtension.appex
        """
        let parsed = ExtensionScanner.parsePluginkitOutput(sample)
        try runner.expectEqual(parsed.count, 2, "System Apple extension must be filtered out")
        try runner.expectEqual(parsed[0].identifier, "com.charliemonroe.Downie-4.Share-Extension")
        try runner.expectEqual(parsed[0].version, "4.13.1")
        try runner.expectEqual(parsed[0].isEnabled, true)
        try runner.expectEqual(parsed[1].identifier, "com.yinxiang.Mac.SafariExtension")
        try runner.expectEqual(parsed[1].isEnabled, false)
    }

    runner.run("Scans system plugin directories and marks HAL audio drivers with requiresReboot = true") {
        let sandbox = try runner.makeTempSandbox(prefix: "ext-sysplugins")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let userLib = sandbox.appendingPathComponent("Library")
        let sysLib = sandbox.appendingPathComponent("SysLib")

        let halDriver = sysLib.appendingPathComponent("Audio/Plug-Ins/HAL/MockVirtualMic.driver")
        let qlGen = userLib.appendingPathComponent("QuickLook/MockMarkdown.qlgenerator")
        try fm.createDirectory(at: halDriver, withIntermediateDirectories: true)
        try fm.createDirectory(at: qlGen, withIntermediateDirectories: true)

        let scanner = ExtensionScanner(
            homeDirectory: sandbox,
            systemLibraryURL: sysLib,
            safetyGuard: SafetyGuard(homeDirectory: sandbox)
        )
        let items = scanner.scanSystemPluginDirectories()
        try runner.expectEqual(items.count, 2)

        let hal = items.first(where: { $0.name == "MockVirtualMic" })
        let ql = items.first(where: { $0.name == "MockMarkdown" })
        try runner.expectEqual(hal?.category, .audioPlugin)
        try runner.expectEqual(hal?.requiresReboot, true, "HAL audio driver MUST set requiresReboot = true")
        try runner.expectEqual(ql?.category, .quickLook)
        try runner.expectEqual(ql?.requiresReboot, false)
    }
}

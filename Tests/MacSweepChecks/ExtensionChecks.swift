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

    runner.run("ExtensionScanner rejects intermediate symlinks in ~/Library, ~/Library/Audio, Google, and Firefox paths") {
        let sandbox = try runner.makeTempSandbox(prefix: "ext-symlink-escape")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let lib = sandbox.appendingPathComponent("Library")
        let appSupport = lib.appendingPathComponent("Application Support")
        let docs = sandbox.appendingPathComponent("Documents")
        let myAudio = docs.appendingPathComponent("MyAudio")
        let myChrome = docs.appendingPathComponent("MyChrome")
        let myFirefox = docs.appendingPathComponent("MyFirefox")

        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try fm.createDirectory(at: myAudio.appendingPathComponent("Plug-Ins/HAL/Custom.driver"), withIntermediateDirectories: true)
        let chromeVer = myChrome.appendingPathComponent("Chrome/Default/Extensions/abcdefghijklmnop/1.0_0")
        try fm.createDirectory(at: chromeVer, withIntermediateDirectories: true)
        try Data("{\"name\":\"MyExt\",\"version\":\"1.0\"}".utf8)
            .write(to: chromeVer.appendingPathComponent("manifest.json"))

        let ffProf = myFirefox.appendingPathComponent("Profiles/default-release")
        try fm.createDirectory(at: ffProf.appendingPathComponent("extensions"), withIntermediateDirectories: true)
        let xpiURL = ffProf.appendingPathComponent("extensions/ext@example.org.xpi")
        try Data("zip".utf8).write(to: xpiURL)
        let ffJSON = """
        {"addons":[{"id":"ext@example.org","location":"app-profile","type":"extension","version":"1.0","active":true,"path":"\(xpiURL.path)","defaultLocale":{"name":"DocExt"}}]}
        """
        try Data(ffJSON.utf8).write(to: ffProf.appendingPathComponent("extensions.json"))

        try fm.createSymbolicLink(at: lib.appendingPathComponent("Audio"), withDestinationURL: myAudio)
        try fm.createSymbolicLink(at: appSupport.appendingPathComponent("Google"), withDestinationURL: myChrome)
        try fm.createSymbolicLink(at: appSupport.appendingPathComponent("Firefox"), withDestinationURL: myFirefox)

        let scanner = ExtensionScanner(
            homeDirectory: sandbox,
            systemLibraryURL: sandbox.appendingPathComponent("NonExistentSysLib"),
            safetyGuard: SafetyGuard(homeDirectory: sandbox)
        )
        let scanAllResult = scanner.scanAll(includePluginkit: false)
        try runner.expectEqual(scanAllResult.items.count, 0, "Intermediate symlinks in Audio/Google/Firefox must yield 0 items in scanAll")

        let directChrome = scanner.scanChromiumUserData(
            at: appSupport.appendingPathComponent("Google/Chrome"),
            category: .browserChrome,
            browserBundleID: "com.google.Chrome"
        )
        try runner.expectEqual(directChrome.count, 0, "Direct scanChromiumUserData with intermediate Google symlink must yield 0 items")

        let directFirefox = scanner.scanFirefoxBase(at: appSupport.appendingPathComponent("Firefox"))
        try runner.expectEqual(directFirefox.count, 0, "Direct scanFirefoxBase with intermediate Firefox symlink must yield 0 items")

        let sysPlugins = scanner.scanSystemPluginDirectories()
        try runner.expectEqual(sysPlugins.count, 0, "scanSystemPluginDirectories with intermediate Audio symlink must yield 0 items")
    }
}

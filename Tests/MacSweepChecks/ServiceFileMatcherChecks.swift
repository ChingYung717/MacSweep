import Foundation
import MacSweepCore

func runServiceFileMatcherChecks(_ runner: CheckRunner) {
    print("== ServiceFileMatcher & LibraryIndex Checks ==")

    runner.run("Matches Bundle ID, Group Containers, vendor subfolders, LaunchAgent binary ref, and avoids short-name false positives") {
        let sandbox = try runner.makeTempSandbox(prefix: "sfm-test")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let userLib = sandbox.appendingPathComponent("UserLibrary")
        let sysLib = sandbox.appendingPathComponent("SystemLibrary")
        let appsDir = sandbox.appendingPathComponent("Applications")
        let fm = FileManager.default

        let mockApp = appsDir.appendingPathComponent("NovaNote.app")
        try fm.createDirectory(at: mockApp, withIntermediateDirectories: true)

        // Create mock Library artifacts
        let targetsToCreate: [URL] = [
            userLib.appendingPathComponent("Caches/com.acme.NovaNote"),
            userLib.appendingPathComponent("Preferences/com.acme.NovaNote.plist"),
            userLib.appendingPathComponent("Saved Application State/com.acme.NovaNote.savedState"),
            userLib.appendingPathComponent("Group Containers/ABCDE12345.group.com.acme.NovaNote"),
            userLib.appendingPathComponent("Application Support/Microsoft/NovaNote"),
            userLib.appendingPathComponent("Application Support/Microsoft/Teams"), // unrelated sibling under same vendor
            userLib.appendingPathComponent("Caches/com.other.UnrelatedApp"),
        ]
        for url in targetsToCreate {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }

        // LaunchAgent with unrelated filename whose ProgramArguments points inside NovaNote.app
        let laDir = userLib.appendingPathComponent("LaunchAgents")
        try fm.createDirectory(at: laDir, withIntermediateDirectories: true)
        let laPlist = laDir.appendingPathComponent("com.helper.custom-sync.plist")
        let plistObj: [String: Any] = [
            "Label": "com.helper.custom-sync",
            "ProgramArguments": [mockApp.appendingPathComponent("Contents/MacOS/NovaSync").path],
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plistObj, format: .xml, options: 0)
        try plistData.write(to: laPlist)

        let sg = SafetyGuard(homeDirectory: sandbox)
        let index = LibraryIndex.build(userLibraryURL: userLib, systemLibraryURL: sysLib, safetyGuard: sg)
        let matcher = ServiceFileMatcher(safetyGuard: sg)

        let app = AppItem(
            url: mockApp,
            name: "NovaNote",
            localizedName: "NovaNote",
            bundleID: "com.acme.NovaNote",
            version: "2.1.0",
            executableName: "NovaNote",
            teamIdentifier: "ABCDE12345"
        )

        let matched = matcher.matchInMemory(app: app, index: index)
        let matchedNames = Set(matched.map(\.displayName))

        try runner.expect(matchedNames.contains("com.acme.NovaNote"), "Should match Cache by Bundle ID")
        try runner.expect(matchedNames.contains("com.acme.NovaNote.plist"), "Should match Preference plist")
        try runner.expect(matchedNames.contains("com.acme.NovaNote.savedState"), "Should match SavedState")
        try runner.expect(matchedNames.contains("ABCDE12345.group.com.acme.NovaNote"), "Should match Group Container")
        try runner.expect(matchedNames.contains("NovaNote"), "Should match vendor subfolder Application Support/Microsoft/NovaNote")
        try runner.expect(matchedNames.contains("com.helper.custom-sync.plist"), "Should match LaunchAgent referencing app binary")

        try runner.expect(!matchedNames.contains("Teams"), "Must NOT match unrelated sibling in vendor folder")
        try runner.expect(!matchedNames.contains("Microsoft"), "Must NOT match entire shared vendor folder")
        try runner.expect(!matchedNames.contains("com.other.UnrelatedApp"), "Must NOT match unrelated app")
    }

    runner.run("Short app names (<4 chars) do not spuriously match unrelated directories") {
        let sandbox = try runner.makeTempSandbox(prefix: "sfm-short")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let userLib = sandbox.appendingPathComponent("UserLibrary")
        let sysLib = sandbox.appendingPathComponent("SystemLibrary")
        let fm = FileManager.default
        try fm.createDirectory(at: userLib.appendingPathComponent("Application Support/Arc"), withIntermediateDirectories: true)

        let sg = SafetyGuard(homeDirectory: sandbox)
        let index = LibraryIndex.build(userLibraryURL: userLib, systemLibraryURL: sysLib, safetyGuard: sg)
        let matcher = ServiceFileMatcher(safetyGuard: sg)

        let shortApp = AppItem(
            url: sandbox.appendingPathComponent("Arc.app"),
            name: "Arc",
            localizedName: "Arc",
            bundleID: "company.thebrowser.Browser",
            version: "1.0"
        )
        let matched = matcher.matchInMemory(app: shortApp, index: index)
        // Name "Arc" is 3 chars (< 4), so it shouldn't loosely match by short name alone without bundle ID
        try runner.expect(matched.isEmpty, "Short 3-char app name should not loosely match without bundle ID")
    }

    runner.run("pkgutil relative path resolution, bundle collapsing, and shared directory filtering") {
        let infoOutput = """
        package-id: com.oray.sunlogin.MacVirtualAudioDevice
        version: 1.0.0
        volume: /
        location: Library/Audio/Plug-Ins/HAL
        install-time: 1789349366
        """
        let parsed = ServiceFileMatcher.parsePkgInfo(infoOutput, fallbackID: "fallback")
        try runner.expectEqual(parsed?.volume, "/")
        try runner.expectEqual(parsed?.location, "Library/Audio/Plug-Ins/HAL")

        let relLines = [
            ".",
            "OrayVirtualAudioDevice.driver",
            "OrayVirtualAudioDevice.driver/Contents",
            "OrayVirtualAudioDevice.driver/Contents/Info.plist",
            "OrayVirtualAudioDevice.driver/Contents/MacOS/OrayVirtualAudioDevice",
        ]
        let sg = SafetyGuard()
        let collapsed = ServiceFileMatcher.resolveAndCollapsePkgFiles(
            relativeLines: relLines,
            pkgInfo: parsed!,
            appBundlePath: "/Applications/Sunlogin.app",
            safetyGuard: sg
        )
        try runner.expectEqual(
            collapsed,
            ["/Library/Audio/Plug-Ins/HAL/OrayVirtualAudioDevice.driver"],
            "Should collapse nested bundle files to single top-level driver bundle"
        )

        // Ensure shared system roots like /Applications and /Library/LaunchDaemons are filtered out
        let rootPkg = PkgInfoRecord(packageID: "com.acme.app", volume: "/", location: "")
        let noisyLines = [
            "Applications",
            "Applications/Acme.app",
            "Applications/Acme.app/Contents/Info.plist",
            "Library",
            "Library/LaunchDaemons",
            "Library/LaunchDaemons/com.acme.helper.plist",
            "usr/local/bin",
        ]
        let filtered = ServiceFileMatcher.resolveAndCollapsePkgFiles(
            relativeLines: noisyLines,
            pkgInfo: rootPkg,
            appBundlePath: "/Applications/Acme.app",
            safetyGuard: sg
        )
        try runner.expectEqual(
            filtered,
            ["/Library/LaunchDaemons/com.acme.helper.plist"],
            "Must strip shared system directories and main app bundle"
        )
    }
}

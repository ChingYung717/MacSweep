import Foundation
import MacSweepCore

func runLeftoverChecks(_ runner: CheckRunner) {
    print("== LeftoverScanner Checks ==")

    runner.run("Identifies high-confidence reverse-DNS leftovers, orphaned LaunchAgents, medium-confidence dirs, and excludes installed/Apple/CLI items") {
        let sandbox = try runner.makeTempSandbox(prefix: "leftover-test")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let appsDir = sandbox.appendingPathComponent("Apps")
        let userLib = sandbox.appendingPathComponent("UserLib")
        let sysLib = sandbox.appendingPathComponent("SysLib")

        // Create 1 installed app: ActiveApp (com.acme.ActiveApp)
        let activeApp = appsDir.appendingPathComponent("ActiveApp.app/Contents")
        try fm.createDirectory(at: activeApp, withIntermediateDirectories: true)
        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": "com.acme.ActiveApp",
            "CFBundleName": "ActiveApp",
            "CFBundleExecutable": "ActiveApp",
        ]
        try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
            .write(to: activeApp.appendingPathComponent("Info.plist"))

        // Populate mock Library folders
        let dirs: [URL] = [
            // Belongs to installed ActiveApp -> MUST NOT be flagged
            userLib.appendingPathComponent("Caches/com.acme.ActiveApp"),
            userLib.appendingPathComponent("Application Support/ActiveApp"),
            // Apple & CLI -> MUST NOT be flagged
            userLib.appendingPathComponent("Caches/com.apple.Safari"),
            userLib.appendingPathComponent("Application Support/Homebrew"),
            userLib.appendingPathComponent("Application Support/docker"),
            // Uninstalled app reverse-DNS -> HIGH confidence leftover (grouped together!)
            userLib.appendingPathComponent("Caches/com.deleted.OldNote"),
            userLib.appendingPathComponent("Saved Application State/com.deleted.OldNote.savedState"),
            userLib.appendingPathComponent("Preferences/com.deleted.OldNote.plist"),
            // Unmatched plain directory -> MEDIUM confidence (unchecked by default!)
            userLib.appendingPathComponent("Application Support/MysteryToolData"),
        ]
        for url in dirs {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }

        // LaunchAgents: one pointing to existing binary (keep!), one pointing to missing binary (HIGH leftover!)
        let laDir = userLib.appendingPathComponent("LaunchAgents")
        try fm.createDirectory(at: laDir, withIntermediateDirectories: true)

        let aliveBin = sandbox.appendingPathComponent("alive-cli")
        try Data("ok".utf8).write(to: aliveBin)

        let aliveLA: [String: Any] = ["Label": "com.cli.alive", "Program": aliveBin.path]
        try PropertyListSerialization.data(fromPropertyList: aliveLA, format: .xml, options: 0)
            .write(to: laDir.appendingPathComponent("com.cli.alive.plist"))

        let deadLA: [String: Any] = ["Label": "com.ghost.deadagent", "Program": "/nonexistent/path/GhostAgent"]
        try PropertyListSerialization.data(fromPropertyList: deadLA, format: .xml, options: 0)
            .write(to: laDir.appendingPathComponent("com.ghost.deadagent.plist"))

        let sg = SafetyGuard(homeDirectory: sandbox)
        let index = LibraryIndex.build(userLibraryURL: userLib, systemLibraryURL: sysLib, safetyGuard: sg)
        let inventory = InstalledAppInventory.build(searchRoots: [appsDir], libraryIndex: index)
        let scanner = LeftoverScanner(safetyGuard: sg)

        // Verify generic tail fallback display names & noise filters
        try runner.expectEqual(LeftoverScanner.deriveDisplayName(fromGroupKey: "dev.zcode.app", fallbackStem: "dev.zcode.app"), "Zcode")
        try runner.expectEqual(LeftoverScanner.deriveDisplayName(fromGroupKey: "com.acme.oldnote", fallbackStem: "com.acme.oldnote"), "Oldnote")

        let groups = scanner.scan(index: index, inventory: inventory)

        // Check installed/Apple/CLI/alive-LaunchAgent are excluded
        try runner.expect(!groups.contains(where: { $0.id.contains("activeapp") }), "Installed app must not appear as leftover")
        try runner.expect(!groups.contains(where: { $0.id.contains("apple") }), "Apple items must not appear")
        try runner.expect(!groups.contains(where: { $0.id.contains("homebrew") || $0.id.contains("docker") }), "CLI dirs must not appear")
        try runner.expect(!groups.contains(where: { $0.id.contains("com.cli.alive") }), "LaunchAgent with existing binary must not appear")

        // Check grouped high-confidence uninstalled app
        let oldNote = groups.first(where: { $0.id == "com.deleted.oldnote" })
        try runner.expect(oldNote != nil, "Uninstalled reverse-DNS app should be found")
        try runner.expectEqual(oldNote?.confidence, .high)
        try runner.expectEqual(oldNote?.isChecked, true)
        try runner.expectEqual(oldNote?.files.count, 3, "Caches + SavedState + Preferences should group together")

        // Check orphaned LaunchAgent
        let deadGroup = groups.first(where: { $0.id == "com.ghost.deadagent" })
        try runner.expect(deadGroup != nil, "Orphaned LaunchAgent should be flagged")
        try runner.expectEqual(deadGroup?.confidence, .high)

        // Check medium-confidence plain folder is UNCHECKED by default
        let mystery = groups.first(where: { $0.id == "mysterytooldata" })
        try runner.expect(mystery != nil, "Unmatched plain dir should appear as medium confidence")
        try runner.expectEqual(mystery?.confidence, .medium)
        try runner.expectEqual(mystery?.isChecked, false, "Medium confidence group MUST be unchecked by default")
        try runner.expectEqual(mystery?.files.first?.isSelected, false, "Medium confidence file MUST be unselected by default")
    }

    runner.run("LibraryIndex and LeftoverScanner reject intermediate symlinks escaping into ~/Documents") {
        let sandbox = try runner.makeTempSandbox(prefix: "leftover-symlink-escape")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        // Case 1: ~/Library itself is a symlink to ~/Documents/FakeLib
        let homeA = sandbox.appendingPathComponent("HomeA")
        let docsLib = homeA.appendingPathComponent("Documents/FakeLib")
        try fm.createDirectory(at: docsLib.appendingPathComponent("Caches/com.old.important"), withIntermediateDirectories: true)
        try fm.createDirectory(at: docsLib.appendingPathComponent("LaunchAgents"), withIntermediateDirectories: true)
        try Data("victim".utf8).write(to: docsLib.appendingPathComponent("Caches/com.old.important/data.bin"))
        let deadLA: [String: Any] = ["Label": "com.user.config", "Program": "/nonexistent/Helper"]
        try PropertyListSerialization.data(fromPropertyList: deadLA, format: .xml, options: 0)
            .write(to: docsLib.appendingPathComponent("LaunchAgents/com.user.config.plist"))
        try fm.createSymbolicLink(at: homeA.appendingPathComponent("Library"), withDestinationURL: docsLib)

        let sgA = SafetyGuard(homeDirectory: homeA)
        let idxA = LibraryIndex.build(
            userLibraryURL: homeA.appendingPathComponent("Library"),
            systemLibraryURL: homeA.appendingPathComponent("SysLib"),
            safetyGuard: sgA
        )
        try runner.expectEqual(idxA.entries.count, 0, "Symlinked ~/Library must yield 0 LibraryIndex entries")
        let leftA = LeftoverScanner(safetyGuard: sgA).scan(
            index: idxA,
            inventory: InstalledAppInventory.build(searchRoots: [], libraryIndex: idxA)
        )
        try runner.expectEqual(leftA.count, 0, "Symlinked ~/Library must yield 0 leftover groups")

        // Case 2: ~/Library is real, but ~/Library/Caches and ~/Library/Application Support/Google are symlinks into ~/Documents
        let homeB = sandbox.appendingPathComponent("HomeB")
        let libB = homeB.appendingPathComponent("Library")
        let docsCaches = homeB.appendingPathComponent("Documents/FakeCaches")
        let docsGoogle = homeB.appendingPathComponent("Documents/FakeGoogle")
        try fm.createDirectory(at: libB.appendingPathComponent("Application Support"), withIntermediateDirectories: true)
        try fm.createDirectory(at: docsCaches.appendingPathComponent("com.old.secret"), withIntermediateDirectories: true)
        try fm.createDirectory(at: docsGoogle.appendingPathComponent("SecretProject"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: libB.appendingPathComponent("Caches"), withDestinationURL: docsCaches)
        try fm.createSymbolicLink(at: libB.appendingPathComponent("Application Support/Google"), withDestinationURL: docsGoogle)

        let sgB = SafetyGuard(homeDirectory: homeB)
        let idxB = LibraryIndex.build(
            userLibraryURL: libB,
            systemLibraryURL: homeB.appendingPathComponent("SysLib"),
            safetyGuard: sgB
        )
        try runner.expectEqual(idxB.entries.count, 0, "Symlinked ~/Library/Caches and ~/Library/Application Support/Google must yield 0 entries")
        let leftB = LeftoverScanner(safetyGuard: sgB).scan(
            index: idxB,
            inventory: InstalledAppInventory.build(searchRoots: [], libraryIndex: idxB)
        )
        try runner.expectEqual(leftB.count, 0, "Intermediate Library symlinks must yield 0 leftover groups")
    }
}

import Foundation
import MacSweepCore

func runSafetyGuardChecks(_ runner: CheckRunner) {
    print("== SafetyGuard Checks ==")

    runner.run("Blocks critical root, system, and user directories") {
        let sandbox = try runner.makeTempSandbox(prefix: "sg-home")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: "/Applications/MacSweep.app")

        let blockedPaths = [
            "/",
            "/System",
            "/System/Applications/Notes.app",
            "/Library/Apple/System",
            "/usr/bin/ls",
            "/Applications",
            "/Library/LaunchDaemons",
            "/private/var/db/receipts/foo.plist",
            sandbox.path,
            sandbox.appendingPathComponent("Library").path,
            sandbox.appendingPathComponent("Documents").path,
            sandbox.appendingPathComponent("Library/Application Support/MacSweep").path,
            "/Applications/MacSweep.app",
        ]
        for path in blockedPaths {
            let res = sg.validateForRemoval(URL(fileURLWithPath: path))
            try runner.expect(!res.isAllowed, "Path should be blocked: \(path)")
        }
    }

    runner.run("Detects Safari symlink to /System as system-protected, allows mock App Store Apple app") {
        let sandbox = try runner.makeTempSandbox(prefix: "sg-apps")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let sg = SafetyGuard(homeDirectory: sandbox)

        // Check real Safari symlink if present on host
        let safariURL = URL(fileURLWithPath: "/Applications/Safari.app")
        if FileManager.default.fileExists(atPath: safariURL.path) {
            try runner.expect(sg.isSystemProtectedApp(at: safariURL), "Safari.app should be system-protected")
            try runner.expect(!sg.validateForRemoval(safariURL).isAllowed, "Safari.app removal must be blocked")
        }

        // Mock App Store Apple app (e.g. Pages in temp folder, non-SIP, non-/System)
        let mockPages = sandbox.appendingPathComponent("Pages.app")
        try FileManager.default.createDirectory(at: mockPages, withIntermediateDirectories: true)
        try runner.expect(!sg.isSystemProtectedApp(at: mockPages), "Non-SIP Apple App Store app should not be hard-blocked")
        try runner.expect(sg.isAppleBundleID("com.apple.iWork.Pages"), "Should detect Apple bundle ID")
        try runner.expect(sg.validateForRemoval(mockPages).isAllowed, "Mock Pages.app should be removable")
    }

    runner.run("Dual-validates symlinks: blocks symlink escaping to critical dir, allows normal symlink") {
        let sandbox = try runner.makeTempSandbox(prefix: "sg-symlink")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let docs = sandbox.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let escapeLink = sandbox.appendingPathComponent("sneaky-link")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: docs)

        let normalTarget = sandbox.appendingPathComponent("normal-target.txt")
        try Data("hello".utf8).write(to: normalTarget)
        let normalLink = sandbox.appendingPathComponent("normal-link")
        try FileManager.default.createSymbolicLink(at: normalLink, withDestinationURL: normalTarget)

        let sg = SafetyGuard(homeDirectory: sandbox)
        try runner.expect(!sg.validateForRemoval(escapeLink).isAllowed, "Symlink pointing to ~/Documents must be blocked")
        try runner.expect(sg.validateForRemoval(normalLink).isAllowed, "Symlink pointing to normal file should be allowed")
    }

    runner.run("Protects Apple, CLI, and shared vendor directories in leftover scan") {
        let sg = SafetyGuard()
        try runner.expect(sg.isProtectedFromLeftoverScan(name: "com.apple.Safari", bundleID: "com.apple.Safari"))
        try runner.expect(sg.isProtectedFromLeftoverScan(name: "Homebrew", bundleID: nil))
        try runner.expect(sg.isProtectedFromLeftoverScan(name: "docker", bundleID: nil))
        try runner.expect(sg.isProtectedFromLeftoverScan(name: "Microsoft", bundleID: nil))
        try runner.expect(sg.isProtectedFromLeftoverScan(name: "CloudDocs", bundleID: nil))
        try runner.expect(!sg.isProtectedFromLeftoverScan(name: "com.acme.OldWidget", bundleID: "com.acme.OldWidget"))
    }

    runner.run("Blocks nested protectedBundleIDs inside Containers/.../Data/Library/... and Application Support/.../Library/...") {
        let sandbox = try runner.makeTempSandbox(prefix: "sg-nested-lib")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let nestedContainerFile = sandbox.appendingPathComponent("Library/Containers/com.acme.protected/Data/Library/Caches/secret.bin")
        let nestedContainerDir = nestedContainerFile.deletingLastPathComponent()
        let nestedAppSupportFile = sandbox.appendingPathComponent("Library/Application Support/com.acme.protected/Library/db.sqlite")
        let archiveDir = sandbox.appendingPathComponent("Archive")
        for dir in [nestedContainerDir, nestedAppSupportFile.deletingLastPathComponent(), archiveDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("s1".utf8).write(to: nestedContainerFile)
        try Data("s2".utf8).write(to: nestedAppSupportFile)

        let sg = SafetyGuard(homeDirectory: sandbox, protectedBundleIDs: ["com.acme.protected"])

        try runner.expect(!sg.validateForRemoval(nestedContainerFile).isAllowed, "Nested Containers/.../Data/Library/... must be blocked")
        try runner.expect(sg.shouldPruneDirectoryScan(at: nestedContainerDir), "shouldPruneDirectoryScan must prune nested container Library")
        try runner.expect(!sg.validateForMoveOrRename(
            source: nestedContainerFile,
            destination: archiveDir.appendingPathComponent("secret.bin")
        ).isAllowed, "Move from nested protected container must be blocked")
        try runner.expect(!sg.validateForRemoval(nestedAppSupportFile).isAllowed, "Nested Application Support/<bundleID>/Library/... must be blocked")
    }

    runner.run("Aligns Apple Caches, Preferences, Saved Application State, and Group Containers across removal, move, and scan pruning") {
        let sandbox = try runner.makeTempSandbox(prefix: "sg-apple-align")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let archiveDir = sandbox.appendingPathComponent("Archive")
        try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)

        let sg = SafetyGuard(homeDirectory: sandbox)

        let blockedRelPaths = [
            "Library/Caches/com.apple.Safari",
            "Library/Caches/com.apple.Safari/Cache.db",
            "Library/Caches/Apple/Sub",
            "Library/Preferences/com.apple.finder.plist",
            "Library/Preferences/ByHost/com.apple.finder.1234.plist",
            "Library/Saved Application State/com.apple.Preview.savedState",
            "Library/Group Containers/group.com.apple.notes",
        ]
        for rel in blockedRelPaths {
            let url = sandbox.appendingPathComponent(rel)
            try runner.expect(!sg.validateForRemoval(url).isAllowed, "validateForRemoval must block: \(rel)")
            try runner.expect(!sg.validateForMoveOrRename(
                source: url,
                destination: archiveDir.appendingPathComponent(url.lastPathComponent)
            ).isAllowed, "validateForMoveOrRename source must block: \(rel)")
            try runner.expect(sg.shouldPruneDirectoryScan(at: url), "shouldPruneDirectoryScan must prune: \(rel)")
        }

        // System /Library/Caches/com.apple.* and /Library/Preferences/com.apple.*
        let sysCache = URL(fileURLWithPath: "/Library/Caches/com.apple.foo")
        let sysPref = URL(fileURLWithPath: "/Library/Preferences/com.apple.System.plist")
        try runner.expect(!sg.validateForRemoval(sysCache).isAllowed)
        try runner.expect(sg.shouldPruneDirectoryScan(at: sysCache))
        try runner.expect(!sg.validateForRemoval(sysPref).isAllowed)
        try runner.expect(sg.shouldPruneDirectoryScan(at: sysPref))

        // Non-Apple caches and App Store iWork preferences remain allowed
        let allowedRelPaths = [
            "Library/Caches/com.acme.App",
            "Library/Preferences/com.apple.iWork.Pages.plist",
        ]
        for rel in allowedRelPaths {
            let url = sandbox.appendingPathComponent(rel)
            try runner.expect(sg.validateForRemoval(url).isAllowed, "validateForRemoval must still allow: \(rel)")
        }
    }

    runner.run("Enforces trailing-slash and NFC vs NFD Unicode equivalence in protectedPaths and protectedBundleIDs") {
        let sandbox = try runner.makeTempSandbox(prefix: "sg-nfc-nfd")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let nfcName = "Caf\u{00E9}-Vault"
        let nfdName = "Cafe\u{0301}-Vault"
        let nfcDir = sandbox.appendingPathComponent(nfcName)
        let nfdChild = sandbox.appendingPathComponent(nfdName).appendingPathComponent("secret.txt")
        try FileManager.default.createDirectory(at: nfcDir, withIntermediateDirectories: true)

        let sg = SafetyGuard(
            homeDirectory: sandbox,
            protectedPaths: [nfcDir.path + "/"],
            protectedBundleIDs: ["COM.ACME.Caf\u{00E9}"]
        )
        try runner.expect(!sg.validateForRemoval(nfdChild).isAllowed, "Trailing-slash NFC protectedPath must block NFD child")
        try runner.expect(sg.shouldPruneDirectoryScan(at: sandbox.appendingPathComponent(nfdName)), "shouldPruneDirectoryScan must match NFD equivalent")

        let nfdCache = sandbox.appendingPathComponent("Library/Caches/com.acme.cafe\u{0301}")
        try runner.expect(!sg.validateForRemoval(nfdCache).isAllowed, "NFC protectedBundleID must block NFD cache path")
    }

    runner.run("Restricts isCriticalSharedDirectory vendor/apple rule to Library paths so ~/Work/logs/meta and ~/Work/caches/apple are allowed") {
        let sandbox = try runner.makeTempSandbox(prefix: "sg-nonlib-vendor")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let logsMeta = sandbox.appendingPathComponent("Work/project/logs/meta")
        let cachesGoogle = sandbox.appendingPathComponent("Work/project/caches/google")
        let cachesApple = sandbox.appendingPathComponent("Work/project/caches/apple")
        let archiveDir = sandbox.appendingPathComponent("Archive")
        let libAdobe = sandbox.appendingPathComponent("Library/Caches/Adobe")
        for dir in [logsMeta.deletingLastPathComponent(), cachesGoogle.deletingLastPathComponent(), archiveDir, libAdobe] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let sg = SafetyGuard(homeDirectory: sandbox)

        // Non-Library directories matching vendor/apple names must be allowed for mkdir, removal, and move
        try runner.expect(!sg.isCriticalSharedDirectory(logsMeta.path), "Non-Library ~/Work/project/logs/meta must not be critical shared")
        try runner.expect(!sg.isCriticalSharedDirectory(cachesGoogle.path), "Non-Library ~/Work/project/caches/google must not be critical shared")
        try runner.expect(!sg.isCriticalSharedDirectory(cachesApple.path), "Non-Library ~/Work/project/caches/apple must not be critical shared")
        try runner.expect(sg.validateDirectoryCreation(at: logsMeta).isAllowed, "mkdir ~/Work/project/logs/meta must be allowed")
        try runner.expect(sg.validateDirectoryCreation(at: cachesGoogle).isAllowed, "mkdir ~/Work/project/caches/google must be allowed")
        try runner.expect(sg.validateDirectoryCreation(at: cachesApple).isAllowed, "mkdir ~/Work/project/caches/apple must be allowed")

        try fm.createDirectory(at: logsMeta, withIntermediateDirectories: true)
        try fm.createDirectory(at: cachesGoogle, withIntermediateDirectories: true)
        try fm.createDirectory(at: cachesApple, withIntermediateDirectories: true)

        for nonLib in [logsMeta, cachesGoogle, cachesApple] {
            try runner.expect(sg.validateForRemoval(nonLib).isAllowed, "Removal must be allowed for \(nonLib.path)")
            try runner.expect(sg.validateForMoveOrRename(
                source: nonLib,
                destination: archiveDir.appendingPathComponent(nonLib.lastPathComponent)
            ).isAllowed, "Move must be allowed for \(nonLib.path)")
        }

        // Actual Library shared vendor and Apple directories must remain blocked
        try runner.expect(sg.isCriticalSharedDirectory(libAdobe.path), "Library/Caches/Adobe must remain critical shared")
        try runner.expect(!sg.validateForRemoval(libAdobe).isAllowed, "Library/Caches/Adobe must remain blocked")
        let sysAppleSupport = URL(fileURLWithPath: "/Library/Application Support/Apple")
        try runner.expect(sg.isCriticalSharedDirectory(sysAppleSupport.path), "/Library/Application Support/Apple must remain critical shared")
        try runner.expect(!sg.validateForRemoval(sysAppleSupport).isAllowed, "/Library/Application Support/Apple must remain blocked")
    }
}

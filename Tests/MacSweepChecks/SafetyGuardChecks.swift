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
}

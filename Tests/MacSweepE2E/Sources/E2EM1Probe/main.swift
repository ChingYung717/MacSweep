import Darwin
import E2EHarness
import Foundation
import MacSweepCore

let runner = E2ERunner(probeName: "E2EM1Probe")

private func lstatItem(_ url: URL) -> stat? {
    var st = stat()
    guard Darwin.lstat(url.path, &st) == 0 else { return nil }
    return st
}

private func isDirectoryOnDisk(_ url: URL) -> Bool {
    guard let st = lstatItem(url) else { return false }
    return (st.st_mode & S_IFMT) == S_IFDIR
}

private func isRegularFileOnDisk(_ url: URL) -> Bool {
    guard let st = lstatItem(url) else { return false }
    return (st.st_mode & S_IFMT) == S_IFREG
}

private func isSymlinkOnDisk(_ url: URL) -> Bool {
    guard let st = lstatItem(url) else { return false }
    return (st.st_mode & S_IFMT) == S_IFLNK
}

// MARK: - F-2: Move / Rename / Mkdir Safety Boundaries (5 Tier 1 + 5 Tier 2)

runner.register(
    id: "f2-move-file-dir-symlink",
    tier: 1,
    feature: "F-2",
    name: "FileOperationsEngine.moveItem safely moves regular file, nested directory, and benign symlink"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f2-move")
    defer { sandbox.cleanup() }

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let engine = FileOperationsEngine(safetyGuard: sg)

    let srcDir = try sandbox.createDirectory("Work/Src")
    let dstDir = try sandbox.createDirectory("Work/Dest")
    let file = try sandbox.createFile("Work/Src/notes.txt", utf8: "hello-move-payload")
    let nestedDir = try sandbox.createDirectory("Work/Src/Folder")
    _ = try sandbox.createFile("Work/Src/Folder/Sub/item.dat", utf8: "nested-bytes")
    let targetFile = try sandbox.createFile("Keep/target.txt", utf8: "untouched-target")
    let symlink = try sandbox.createSymlink(atRelativePath: "Work/Src/alias", targetURL: targetFile)

    let srcParent = sandbox.canonicalPath(for: srcDir)
    let dstCanonical = sandbox.canonicalPath(for: dstDir)

    let movedFile = try await engine.moveItem(
        from: file,
        to: dstDir,
        expectedSourceCanonicalParent: srcParent,
        expectedDestinationCanonicalParent: dstCanonical
    )
    try E2ERunner.expect(!isRegularFileOnDisk(file), "Source file should be moved away")
    try E2ERunner.expect(isRegularFileOnDisk(movedFile), "Moved file should exist at destination")
    try E2ERunner.expectEqual(try String(contentsOf: movedFile, encoding: .utf8), "hello-move-payload")

    let movedFolder = try await engine.moveItem(
        from: nestedDir,
        to: dstDir,
        expectedSourceCanonicalParent: srcParent
    )
    try E2ERunner.expect(!isDirectoryOnDisk(nestedDir), "Source folder should be moved away")
    try E2ERunner.expect(isDirectoryOnDisk(movedFolder), "Moved folder should exist at destination")
    let nestedPayload = movedFolder.appendingPathComponent("Sub/item.dat")
    try E2ERunner.expectEqual(try String(contentsOf: nestedPayload, encoding: .utf8), "nested-bytes")

    let movedLink = try await engine.moveItem(
        from: symlink,
        to: dstDir,
        expectedSourceCanonicalParent: srcParent
    )
    try E2ERunner.expect(lstatItem(symlink) == nil, "Original symlink should be moved away")
    try E2ERunner.expect(isSymlinkOnDisk(movedLink), "Moved item must remain a symlink without dereferencing")
    try E2ERunner.expectEqual(try String(contentsOf: targetFile, encoding: .utf8), "untouched-target")
}

runner.register(
    id: "f2-rename-valid-and-case-only",
    tier: 1,
    feature: "F-2",
    name: "FileOperationsEngine.renameItem performs normal rename, directory rename, and APFS case-only rename preserving inode"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f2-rename")
    defer { sandbox.cleanup() }

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let engine = FileOperationsEngine(safetyGuard: sg)

    let work = try sandbox.createDirectory("Work")
    let draft = try sandbox.createFile("Work/draft.txt", utf8: "rename-contents")
    let workCanonical = sandbox.canonicalPath(for: work)

    let renamed = try await engine.renameItem(
        at: draft,
        toNewName: "readme.txt",
        expectedSourceCanonicalParent: workCanonical
    )
    try E2ERunner.expectEqual(renamed.lastPathComponent, "readme.txt")
    try E2ERunner.expect(isRegularFileOnDisk(renamed), "Renamed file must exist")

    let stBefore = try E2ERunner.expectNotNil(lstatItem(renamed))
    let caseRenamed = try await engine.renameItem(
        at: renamed,
        toNewName: "README.TXT",
        expectedSourceCanonicalParent: workCanonical
    )
    try E2ERunner.expectEqual(caseRenamed.lastPathComponent, "README.TXT")
    let diskEntries = try FileManager.default.contentsOfDirectory(atPath: work.path)
    try E2ERunner.expect(diskEntries.contains("README.TXT"), "On-disk directory listing must contain 'README.TXT', got \(diskEntries)")
    let stAfter = try E2ERunner.expectNotNil(lstatItem(caseRenamed))
    try E2ERunner.expectEqual(stAfter.st_dev, stBefore.st_dev)
    try E2ERunner.expectEqual(stAfter.st_ino, stBefore.st_ino)
    try E2ERunner.expectEqual(try String(contentsOf: caseRenamed, encoding: .utf8), "rename-contents")

    let oldDir = try sandbox.createDirectory("Work/OldDir")
    _ = try sandbox.createFile("Work/OldDir/inside.txt", utf8: "dir-payload")
    let newDir = try await engine.renameItem(
        at: oldDir,
        toNewName: "NewDir",
        expectedSourceCanonicalParent: workCanonical
    )
    try E2ERunner.expectEqual(newDir.lastPathComponent, "NewDir")
    try E2ERunner.expect(isDirectoryOnDisk(newDir))
    try E2ERunner.expectEqual(
        try String(contentsOf: newDir.appendingPathComponent("inside.txt"), encoding: .utf8),
        "dir-payload"
    )
}

runner.register(
    id: "f2-mkdir-valid",
    tier: 1,
    feature: "F-2",
    name: "FileOperationsEngine.createDirectory creates normal, Unicode/space, and ~/Documents child directories"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f2-mkdir")
    defer { sandbox.cleanup() }

    _ = try sandbox.createDirectory("Documents")
    let work = try sandbox.createDirectory("Work")
    let docs = sandbox.url("Documents")

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let engine = FileOperationsEngine(safetyGuard: sg)

    let normal = try await engine.createDirectory(
        named: "Projects",
        in: work,
        expectedParentCanonicalParent: sandbox.canonicalPath(for: work)
    )
    try E2ERunner.expect(isDirectoryOnDisk(normal), "Created Projects dir should exist")

    let unicode = try await engine.createDirectory(named: "设计 文档 🚀", in: normal)
    try E2ERunner.expect(isDirectoryOnDisk(unicode), "Created Unicode/space dir should exist")

    let docsChild = try await engine.createDirectory(named: "ClientWork", in: docs)
    try E2ERunner.expect(isDirectoryOnDisk(docsChild), "Child directory inside ~/Documents should be allowed")
}

runner.register(
    id: "f2-inspect-metadata-kinds",
    tier: 1,
    feature: "F-2",
    name: "FileOperationsEngine.inspectMetadata accurately reports regular, hidden, valid/broken symlink, uchg, and package metadata"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f2-meta")
    defer { sandbox.cleanup() }

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let engine = FileOperationsEngine(safetyGuard: sg)

    let work = try sandbox.createDirectory("Work")
    let reg = try sandbox.createFile("Work/sample.txt", utf8: "0123456789", permissions: 0o640)
    let hidden = try sandbox.createFile("Work/.hidden.cfg", utf8: "secret")
    let validLink = try sandbox.createSymlink(atRelativePath: "Work/valid.link", targetURL: reg)
    let brokenLink = try sandbox.createSymlink(
        atRelativePath: "Work/broken.link",
        targetPath: sandbox.url("Work/does-not-exist.txt").path
    )
    let locked = try sandbox.createFile("Work/locked.txt", utf8: "locked")
    try sandbox.setUserImmutable(locked, locked: true)
    let mockApp = try sandbox.createMockAppBundle(
        atRelativePath: "Work/Demo.app",
        bundleID: "com.example.demo",
        name: "Demo"
    )

    let expectedParent = sandbox.canonicalPath(for: work)

    let regInfo = try engine.inspectMetadata(at: reg)
    try E2ERunner.expectEqual(regInfo.kind, .regularFile)
    try E2ERunner.expectEqual(regInfo.sizeBytes, 10)
    try E2ERunner.expectNotNil(regInfo.allocatedSizeBytes)
    try E2ERunner.expectEqual(regInfo.posixPermissionsOctal, "0640")
    try E2ERunner.expect(!regInfo.isHidden)
    try E2ERunner.expect(!regInfo.isUserImmutable)
    try E2ERunner.expectEqual(regInfo.expectedCanonicalParent, expectedParent)

    let hiddenInfo = try engine.inspectMetadata(at: hidden)
    try E2ERunner.expect(hiddenInfo.isHidden, "Dotfile should report isHidden == true")

    let validLinkInfo = try engine.inspectMetadata(at: validLink)
    try E2ERunner.expectEqual(validLinkInfo.kind, .symbolicLink)
    try E2ERunner.expect(validLinkInfo.isSymbolicLink)
    try E2ERunner.expect(!validLinkInfo.isSymlinkBroken)
    try E2ERunner.expectNotNil(validLinkInfo.symlinkTarget)
    try E2ERunner.expectEqual(validLinkInfo.resolvedTargetPath, sandbox.canonicalPath(for: reg))
    try E2ERunner.expectNil(validLinkInfo.allocatedSizeBytes)

    let brokenLinkInfo = try engine.inspectMetadata(at: brokenLink)
    try E2ERunner.expectEqual(brokenLinkInfo.kind, .symbolicLink)
    try E2ERunner.expect(brokenLinkInfo.isSymbolicLink)
    try E2ERunner.expect(brokenLinkInfo.isSymlinkBroken)
    try E2ERunner.expectNil(brokenLinkInfo.resolvedTargetPath)

    let lockedInfo = try engine.inspectMetadata(at: locked)
    try E2ERunner.expect(lockedInfo.isUserImmutable)
    try E2ERunner.expect(!lockedInfo.isSIPRestricted)

    let appInfo = try engine.inspectMetadata(at: mockApp)
    try E2ERunner.expectEqual(appInfo.kind, .package)
    try E2ERunner.expect(appInfo.isPackage)
}

runner.register(
    id: "f2-cache-subpath-allow-leaf",
    tier: 1,
    feature: "F-2",
    name: "SafetyGuard.validateCacheSubpath allows <Vendor>/<AppCache> and standalone <AppCache> inside ~/Library/Caches"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f2-cache-ok")
    defer { sandbox.cleanup() }

    _ = try sandbox.createDirectory("Library/Caches/Google/Chrome")
    _ = try sandbox.createDirectory("Library/Caches/Microsoft/OneNote")
    _ = try sandbox.createDirectory("Library/Caches/com.example.widget")

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    try E2ERunner.expectEqual(sg.validateCacheSubpath(sandbox.url("Library/Caches/Google/Chrome")), .allowed)
    try E2ERunner.expectEqual(sg.validateCacheSubpath(sandbox.url("Library/Caches/Microsoft/OneNote")), .allowed)
    try E2ERunner.expectEqual(sg.validateCacheSubpath(sandbox.url("Library/Caches/com.example.widget")), .allowed)
}

runner.register(
    id: "f2-block-protected-escapes-and-photos",
    tier: 2,
    feature: "F-2",
    name: "SafetyGuard & FileOperationsEngine block protected roots, symlink escapes, *.photoslibrary, and protectedBundleIDs"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f2-escapes")
    defer { sandbox.cleanup() }

    let docsDir = try sandbox.createDirectory("Documents")
    let sshDir = try sandbox.createDirectory(".ssh")
    let sshKey = try sandbox.createFile(".ssh/id_ed25519", utf8: "PRIVATE-KEY")
    let selfData = try sandbox.createDirectory("Library/Application Support/MacSweep")
    let work = try sandbox.createDirectory("Work")
    let benignFile = try sandbox.createFile("Work/benign.txt", utf8: "safe")
    let escapeLink = try sandbox.createSymlink(atRelativePath: "Work/escape-ssh", targetURL: sshDir)
    let sysLink = try sandbox.createSymlink(atRelativePath: "Work/escape-sys", targetPath: "/System")
    let photosPkg = try sandbox.createDirectory("Work/Family.photoslibrary")
    let photosDB = try sandbox.createFile("Work/Family.photoslibrary/database/photos.sqlite", utf8: "db")
    let protApp = try sandbox.createMockAppBundle(
        atRelativePath: "Applications/KeepMe.app",
        bundleID: "com.example.keepme",
        name: "KeepMe"
    )
    _ = try sandbox.createDirectory("Applications/KeepMe.app/Contents/Resources")

    let sg = SafetyGuard(
        homeDirectory: sandbox.rootURL,
        selfBundlePath: nil,
        protectedPaths: [],
        protectedBundleIDs: ["com.example.keepme"]
    )
    let engine = FileOperationsEngine(safetyGuard: sg)
    let workParent = sandbox.canonicalPath(for: work)

    let blockedSources = [
        URL(fileURLWithPath: "/System"),
        URL(fileURLWithPath: "/Library/Apple"),
        docsDir,
        sshDir,
        sshKey,
        selfData,
        photosPkg,
        photosDB,
        protApp,
    ]
    for src in blockedSources {
        let val = sg.validateForMoveOrRename(source: src, destination: work.appendingPathComponent(src.lastPathComponent))
        try E2ERunner.expect(!val.isAllowed, "Expected move source blocked: \(src.path)")
    }

    // Symlink escape on createDirectory and moveItem into protected roots
    try await E2ERunner.expectThrowsAsync("createDirectory through symlink to ~/.ssh must fail") {
        _ = try await engine.createDirectory(named: "NewSub", in: escapeLink)
    }
    try await E2ERunner.expectThrowsAsync("createDirectory multi-level through symlink to ~/.ssh must fail") {
        _ = try await engine.createDirectory(named: "Nested", in: escapeLink.appendingPathComponent("NonExistent"))
    }
    try await E2ERunner.expectThrowsAsync("moveItem into symlink to ~/.ssh must fail") {
        _ = try await engine.moveItem(from: benignFile, to: escapeLink, expectedSourceCanonicalParent: workParent)
    }
    try await E2ERunner.expectThrowsAsync("moveItem into symlink to /System must fail") {
        _ = try await engine.moveItem(from: benignFile, to: sysLink, expectedSourceCanonicalParent: workParent)
    }
    try await E2ERunner.expectThrowsAsync("createDirectory inside protectedBundleID .app must fail") {
        _ = try await engine.createDirectory(
            named: "Injected",
            in: protApp.appendingPathComponent("Contents/Resources")
        )
    }
    try await E2ERunner.expectThrowsAsync("renameItem on *.photoslibrary must fail") {
        _ = try await engine.renameItem(
            at: photosPkg,
            toNewName: "Renamed.photoslibrary",
            expectedSourceCanonicalParent: workParent
        )
    }

    try E2ERunner.expect(isRegularFileOnDisk(benignFile), "Benign file should remain untouched")
    try E2ERunner.expect(isRegularFileOnDisk(sshKey), "SSH key should remain untouched")
}

runner.register(
    id: "f2-reject-invalid-names-and-urls",
    tier: 2,
    feature: "F-2",
    name: "FileOperationsEngine rejects invalid names (empty, dot, dotdot, slash, NUL, >255 UTF-8 bytes) and %00/dotdot URLs"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f2-names")
    defer { sandbox.cleanup() }

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let engine = FileOperationsEngine(safetyGuard: sg)

    let work = try sandbox.createDirectory("Work")
    let file = try sandbox.createFile("Work/valid.txt", utf8: "payload")
    _ = try sandbox.createDirectory("Work/Sub")
    let workParent = sandbox.canonicalPath(for: work)

    let overMaxUTF8 = String(repeating: "你", count: 86) // 258 UTF-8 bytes > NAME_MAX (255)
    let badNames = ["", ".", "..", "sub/name", "bad\0name", overMaxUTF8]

    for bad in badNames {
        let err = try E2ERunner.expectThrows("validateItemName must reject '\(bad.debugDescription)'") {
            try FileOperationsEngine.validateItemName(bad)
        }
        if case .invalidName = err as? FileOperationError {
            // Expected
        } else {
            throw E2EAssertionFailure("Expected .invalidName for '\(bad.debugDescription)', got \(err)")
        }

        try await E2ERunner.expectThrowsAsync("createDirectory must reject '\(bad.debugDescription)'") {
            _ = try await engine.createDirectory(named: bad, in: work)
        }
        try await E2ERunner.expectThrowsAsync("renameItem must reject '\(bad.debugDescription)'") {
            _ = try await engine.renameItem(at: file, toNewName: bad, expectedSourceCanonicalParent: workParent)
        }
    }

    let encodedNulURL = try E2ERunner.expectNotNil(URL(string: "file://\(work.path)/bad%00file"))
    let dotDotURL = URL(fileURLWithPath: work.path + "/Sub/../valid.txt", isDirectory: false)

    try await E2ERunner.expectThrowsAsync("moveItem must reject %00 URL") {
        _ = try await engine.moveItem(from: encodedNulURL, to: work, expectedSourceCanonicalParent: workParent)
    }
    try await E2ERunner.expectThrowsAsync("renameItem must reject unstandardized .. URL") {
        _ = try await engine.renameItem(at: dotDotURL, toNewName: "other.txt", expectedSourceCanonicalParent: workParent)
    }
    try E2ERunner.expectThrows("inspectMetadata must reject %00 URL") {
        _ = try engine.inspectMetadata(at: encodedNulURL)
    }
    try E2ERunner.expectThrows("inspectMetadata must reject unstandardized .. URL") {
        _ = try engine.inspectMetadata(at: dotDotURL)
    }
}

runner.register(
    id: "f2-toctou-parent-swap-and-noncanonical",
    tier: 2,
    feature: "F-2",
    name: "FileOperationsEngine throws .toctouMismatch on parent symlink swap and non-canonical /var expectedParent"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f2-toctou")
    defer { sandbox.cleanup() }

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let engine = FileOperationsEngine(safetyGuard: sg)

    let parentA = try sandbox.createDirectory("Work/ParentA")
    let victim = try sandbox.createFile("Work/ParentA/item.txt", utf8: "real")
    let decoy = try sandbox.createDirectory("Work/Decoy")
    let decoyItem = try sandbox.createFile("Work/Decoy/item.txt", utf8: "decoy-intact")
    let dest = try sandbox.createDirectory("Work/Dest")

    // Capture scan-time metadata BEFORE parent swap
    let meta = try engine.inspectMetadata(at: victim)
    try E2ERunner.expectEqual(meta.expectedCanonicalParent, sandbox.canonicalPath(for: parentA))

    // Non-canonical /var vs /private/var mismatch (sandbox.rawRootURL starts with /var/folders on macOS)
    let rawParentPath = sandbox.rawRootURL.appendingPathComponent("Work/ParentA").path
    if rawParentPath != meta.expectedCanonicalParent {
        let err = try await E2ERunner.expectThrowsAsync("Non-canonical parent path must fail TOCTOU check") {
            _ = try await engine.renameItem(
                at: victim,
                toNewName: "renamed.txt",
                expectedSourceCanonicalParent: rawParentPath
            )
        }
        if case .toctouMismatch = err as? FileOperationError {
            // Expected
        } else {
            throw E2EAssertionFailure("Expected .toctouMismatch for non-canonical parent, got \(err)")
        }
    }

    // Negative expectedDestinationCanonicalParent mismatch on moveItem (wrong parent & destination symlink swap)
    let wrongDestCanonical = sandbox.canonicalPath(for: decoy)
    let destMismatchErr = try await E2ERunner.expectThrowsAsync("moveItem must fail when expectedDestinationCanonicalParent mismatches") {
        _ = try await engine.moveItem(
            from: victim,
            to: dest,
            expectedSourceCanonicalParent: meta.expectedCanonicalParent,
            expectedDestinationCanonicalParent: wrongDestCanonical
        )
    }
    if case .toctouMismatch = destMismatchErr as? FileOperationError {
        // Expected
    } else {
        throw E2EAssertionFailure("Expected .toctouMismatch for wrong expectedDestinationCanonicalParent, got \(destMismatchErr)")
    }
    try E2ERunner.expect(isRegularFileOnDisk(victim), "victim must remain untouched after destination TOCTOU mismatch")
    try E2ERunner.expect(!isRegularFileOnDisk(dest.appendingPathComponent("item.txt")), "dest must remain untouched")

    let destSwap = try sandbox.createDirectory("Work/DestSwap")
    let destDecoy = try sandbox.createDirectory("Work/DestDecoy")
    let destSwapCanonical = sandbox.canonicalPath(for: destSwap)
    try FileManager.default.removeItem(at: destSwap)
    try FileManager.default.createSymbolicLink(at: destSwap, withDestinationURL: destDecoy)
    let destSwapErr = try await E2ERunner.expectThrowsAsync("moveItem must fail after destination directory symlink swap") {
        _ = try await engine.moveItem(
            from: victim,
            to: destSwap,
            expectedSourceCanonicalParent: meta.expectedCanonicalParent,
            expectedDestinationCanonicalParent: destSwapCanonical
        )
    }
    if case .toctouMismatch = destSwapErr as? FileOperationError {
        // Expected
    } else {
        throw E2EAssertionFailure("Expected .toctouMismatch after destination symlink swap, got \(destSwapErr)")
    }
    try E2ERunner.expect(isRegularFileOnDisk(victim), "victim must remain untouched after destination symlink swap")
    try E2ERunner.expect(!isRegularFileOnDisk(destDecoy.appendingPathComponent("item.txt")), "DestDecoy must remain untouched")

    // Swap ParentA for a symlink to Decoy
    try FileManager.default.removeItem(at: parentA)
    try FileManager.default.createSymbolicLink(at: parentA, withDestinationURL: decoy)

    let moveErr = try await E2ERunner.expectThrowsAsync("moveItem must fail after parent symlink swap") {
        _ = try await engine.moveItem(
            from: victim,
            to: dest,
            expectedSourceCanonicalParent: meta.expectedCanonicalParent
        )
    }
    if case .toctouMismatch = moveErr as? FileOperationError {
        // Expected
    } else {
        throw E2EAssertionFailure("Expected .toctouMismatch on moveItem, got \(moveErr)")
    }

    let renameErr = try await E2ERunner.expectThrowsAsync("renameItem must fail after parent symlink swap") {
        _ = try await engine.renameItem(
            at: victim,
            toNewName: "pwned.txt",
            expectedSourceCanonicalParent: meta.expectedCanonicalParent
        )
    }
    if case .toctouMismatch = renameErr as? FileOperationError {
        // Expected
    } else {
        throw E2EAssertionFailure("Expected .toctouMismatch on renameItem, got \(renameErr)")
    }

    let mkdirErr = try await E2ERunner.expectThrowsAsync("createDirectory must fail after parent symlink swap") {
        _ = try await engine.createDirectory(
            named: "Child",
            in: parentA,
            expectedParentCanonicalParent: meta.expectedCanonicalParent
        )
    }
    if case .toctouMismatch = mkdirErr as? FileOperationError {
        // Expected
    } else {
        throw E2EAssertionFailure("Expected .toctouMismatch on createDirectory, got \(mkdirErr)")
    }

    try E2ERunner.expectEqual(try String(contentsOf: decoyItem, encoding: .utf8), "decoy-intact")
}

runner.register(
    id: "f2-uchg-selfmove-collision-hardlink-fifo",
    tier: 2,
    feature: "F-2",
    name: "FileOperationsEngine blocks uchg mutation, self/descendant move, collisions, hardlink case rename, and non-blocking FIFO inspect"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f2-edge")
    defer { sandbox.cleanup() }

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)
    let engine = FileOperationsEngine(safetyGuard: sg)

    let work = try sandbox.createDirectory("Work")
    let dest = try sandbox.createDirectory("Dest")
    let workParent = sandbox.canonicalPath(for: work)

    // 1. uchg immutable source
    let lockedFile = try sandbox.createFile("Work/locked.txt", utf8: "immutable")
    try sandbox.setUserImmutable(lockedFile, locked: true)
    let moveUchgErr = try await E2ERunner.expectThrowsAsync("moveItem on uchg must fail") {
        _ = try await engine.moveItem(from: lockedFile, to: dest, expectedSourceCanonicalParent: workParent)
    }
    try E2ERunner.expectEqual(moveUchgErr as? FileOperationError, .userImmutable(path: lockedFile.standardizedFileURL.path))

    let renameUchgErr = try await E2ERunner.expectThrowsAsync("renameItem on uchg must fail") {
        _ = try await engine.renameItem(at: lockedFile, toNewName: "unlocked.txt", expectedSourceCanonicalParent: workParent)
    }
    try E2ERunner.expectEqual(renameUchgErr as? FileOperationError, .userImmutable(path: lockedFile.standardizedFileURL.path))
    try E2ERunner.expect(isRegularFileOnDisk(lockedFile))

    // 2. Self / descendant move
    let tree = try sandbox.createDirectory("Work/Tree")
    let subTree = try sandbox.createDirectory("Work/Tree/Sub")
    let selfMoveErr = try await E2ERunner.expectThrowsAsync("Moving dir into descendant must fail") {
        _ = try await engine.moveItem(from: tree, to: subTree, expectedSourceCanonicalParent: workParent)
    }
    if case .cannotMoveDirectoryIntoItself = selfMoveErr as? FileOperationError {
        // Expected
    } else {
        throw E2EAssertionFailure("Expected .cannotMoveDirectoryIntoItself, got \(selfMoveErr)")
    }

    // 3. Collision checks (exact & APFS case-insensitive)
    _ = try sandbox.createDirectory("Work/ExistingDir")
    let existingFile = try sandbox.createFile("Work/Existing.txt", utf8: "keep-original")
    _ = try sandbox.createFile("Dest/Existing.txt", utf8: "dest-original")

    let moveCollErr = try await E2ERunner.expectThrowsAsync("moveItem must not overwrite existing item") {
        _ = try await engine.moveItem(from: existingFile, to: dest, expectedSourceCanonicalParent: workParent)
    }
    if case .destinationAlreadyExists = moveCollErr as? FileOperationError {
        // Expected
    } else {
        throw E2EAssertionFailure("Expected .destinationAlreadyExists on moveItem, got \(moveCollErr)")
    }

    let sameRenameErr = try await E2ERunner.expectThrowsAsync("renameItem with identical name must fail") {
        _ = try await engine.renameItem(at: existingFile, toNewName: "Existing.txt", expectedSourceCanonicalParent: workParent)
    }
    if case .destinationAlreadyExists = sameRenameErr as? FileOperationError {
        // Expected
    } else {
        throw E2EAssertionFailure("Expected .destinationAlreadyExists on same-name rename, got \(sameRenameErr)")
    }

    let mkdirCollErr = try await E2ERunner.expectThrowsAsync("createDirectory must reject existing case-colliding dir") {
        _ = try await engine.createDirectory(named: "existingdir", in: work)
    }
    if case .destinationAlreadyExists = mkdirCollErr as? FileOperationError {
        // Expected
    } else {
        throw E2EAssertionFailure("Expected .destinationAlreadyExists on case-colliding mkdir, got \(mkdirCollErr)")
    }

    // 4. Hardlinked regular file case-only rename blocked
    let hardA = try sandbox.createFile("Work/HardLink.txt", utf8: "shared-inode")
    let hardB = try sandbox.createHardlink(atRelativePath: "Work/HardLinkPeer.txt", to: hardA)
    try await E2ERunner.expectThrowsAsync("Case-only rename of hardlinked regular file must be blocked") {
        _ = try await engine.renameItem(at: hardA, toNewName: "hardlink.txt", expectedSourceCanonicalParent: workParent)
    }
    try E2ERunner.expectEqual(try String(contentsOf: hardB, encoding: .utf8), "shared-inode")

    // 5. FIFO inspectMetadata non-blocking
    let fifo = try sandbox.createFIFO(atRelativePath: "Work/pipe.fifo")
    let t0 = Date()
    let fifoMeta = try engine.inspectMetadata(at: fifo)
    let elapsed = Date().timeIntervalSince(t0)
    try E2ERunner.expect(elapsed < 1.0, "inspectMetadata on FIFO must not block (took \(elapsed)s)")
    try E2ERunner.expectEqual(fifoMeta.kind, .special)
    try E2ERunner.expectNil(fifoMeta.allocatedSizeBytes)
}

runner.register(
    id: "f2-cache-subpath-boundaries",
    tier: 2,
    feature: "F-2",
    name: "SafetyGuard.validateCacheSubpath blocks Caches root, shared vendors, Apple/group containers, selfData, and symlink escapes"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f2-cache-blk")
    defer { sandbox.cleanup() }

    _ = try sandbox.createDirectory("Library/Caches/Google")
    _ = try sandbox.createDirectory("Library/Caches/Microsoft")
    _ = try sandbox.createDirectory("Library/Caches/Adobe")
    _ = try sandbox.createDirectory("Library/Caches/Apple/Sub")
    _ = try sandbox.createDirectory("Library/Caches/com.apple.Safari")
    _ = try sandbox.createDirectory("Library/Caches/group.com.apple.notes")
    _ = try sandbox.createDirectory("Library/Caches/local.macsweep")
    let outside = try sandbox.createDirectory("Work/ExternalCache")
    let escapeLink = try sandbox.createSymlink(atRelativePath: "Library/Caches/Escape", targetURL: outside)
    _ = try sandbox.createDirectory("Documents/Notes")

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil)

    let blockedURLs: [URL] = [
        sandbox.url("Library/Caches"),
        sandbox.url("Library/Caches/Google"),
        sandbox.url("Library/Caches/Microsoft"),
        sandbox.url("Library/Caches/Adobe"),
        sandbox.url("Library/Caches/Apple"),
        sandbox.url("Library/Caches/Apple/Sub"),
        sandbox.url("Library/Caches/com.apple"),
        sandbox.url("Library/Caches/com.apple.Safari"),
        sandbox.url("Library/Caches/group.com.apple.notes"),
        sandbox.url("Library/Caches/local.macsweep"),
        escapeLink,
        escapeLink.appendingPathComponent("Sub"),
        sandbox.url("Documents/Notes"),
        URL(fileURLWithPath: sandbox.url("Library/Caches").path + "/../Documents/Notes"),
    ]

    for url in blockedURLs {
        let res = sg.validateCacheSubpath(url)
        try E2ERunner.expect(!res.isAllowed, "validateCacheSubpath must block \(url.path)")
    }
}

// MARK: - F-3: Protected Paths Preferences & Enforcement (5 Tier 1 + 5 Tier 2)

runner.register(
    id: "f3-prefs-protected-paths-roundtrip",
    tier: 1,
    feature: "F-3",
    name: "PreferencesStore roundtrips protectedPaths alongside bundle/leftover/theme/lang/mode with 0600 permissions"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f3-prefs")
    defer { sandbox.cleanup() }

    let prefsURL = sandbox.url("Config/preferences.json")
    let store = PreferencesStore(fileURL: prefsURL)

    let p1 = sandbox.url("Work/KeepOne").path
    let p2 = sandbox.url("Work/KeepTwo/secret.db").path
    let prefs = SweepPreferences(
        themeMode: .system,
        language: .en,
        defaultRemovalMode: .permanent,
        showSystemApps: true,
        includeUtilitiesFolder: true,
        protectedBundleIDs: ["com.example.alpha", "com.example.beta"],
        protectedPaths: [p1, p2],
        ignoredLeftoverIDs: ["ignored.leftover.1"]
    )

    try E2ERunner.expect(store.save(prefs), "PreferencesStore.save must succeed")
    try E2ERunner.expect(!store.isWriteBlockedDueToLoadError, "Write block must be false")

    let reloadedStore = PreferencesStore(fileURL: prefsURL)
    let loaded = reloadedStore.load()
    try E2ERunner.expect(!reloadedStore.isWriteBlockedDueToLoadError)
    try E2ERunner.expectEqual(loaded, prefs)

    let st = try E2ERunner.expectNotNil(lstatItem(prefsURL))
    try E2ERunner.expectEqual(st.st_mode & 0o777, mode_t(0o600), "preferences.json must have 0600 permissions")
}

runner.register(
    id: "f3-protected-paths-block-removal",
    tier: 1,
    feature: "F-3",
    name: "SafetyGuard(protectedPaths:) blocks validateForRemoval and RemovalEngine.remove inside protectedPaths"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f3-rm-block")
    defer { sandbox.cleanup() }

    let protDir = try sandbox.createDirectory("Work/Vault")
    let protNested = try sandbox.createFile("Work/Vault/Nested/key.txt", utf8: "vault-secret")
    let protFile = try sandbox.createFile("Work/single.db", utf8: "single-secret")
    let mockTrash = try sandbox.createDirectory("MockTrash")

    let sg = SafetyGuard(
        homeDirectory: sandbox.rootURL,
        selfBundlePath: nil,
        protectedPaths: [protDir.path, protFile.path]
    )

    try E2ERunner.expect(!sg.validateForRemoval(protDir).isAllowed, "Protected directory must be blocked")
    try E2ERunner.expect(!sg.validateForRemoval(protNested).isAllowed, "Nested child of protected dir must be blocked")
    try E2ERunner.expect(!sg.validateForRemoval(protFile).isAllowed, "Protected file must be blocked")
    try E2ERunner.expect(sg.isUserProtected(bundleID: nil, url: protNested), "isUserProtected must be true")

    let engine = RemovalEngine(
        safetyGuard: sg,
        localTrashHandler: { itemURL in
            try FileManager.default.moveItem(at: itemURL, to: mockTrash.appendingPathComponent(itemURL.lastPathComponent))
        }
    )

    for mode in [RemovalMode.trash, RemovalMode.permanent] {
        let report = engine.remove(
            targets: [
                RemovalTarget(url: protDir, estimatedSize: 12),
                RemovalTarget(url: protNested, estimatedSize: 12),
                RemovalTarget(url: protFile, estimatedSize: 13),
            ],
            mode: mode,
            allowElevation: false
        )
        try E2ERunner.expect(report.succeededURLs.isEmpty, "Protected targets must never succeed in mode \(mode)")
        try E2ERunner.expectEqual(report.failures.count, 3)
    }

    try E2ERunner.expect(isRegularFileOnDisk(protNested))
    try E2ERunner.expect(isRegularFileOnDisk(protFile))
}

runner.register(
    id: "f3-protected-paths-block-fileops",
    tier: 1,
    feature: "F-3",
    name: "SafetyGuard & FileOperationsEngine block moveItem, renameItem, and createDirectory inside protectedPaths"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f3-ops-block")
    defer { sandbox.cleanup() }

    let protDir = try sandbox.createDirectory("Work/Protected")
    let protChild = try sandbox.createFile("Work/Protected/doc.txt", utf8: "stay-put")
    let freeDir = try sandbox.createDirectory("Work/Free")
    let freeFile = try sandbox.createFile("Work/Free/move-me.txt", utf8: "free-payload")

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil, protectedPaths: [protDir.path])
    let engine = FileOperationsEngine(safetyGuard: sg)

    let protParent = sandbox.canonicalPath(for: protDir)
    let freeParent = sandbox.canonicalPath(for: freeDir)

    let moveSrcErr = try await E2ERunner.expectThrowsAsync("moveItem from protectedPaths must fail") {
        _ = try await engine.moveItem(from: protChild, to: freeDir, expectedSourceCanonicalParent: protParent)
    }
    if case .blockedBySafetyGuard = moveSrcErr as? FileOperationError {} else {
        throw E2EAssertionFailure("Expected .blockedBySafetyGuard for source in protectedPaths, got \(moveSrcErr)")
    }

    let moveDstErr = try await E2ERunner.expectThrowsAsync("moveItem into protectedPaths must fail") {
        _ = try await engine.moveItem(from: freeFile, to: protDir, expectedSourceCanonicalParent: freeParent)
    }
    if case .blockedBySafetyGuard = moveDstErr as? FileOperationError {} else {
        throw E2EAssertionFailure("Expected .blockedBySafetyGuard for destination in protectedPaths, got \(moveDstErr)")
    }

    let renameErr = try await E2ERunner.expectThrowsAsync("renameItem inside protectedPaths must fail") {
        _ = try await engine.renameItem(at: protChild, toNewName: "renamed.txt", expectedSourceCanonicalParent: protParent)
    }
    if case .blockedBySafetyGuard = renameErr as? FileOperationError {} else {
        throw E2EAssertionFailure("Expected .blockedBySafetyGuard for rename in protectedPaths, got \(renameErr)")
    }

    let mkdirErr = try await E2ERunner.expectThrowsAsync("createDirectory inside protectedPaths must fail") {
        _ = try await engine.createDirectory(named: "Sub", in: protDir)
    }
    if case .blockedBySafetyGuard = mkdirErr as? FileOperationError {} else {
        throw E2EAssertionFailure("Expected .blockedBySafetyGuard for mkdir in protectedPaths, got \(mkdirErr)")
    }

    try E2ERunner.expect(isRegularFileOnDisk(protChild))
    try E2ERunner.expect(isRegularFileOnDisk(freeFile))
}

runner.register(
    id: "f3-protected-paths-allow-siblings",
    tier: 1,
    feature: "F-3",
    name: "SafetyGuard allows removal and file operations on sibling paths (including /Work2 when /Work is protected)"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f3-siblings")
    defer { sandbox.cleanup() }

    let work = try sandbox.createDirectory("Work")
    _ = try sandbox.createFile("Work/keep.txt", utf8: "keep")
    let work2 = try sandbox.createDirectory("Work2")
    let work2File = try sandbox.createFile("Work2/ok.txt", utf8: "ok-sibling")
    let dest = try sandbox.createDirectory("Dest")

    let sg = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil, protectedPaths: [work.path])
    try E2ERunner.expect(!sg.validateForRemoval(work).isAllowed, "/Work must remain blocked")
    try E2ERunner.expectEqual(sg.validateForRemoval(work2), .allowed)
    try E2ERunner.expectEqual(sg.validateForRemoval(work2File), .allowed)

    let engine = FileOperationsEngine(safetyGuard: sg)
    let created = try await engine.createDirectory(named: "Sub2", in: work2)
    try E2ERunner.expect(isDirectoryOnDisk(created))

    let renamed = try await engine.renameItem(
        at: work2File,
        toNewName: "ok-renamed.txt",
        expectedSourceCanonicalParent: sandbox.canonicalPath(for: work2)
    )
    let moved = try await engine.moveItem(
        from: renamed,
        to: dest,
        expectedSourceCanonicalParent: sandbox.canonicalPath(for: work2)
    )
    try E2ERunner.expect(isRegularFileOnDisk(moved))

    let removal = RemovalEngine(safetyGuard: sg)
    let report = removal.remove(targets: [RemovalTarget(url: moved, estimatedSize: 10)], mode: .permanent, allowElevation: false)
    try E2ERunner.expect(report.isFullSuccess, "Sibling removal must succeed: \(report.failures)")
    try E2ERunner.expect(!RemovalEngine.entryExists(moved))
}

runner.register(
    id: "f3-protected-paths-and-prefs-lifecycle",
    tier: 1,
    feature: "F-3",
    name: "Updating PreferencesStore.protectedPaths preserves protectedBundleIDs/ignoredLeftoverIDs and updates SafetyGuard enforcement"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f3-lifecycle")
    defer { sandbox.cleanup() }

    let prefsURL = sandbox.url("Config/preferences.json")
    let store = PreferencesStore(fileURL: prefsURL)
    let targetFile = try sandbox.createFile("Work/toggle.txt", utf8: "toggle")
    let protectedCache = try sandbox.createDirectory("Library/Caches/com.example.kept")

    let initial = SweepPreferences(
        themeMode: .deepOcean,
        language: .zhHans,
        defaultRemovalMode: .trash,
        protectedBundleIDs: ["com.example.kept"],
        protectedPaths: [targetFile.path],
        ignoredLeftoverIDs: ["leftover.alpha", "leftover.beta"]
    )
    try E2ERunner.expect(store.save(initial))

    let loaded1 = PreferencesStore(fileURL: prefsURL).load()
    let sg1 = SafetyGuard(
        homeDirectory: sandbox.rootURL,
        selfBundlePath: nil,
        protectedPaths: loaded1.protectedPaths,
        protectedBundleIDs: loaded1.protectedBundleIDs
    )
    try E2ERunner.expect(!sg1.validateForRemoval(targetFile).isAllowed)
    try E2ERunner.expect(!sg1.validateForRemoval(protectedCache).isAllowed)

    var updated = loaded1
    updated.protectedPaths.removeAll()
    try E2ERunner.expect(PreferencesStore(fileURL: prefsURL).save(updated))

    let loaded2 = PreferencesStore(fileURL: prefsURL).load()
    try E2ERunner.expectEqual(loaded2.protectedBundleIDs, ["com.example.kept"])
    try E2ERunner.expectEqual(loaded2.ignoredLeftoverIDs, ["leftover.alpha", "leftover.beta"])
    try E2ERunner.expectEqual(loaded2.themeMode, .deepOcean)
    try E2ERunner.expectEqual(loaded2.language, .zhHans)

    let sg2 = SafetyGuard(
        homeDirectory: sandbox.rootURL,
        selfBundlePath: nil,
        protectedPaths: loaded2.protectedPaths,
        protectedBundleIDs: loaded2.protectedBundleIDs
    )
    try E2ERunner.expectEqual(sg2.validateForRemoval(targetFile), .allowed)
    try E2ERunner.expect(!sg2.validateForRemoval(protectedCache).isAllowed, "protectedBundleIDs must remain enforced")
}

runner.register(
    id: "f3-path-normalization-trailing-symlink-relative",
    tier: 2,
    feature: "F-3",
    name: "SafetyGuard normalizes trailing slashes, /var vs /private/var, ../ components, and symlinks in protectedPaths"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f3-norm")
    defer { sandbox.cleanup() }

    let protReal = try sandbox.createDirectory("Real/KeepDir")
    let protChild = try sandbox.createFile("Real/KeepDir/data.bin", utf8: "x")
    let symlinkToProt = try sandbox.createSymlink(atRelativePath: "Alias/ToKeep", targetURL: protReal)
    let symlinkTarget = try sandbox.createDirectory("Real/LinkedTarget")
    let symlinkProtected = try sandbox.createSymlink(atRelativePath: "Alias/ProtectedLink", targetURL: symlinkTarget)
    _ = try sandbox.createFile("Real/LinkedTarget/inside.txt", utf8: "y")

    // Use rawRootURL (/var/folders/... on macOS), trailing slash, and Work/../Real/KeepDir
    let rawWithTrailing = sandbox.rawRootURL.appendingPathComponent("Real/KeepDir").path + "/"
    let dotDotPath = sandbox.rootURL.appendingPathComponent("Work/../Real/KeepDir").path
    let futureSubViaLink = symlinkToProt.appendingPathComponent("FutureDir").path

    let sg1 = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil, protectedPaths: [rawWithTrailing])
    try E2ERunner.expect(!sg1.validateForRemoval(protReal).isAllowed, "Trailing slash + /var should protect /private/var target")
    try E2ERunner.expect(!sg1.validateForRemoval(protChild).isAllowed)
    try E2ERunner.expect(!sg1.validateForRemoval(symlinkToProt).isAllowed, "Symlink pointing into protected dir must be blocked")

    let sg2 = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil, protectedPaths: [dotDotPath])
    try E2ERunner.expect(!sg2.validateForRemoval(protReal).isAllowed, "Relative /../ path in protectedPaths must still protect target")

    let sg3 = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil, protectedPaths: [symlinkProtected.path, futureSubViaLink])
    try E2ERunner.expect(!sg3.validateForRemoval(symlinkTarget).isAllowed, "Protecting a symlink must also protect its resolved target")
    try E2ERunner.expect(!sg3.validateDirectoryCreation(at: protReal.appendingPathComponent("FutureDir")).isAllowed, "Non-existent protected path via symlink must block mkdir")
}

runner.register(
    id: "f3-parent-child-overlap",
    tier: 2,
    feature: "F-3",
    name: "SafetyGuard enforces bidirectional parent/child overlap for protectedPaths"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f3-overlap")
    defer { sandbox.cleanup() }

    let keep = try sandbox.createDirectory("Keep")
    let sub = try sandbox.createDirectory("Keep/Sub")
    let leaf = try sandbox.createFile("Keep/Sub/leaf.txt", utf8: "important")
    let dest = try sandbox.createDirectory("Dest")

    let sgParentProt = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil, protectedPaths: [keep.path])
    try E2ERunner.expect(!sgParentProt.validateForRemoval(leaf).isAllowed, "Protecting parent must protect descendant")

    let sgChildProt = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil, protectedPaths: [sub.path])
    try E2ERunner.expect(!sgChildProt.validateForRemoval(leaf).isAllowed, "Protecting /Keep/Sub must block /Keep/Sub/leaf.txt")
    try E2ERunner.expect(!sgChildProt.validateForRemoval(keep).isAllowed, "Protecting /Keep/Sub must block removing ancestor /Keep")

    let engine = FileOperationsEngine(safetyGuard: sgChildProt)
    try await E2ERunner.expectThrowsAsync("Moving ancestor /Keep when /Keep/Sub is protected must fail") {
        _ = try await engine.moveItem(from: keep, to: dest, expectedSourceCanonicalParent: sandbox.canonicalRootPath)
    }
}

runner.register(
    id: "f3-case-and-unicode-nfc-nfd",
    tier: 2,
    feature: "F-3",
    name: "SafetyGuard enforces case-insensitive and Unicode NFC/NFD normalization for protectedPaths"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f3-unicode")
    defer { sandbox.cleanup() }

    let nfcName = "Café"        // U+00E9 precomposed
    let nfdName = "cafe\u{0301}" // decomposed + lowercase

    let nfcDir = try sandbox.createDirectory("Work/\(nfcName)")
    let nfcFile = try sandbox.createFile("Work/\(nfcName)/notes.txt", utf8: "unicode")

    // Protect using NFD lowercase string while checking NFC mixed-case disk URL
    let nfdProtectedPath = sandbox.url("Work").appendingPathComponent(nfdName).path
    let sgNFD = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil, protectedPaths: [nfdProtectedPath])
    try E2ERunner.expect(!sgNFD.validateForRemoval(nfcDir).isAllowed, "NFD protectedPath must block NFC directory")
    try E2ERunner.expect(!sgNFD.validateForRemoval(nfcFile).isAllowed, "NFD protectedPath must block child of NFC directory")

    // Protect using NFC uppercase string while checking NFD candidate URL
    let nfcUpperPath = sandbox.url("Work").appendingPathComponent("CAFÉ").path
    let sgNFC = SafetyGuard(homeDirectory: sandbox.rootURL, selfBundlePath: nil, protectedPaths: [nfcUpperPath])
    let nfdCandidate = sandbox.url("Work").appendingPathComponent(nfdName).appendingPathComponent("notes.txt")
    try E2ERunner.expect(!sgNFC.validateForRemoval(nfdCandidate).isAllowed, "NFC uppercase protectedPath must block NFD candidate")
}

runner.register(
    id: "f3-prefs-corrupt-oversized-symlink-write-block",
    tier: 2,
    feature: "F-3",
    name: "PreferencesStore refuses overwrite on corrupt JSON variants, oversized (>1MiB), and symlink preferences.json"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f3-prefblk")
    defer { sandbox.cleanup() }

    let variants: [(String, CorruptJSONVariant)] = [
        ("truncated", .truncated),
        ("invalidUTF8", .invalidUTF8),
        ("wrongRootType", .wrongRootType),
        ("empty", .empty),
    ]

    for (label, variant) in variants {
        let url = try sandbox.createCorruptJSON(atRelativePath: "Config/\(label).json", variant: variant)
        let originalData = try Data(contentsOf: url)
        let store = PreferencesStore(fileURL: url)

        let loaded = store.load()
        try E2ERunner.expectEqual(loaded, SweepPreferences(), "Variant \(label) must return default prefs")
        try E2ERunner.expect(store.isWriteBlockedDueToLoadError, "Variant \(label) must activate write block")
        try E2ERunner.expect(!store.save(SweepPreferences(protectedPaths: ["/tmp/x"])), "Variant \(label) must refuse save")
        try E2ERunner.expectEqual(try Data(contentsOf: url), originalData, "Variant \(label) bytes must stay preserved")
    }

    let oversizedURL = try sandbox.createOversizedJSON(atRelativePath: "Config/oversized.json", exceedingBytes: PreferencesStore.maxBytes + 64 * 1024)
    let oversizedBefore = try Data(contentsOf: oversizedURL)
    let oversizedStore = PreferencesStore(fileURL: oversizedURL)
    _ = oversizedStore.load()
    try E2ERunner.expect(oversizedStore.isWriteBlockedDueToLoadError)
    try E2ERunner.expect(!oversizedStore.save(SweepPreferences()))
    try E2ERunner.expectEqual(try Data(contentsOf: oversizedURL).count, oversizedBefore.count)

    let targetPrefs = try sandbox.createFile("Config/target.json", utf8: "{\"protectedPaths\":[\"/tmp/keep\"]}")
    let symlinkPrefs = try sandbox.createSymlink(atRelativePath: "Config/symlink-prefs.json", targetURL: targetPrefs)
    let symStore = PreferencesStore(fileURL: symlinkPrefs)
    _ = symStore.load()
    try E2ERunner.expect(symStore.isWriteBlockedDueToLoadError, "Symlink prefs must set write block")
    try E2ERunner.expect(!symStore.save(SweepPreferences()), "Symlink prefs must refuse save")
    try E2ERunner.expectEqual(try String(contentsOf: targetPrefs, encoding: .utf8), "{\"protectedPaths\":[\"/tmp/keep\"]}")
}

runner.register(
    id: "f3-empty-whitespace-nul-duplicates-safe",
    tier: 2,
    feature: "F-3",
    name: "SafetyGuard safely ignores empty, whitespace, NUL, and duplicate protectedPaths without blocking unrelated paths"
) {
    let sandbox = try E2ESandbox(prefix: "e2e-f3-san")
    defer { sandbox.cleanup() }

    let prot = try sandbox.createDirectory("Work/Keep")
    let unrelated = try sandbox.createFile("Work/Free/normal.txt", utf8: "free")

    let sg = SafetyGuard(
        homeDirectory: sandbox.rootURL,
        selfBundlePath: nil,
        protectedPaths: ["", "   ", "\n\t", "/tmp/bad\0entry", prot.path, prot.path + "/"]
    )

    try E2ERunner.expect(!sg.validateForRemoval(prot).isAllowed, "Valid protected path must still be blocked")
    try E2ERunner.expectEqual(sg.validateForRemoval(unrelated), .allowed)
    try E2ERunner.expect(!sg.isUserProtected(bundleID: nil, url: unrelated), "Empty entry must never protect CWD or unrelated paths")
}

await runner.runAndExit()

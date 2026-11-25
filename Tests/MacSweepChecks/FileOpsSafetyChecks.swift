import Darwin
import Foundation
@testable import MacSweepCore

private final class AsyncResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func store(_ res: Result<T, Error>) {
        lock.withLock { result = res }
    }

    func take() -> Result<T, Error>? {
        lock.withLock { result }
    }
}

private func runAsync<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = AsyncResultBox<T>()
    Task {
        do {
            box.store(.success(try await work()))
        } catch {
            box.store(.failure(error))
        }
        sem.signal()
    }
    sem.wait()
    return try box.take()!.get()
}

func runFileOpsSafetyChecks(_ runner: CheckRunner) {
    print("== FileOps Safety & Engine Checks ==")

    runner.run("SafetyGuard.validateForMoveOrRename enforces source, destination, self-move, symlink escape, and case-only rename rules") {
        let sandbox = try runner.makeTempSandbox(prefix: "fops-sg-move")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let docs = sandbox.appendingPathComponent("Documents")
        let ssh = sandbox.appendingPathComponent(".ssh")
        let work = sandbox.appendingPathComponent("Work")
        let archive = sandbox.appendingPathComponent("Archive")
        let protectedDir = sandbox.appendingPathComponent("Vault")
        let photosLib = sandbox.appendingPathComponent("Pictures/Main.photoslibrary")
        let chromeCache = sandbox.appendingPathComponent("Library/Caches/Google/Chrome")
        let selfApp = sandbox.appendingPathComponent("Applications/MacSweep.app")

        for dir in [docs, ssh, work, archive, protectedDir, photosLib, chromeCache, selfApp] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let workFile = work.appendingPathComponent("report.txt")
        let existingArchiveFile = archive.appendingPathComponent("existing.txt")
        try Data("report".utf8).write(to: workFile)
        try Data("existing".utf8).write(to: existingArchiveFile)

        let normalTarget = work.appendingPathComponent("target.txt")
        try Data("target".utf8).write(to: normalTarget)
        let normalSymlink = work.appendingPathComponent("normal-link")
        try fm.createSymbolicLink(at: normalSymlink, withDestinationURL: normalTarget)

        let docsSymlink = work.appendingPathComponent("docs-link")
        try fm.createSymbolicLink(at: docsSymlink, withDestinationURL: docs)

        let sshEscapeDirLink = work.appendingPathComponent("ssh-escape")
        try fm.createSymbolicLink(at: sshEscapeDirLink, withDestinationURL: ssh)

        let dirA = work.appendingPathComponent("DirA")
        try fm.createDirectory(at: dirA.appendingPathComponent("Sub"), withIntermediateDirectories: true)

        let sg = SafetyGuard(
            homeDirectory: sandbox,
            selfBundlePath: selfApp.path,
            protectedPaths: [protectedDir.path],
            protectedBundleIDs: ["com.acme.protected"]
        )

        // Blocked sources
        try runner.expect(!sg.validateForMoveOrRename(
            source: URL(fileURLWithPath: "/System/Applications/Notes.app"),
            destination: archive.appendingPathComponent("Notes.app")
        ).isAllowed)
        try runner.expect(!sg.validateForMoveOrRename(
            source: docs,
            destination: archive.appendingPathComponent("Documents")
        ).isAllowed)
        try runner.expect(!sg.validateForMoveOrRename(
            source: selfApp,
            destination: archive.appendingPathComponent("MacSweep.app")
        ).isAllowed)
        try runner.expect(!sg.validateForMoveOrRename(
            source: protectedDir,
            destination: archive.appendingPathComponent("Vault")
        ).isAllowed)
        try runner.expect(!sg.validateForMoveOrRename(
            source: photosLib,
            destination: archive.appendingPathComponent("Main.photoslibrary")
        ).isAllowed)
        try runner.expect(!sg.validateForMoveOrRename(
            source: sandbox.appendingPathComponent("Library/Caches/Google"),
            destination: archive.appendingPathComponent("Google")
        ).isAllowed)
        try runner.expect(!sg.validateForMoveOrRename(
            source: docsSymlink,
            destination: archive.appendingPathComponent("docs-link")
        ).isAllowed, "Symlink pointing to ~/Documents must be blocked")

        // Blocked destinations (protected roots, credentials, symlink escape with multi-level non-existent path)
        try runner.expect(!sg.validateForMoveOrRename(
            source: workFile,
            destination: URL(fileURLWithPath: "/System/report.txt")
        ).isAllowed)
        try runner.expect(!sg.validateForMoveOrRename(
            source: workFile,
            destination: URL(fileURLWithPath: "/Library/Apple/report.txt")
        ).isAllowed)
        try runner.expect(!sg.validateForMoveOrRename(
            source: workFile,
            destination: ssh.appendingPathComponent("report.txt")
        ).isAllowed)
        try runner.expect(!sg.validateForMoveOrRename(
            source: workFile,
            destination: protectedDir.appendingPathComponent("sub/report.txt")
        ).isAllowed)
        try runner.expect(!sg.validateForMoveOrRename(
            source: workFile,
            destination: sshEscapeDirLink.appendingPathComponent("deep/nested/report.txt")
        ).isAllowed, "Multi-level destination inside symlink escaping to ~/.ssh must be blocked")
        try runner.expect(!sg.validateForMoveOrRename(
            source: workFile,
            destination: docs
        ).isAllowed, "Cannot overwrite criticalExactPaths ~/Documents")
        try runner.expect(!sg.validateForMoveOrRename(
            source: workFile,
            destination: sandbox.appendingPathComponent("Library/Caches/com.apple.Safari")
        ).isAllowed)
        try runner.expect(!sg.validateForMoveOrRename(
            source: workFile,
            destination: sandbox.appendingPathComponent("Library/Caches/com.acme.protected")
        ).isAllowed)

        // Self-move / directory into itself / existing destination collision / TOCTOU
        try runner.expect(!sg.validateForMoveOrRename(source: workFile, destination: workFile).isAllowed)
        try runner.expect(!sg.validateForMoveOrRename(
            source: dirA,
            destination: dirA.appendingPathComponent("Sub/DirA")
        ).isAllowed, "Cannot move directory into itself")
        try runner.expect(!sg.validateForMoveOrRename(
            source: workFile,
            destination: existingArchiveFile
        ).isAllowed, "Must block overwriting existing destination")
        try runner.expect(!sg.validateForMoveOrRename(
            source: workFile,
            destination: archive.appendingPathComponent("report.txt"),
            expectedSourceCanonicalParent: "/nonexistent/wrong/parent"
        ).isAllowed, "TOCTOU parent mismatch must be blocked")

        // Allowed cases
        let canonicalWork = PrivilegedExecutor.canonicalParentPath(forTargetURL: workFile)
        try runner.expect(sg.validateForMoveOrRename(
            source: workFile,
            destination: archive.appendingPathComponent("report.txt"),
            expectedSourceCanonicalParent: canonicalWork
        ).isAllowed, "Valid move across sandbox folders should be allowed")
        try runner.expect(sg.validateForMoveOrRename(
            source: workFile,
            destination: docs.appendingPathComponent("report.txt")
        ).isAllowed, "Moving a file inside ~/Documents should be allowed")
        try runner.expect(sg.validateForMoveOrRename(
            source: normalSymlink,
            destination: archive.appendingPathComponent("normal-link")
        ).isAllowed, "Moving normal symlink should be allowed")
        try runner.expect(sg.validateForMoveOrRename(
            source: chromeCache,
            destination: sandbox.appendingPathComponent("Library/Caches/Google/Chrome.bak")
        ).isAllowed, "Renaming vendor app cache subfolder should be allowed")
        try runner.expect(sg.validateForMoveOrRename(
            source: workFile,
            destination: work.appendingPathComponent("REPORT.txt"),
            expectedSourceCanonicalParent: canonicalWork
        ).isAllowed, "Case-only rename on APFS should be allowed")
    }

    runner.run("SafetyGuard.validateDirectoryCreation enforces protected roots, symlinks, invalid names, and collisions") {
        let sandbox = try runner.makeTempSandbox(prefix: "fops-sg-mkdir")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let work = sandbox.appendingPathComponent("Work")
        let docs = sandbox.appendingPathComponent("Documents")
        let ssh = sandbox.appendingPathComponent(".ssh")
        let protectedDir = sandbox.appendingPathComponent("Protected")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try fm.createDirectory(at: ssh, withIntermediateDirectories: true)
        try fm.createDirectory(at: protectedDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: work.appendingPathComponent("Existing"), withIntermediateDirectories: true)

        let escapeLink = work.appendingPathComponent("escape-ssh")
        try fm.createSymbolicLink(at: escapeLink, withDestinationURL: ssh)

        let sg = SafetyGuard(homeDirectory: sandbox, protectedPaths: [protectedDir.path])

        try runner.expect(!sg.validateDirectoryCreation(at: URL(fileURLWithPath: "/System/NewFolder")).isAllowed)
        try runner.expect(!sg.validateDirectoryCreation(at: URL(fileURLWithPath: "/Library/Apple/NewFolder")).isAllowed)
        try runner.expect(!sg.validateDirectoryCreation(at: ssh.appendingPathComponent("NewFolder")).isAllowed)
        try runner.expect(!sg.validateDirectoryCreation(at: protectedDir.appendingPathComponent("NewFolder")).isAllowed)
        try runner.expect(!sg.validateDirectoryCreation(at: escapeLink.appendingPathComponent("a/b")).isAllowed)
        try runner.expect(!sg.validateDirectoryCreation(at: sandbox.appendingPathComponent("Library/Caches/Google")).isAllowed)
        try runner.expect(!sg.validateDirectoryCreation(at: sandbox.appendingPathComponent("Library/Caches/Apple/Sub")).isAllowed)
        try runner.expect(!sg.validateDirectoryCreation(at: work.appendingPathComponent("Existing")).isAllowed)
        try runner.expect(!sg.validateDirectoryCreation(at: work.appendingPathComponent("existing")).isAllowed)
        try runner.expect(!sg.validateDirectoryCreation(at: work.appendingPathComponent("..")).isAllowed)
        try runner.expect(!sg.validateDirectoryCreation(at: work.appendingPathComponent(".")).isAllowed)
        try runner.expect(!sg.validateDirectoryCreation(at: URL(string: "file://\(work.path)/bad%00dir")!).isAllowed)

        try runner.expect(sg.validateDirectoryCreation(at: work.appendingPathComponent("NewSubdir")).isAllowed)
        try runner.expect(sg.validateDirectoryCreation(at: docs.appendingPathComponent("Projects")).isAllowed)
    }

    runner.run("SafetyGuard.validateCacheSubpath enforces ~/Library/Caches confinement and shared vendor discipline") {
        let sandbox = try runner.makeTempSandbox(prefix: "fops-sg-cache")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let caches = sandbox.appendingPathComponent("Library/Caches")
        let docs = sandbox.appendingPathComponent("Documents")
        let msOneNote = caches.appendingPathComponent("Microsoft/OneNote")
        let acmeCache = caches.appendingPathComponent("com.example.tool")
        let protectedCache = caches.appendingPathComponent("com.acme.keep")
        let escapingCache = caches.appendingPathComponent("SneakyEscape")

        for dir in [caches, docs, msOneNote, acmeCache, protectedCache] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(at: escapingCache, withDestinationURL: docs)

        let sg = SafetyGuard(
            homeDirectory: sandbox,
            protectedPaths: [protectedCache.path],
            protectedBundleIDs: ["com.acme.keep"]
        )

        try runner.expect(!sg.validateCacheSubpath(caches).isAllowed, "Caches root must be blocked")
        try runner.expect(!sg.validateCacheSubpath(caches.appendingPathComponent("Microsoft")).isAllowed, "Bare vendor root must be blocked")
        try runner.expect(!sg.validateCacheSubpath(caches.appendingPathComponent("Google")).isAllowed, "Bare vendor root must be blocked")
        try runner.expect(!sg.validateCacheSubpath(caches.appendingPathComponent("Apple")).isAllowed, "Apple cache dir must be blocked")
        try runner.expect(!sg.validateCacheSubpath(caches.appendingPathComponent("Apple/Sub")).isAllowed, "Apple cache descendant must be blocked")
        try runner.expect(!sg.validateCacheSubpath(caches.appendingPathComponent("com.apple.Safari")).isAllowed, "com.apple.* cache must be blocked")
        try runner.expect(!sg.validateCacheSubpath(caches.appendingPathComponent("local.macsweep")).isAllowed, "Self cache must be blocked")
        try runner.expect(!sg.validateCacheSubpath(protectedCache).isAllowed, "User protected cache must be blocked")
        try runner.expect(!sg.validateCacheSubpath(escapingCache).isAllowed, "Symlink escaping ~/Library/Caches must be blocked")
        try runner.expect(!sg.validateCacheSubpath(docs.appendingPathComponent("SomeFile")).isAllowed, "Path outside Caches must be blocked")

        try runner.expect(sg.validateCacheSubpath(msOneNote).isAllowed, "Vendor/App cache subpath should be allowed")
        try runner.expect(sg.validateCacheSubpath(acmeCache).isAllowed, "App cache leaf should be allowed")
    }

    runner.run("FileOperationsEngine.moveItem handles files, dirs, symlinks, overwrite rejection, TOCTOU, uchg, and cross-volume staging") {
        let sandbox = try runner.makeTempSandbox(prefix: "fops-eng-move")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let srcDir = sandbox.appendingPathComponent("Source")
        let altSrcDir = sandbox.appendingPathComponent("AltSource")
        let dstDir = sandbox.appendingPathComponent("Dest")
        let sshDir = sandbox.appendingPathComponent(".ssh")
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: altSrcDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sshDir, withIntermediateDirectories: true)

        let sg = SafetyGuard(homeDirectory: sandbox)
        let engine = FileOperationsEngine(safetyGuard: sg)

        // 1. Move regular file
        let fileA = srcDir.appendingPathComponent("alpha.txt")
        try Data("alpha-content".utf8).write(to: fileA)
        let parentA = PrivilegedExecutor.canonicalParentPath(forTargetURL: fileA)
        let movedA = try runAsync {
            try await engine.moveItem(from: fileA, to: dstDir, expectedSourceCanonicalParent: parentA)
        }
        try runner.expectEqual(movedA.standardizedFileURL.path, dstDir.appendingPathComponent("alpha.txt").standardizedFileURL.path)
        try runner.expect(!fm.fileExists(atPath: fileA.path))
        try runner.expectEqual(try Data(contentsOf: movedA), Data("alpha-content".utf8))

        // 2. Move directory
        let folder = srcDir.appendingPathComponent("BundleDir")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: folder.appendingPathComponent("child.txt"))
        let movedFolder = try runAsync {
            try await engine.moveItem(from: folder, to: dstDir, expectedSourceCanonicalParent: parentA)
        }
        try runner.expect(!fm.fileExists(atPath: folder.path))
        try runner.expectEqual(try Data(contentsOf: movedFolder.appendingPathComponent("child.txt")), Data("nested".utf8))

        // 3. Move normal symlink without following target
        let linkTarget = sandbox.appendingPathComponent("keep-target.txt")
        try Data("keep".utf8).write(to: linkTarget)
        let symlink = srcDir.appendingPathComponent("safe-link")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: linkTarget)
        let movedLink = try runAsync {
            try await engine.moveItem(from: symlink, to: dstDir, expectedSourceCanonicalParent: parentA)
        }
        try runner.expect(sg.isSymbolicLink(movedLink), "Moved item must remain a symlink")
        try runner.expectEqual(try Data(contentsOf: linkTarget), Data("keep".utf8))

        // 4. Reject overwriting existing destination
        let dupFile = srcDir.appendingPathComponent("alpha.txt")
        try Data("new-alpha".utf8).write(to: dupFile)
        var overwriteRejected = false
        do {
            _ = try runAsync {
                try await engine.moveItem(from: dupFile, to: dstDir, expectedSourceCanonicalParent: parentA)
            }
        } catch FileOperationError.destinationAlreadyExists {
            overwriteRejected = true
        }
        try runner.expect(overwriteRejected, "Overwriting existing destination must throw destinationAlreadyExists")
        try runner.expectEqual(try Data(contentsOf: movedA), Data("alpha-content".utf8))

        // 5. Reject protected destination (symlink escaping to .ssh)
        let escapeParent = sandbox.appendingPathComponent("EscapeParent")
        try fm.createSymbolicLink(at: escapeParent, withDestinationURL: sshDir)
        var blockedDest = false
        do {
            _ = try runAsync {
                try await engine.moveItem(from: dupFile, to: escapeParent, expectedSourceCanonicalParent: parentA)
            }
        } catch FileOperationError.blockedBySafetyGuard {
            blockedDest = true
        }
        try runner.expect(blockedDest, "Moving into symlinked .ssh must be blocked")

        // 6. Reject uchg (UF_IMMUTABLE) file
        let lockedFile = srcDir.appendingPathComponent("locked.txt")
        try Data("locked".utf8).write(to: lockedFile)
        if chflags(lockedFile.path, UInt32(UF_IMMUTABLE)) == 0 {
            defer { _ = chflags(lockedFile.path, 0) }
            var immutableRejected = false
            do {
                _ = try runAsync {
                    try await engine.moveItem(from: lockedFile, to: dstDir, expectedSourceCanonicalParent: parentA)
                }
            } catch FileOperationError.userImmutable {
                immutableRejected = true
            }
            try runner.expect(immutableRejected, "Moving uchg file must throw userImmutable")
        }

        // 7. Reject TOCTOU parent directory swap
        let swapParent = sandbox.appendingPathComponent("SwapParent")
        try fm.createDirectory(at: swapParent, withIntermediateDirectories: true)
        let swapFile = swapParent.appendingPathComponent("item.txt")
        try Data("orig".utf8).write(to: swapFile)
        let capturedParent = PrivilegedExecutor.canonicalParentPath(forTargetURL: swapFile)
        try fm.removeItem(at: swapParent)
        try fm.createSymbolicLink(at: swapParent, withDestinationURL: altSrcDir)
        try Data("swapped".utf8).write(to: altSrcDir.appendingPathComponent("item.txt"))

        var toctouRejected = false
        do {
            _ = try runAsync {
                try await engine.moveItem(from: swapFile, to: dstDir, expectedSourceCanonicalParent: capturedParent)
            }
        } catch FileOperationError.toctouMismatch {
            toctouRejected = true
        }
        try runner.expect(toctouRejected, "Parent swap must trigger toctouMismatch")
        try runner.expect(fm.fileExists(atPath: altSrcDir.appendingPathComponent("item.txt").path))

        // 8. Exercise EXDEV cross-volume confined staging helper directly
        let crossSrcDir = sandbox.appendingPathComponent("CrossSrc")
        let crossDstDir = sandbox.appendingPathComponent("CrossDst")
        try fm.createDirectory(at: crossSrcDir.appendingPathComponent("Tree/Inner"), withIntermediateDirectories: true)
        try fm.createDirectory(at: crossDstDir, withIntermediateDirectories: true)
        try Data("cross-data".utf8).write(to: crossSrcDir.appendingPathComponent("Tree/Inner/file.bin"))
        try fm.createSymbolicLink(
            at: crossSrcDir.appendingPathComponent("Tree/link"),
            withDestinationURL: linkTarget
        )

        let sFD = open(crossSrcDir.path, O_SEARCH | O_DIRECTORY)
        let dFD = open(crossDstDir.path, O_SEARCH | O_DIRECTORY)
        try runner.expect(sFD >= 0 && dFD >= 0)
        defer {
            if sFD >= 0 { close(sFD) }
            if dFD >= 0 { close(dFD) }
        }
        try FileOperationsEngine.moveAcrossVolumesConfined(
            srcParentFD: sFD,
            srcName: "Tree",
            dstParentFD: dFD,
            dstName: "Tree",
            srcDisplayPath: crossSrcDir.appendingPathComponent("Tree").path,
            dstDisplayPath: crossDstDir.appendingPathComponent("Tree").path
        )
        try runner.expect(!fm.fileExists(atPath: crossSrcDir.appendingPathComponent("Tree").path))
        try runner.expectEqual(
            try Data(contentsOf: crossDstDir.appendingPathComponent("Tree/Inner/file.bin")),
            Data("cross-data".utf8)
        )
        try runner.expect(sg.isSymbolicLink(crossDstDir.appendingPathComponent("Tree/link")))
    }

    runner.run("FileOperationsEngine.renameItem and createDirectory validate names, collisions, case-only renames, and TOCTOU") {
        let sandbox = try runner.makeTempSandbox(prefix: "fops-eng-rename")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let work = sandbox.appendingPathComponent("Work")
        let protectedDir = sandbox.appendingPathComponent("Protected")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.createDirectory(at: protectedDir, withIntermediateDirectories: true)

        let sg = SafetyGuard(homeDirectory: sandbox, protectedPaths: [protectedDir.path])
        let engine = FileOperationsEngine(safetyGuard: sg)

        let file = work.appendingPathComponent("notes.txt")
        let existing = work.appendingPathComponent("taken.txt")
        try Data("notes".utf8).write(to: file)
        try Data("taken".utf8).write(to: existing)

        let parentCanonical = PrivilegedExecutor.canonicalParentPath(forTargetURL: file)

        // Rename normal
        let renamed = try runAsync {
            try await engine.renameItem(at: file, toNewName: "readme.txt", expectedSourceCanonicalParent: parentCanonical)
        }
        try runner.expectEqual(renamed.lastPathComponent, "readme.txt")
        try runner.expect(!fm.fileExists(atPath: file.path))
        try runner.expectEqual(try Data(contentsOf: renamed), Data("notes".utf8))

        // Case-only rename on APFS
        let caseRenamed = try runAsync {
            try await engine.renameItem(at: renamed, toNewName: "README.txt", expectedSourceCanonicalParent: parentCanonical)
        }
        try runner.expectEqual(caseRenamed.lastPathComponent, "README.txt")
        try runner.expectEqual(try Data(contentsOf: caseRenamed), Data("notes".utf8))

        // Invalid names
        let longName = String(repeating: "a", count: 300)
        for bad in ["", ".", "..", "sub/name", "bad\0name", longName] {
            var threwInvalid = false
            do {
                _ = try runAsync {
                    try await engine.renameItem(at: caseRenamed, toNewName: bad, expectedSourceCanonicalParent: parentCanonical)
                }
            } catch FileOperationError.invalidName {
                threwInvalid = true
            }
            try runner.expect(threwInvalid, "Invalid name '\(bad.prefix(20))' must throw invalidName")
        }

        // Collision
        var threwCollision = false
        do {
            _ = try runAsync {
                try await engine.renameItem(at: caseRenamed, toNewName: "taken.txt", expectedSourceCanonicalParent: parentCanonical)
            }
        } catch FileOperationError.destinationAlreadyExists {
            threwCollision = true
        }
        try runner.expect(threwCollision, "Renaming onto existing file must throw destinationAlreadyExists")

        // TOCTOU mismatch
        var threwTOCTOU = false
        do {
            _ = try runAsync {
                try await engine.renameItem(at: caseRenamed, toNewName: "other.txt", expectedSourceCanonicalParent: "/wrong/parent")
            }
        } catch FileOperationError.toctouMismatch {
            threwTOCTOU = true
        }
        try runner.expect(threwTOCTOU)

        // createDirectory valid + rejections
        let created = try runAsync {
            try await engine.createDirectory(named: "Folder One", in: work)
        }
        var isDirObj: ObjCBool = false
        try runner.expect(fm.fileExists(atPath: created.path, isDirectory: &isDirObj) && isDirObj.boolValue)

        var dupDirRejected = false
        do {
            _ = try runAsync {
                try await engine.createDirectory(named: "Folder One", in: work)
            }
        } catch FileOperationError.destinationAlreadyExists {
            dupDirRejected = true
        }
        try runner.expect(dupDirRejected)

        var protDirRejected = false
        do {
            _ = try runAsync {
                try await engine.createDirectory(named: "Sub", in: protectedDir)
            }
        } catch FileOperationError.blockedBySafetyGuard {
            protDirRejected = true
        }
        try runner.expect(protDirRejected)
    }

    runner.run("FileOperationsEngine.inspectMetadata reads file, dir, symlinks, hidden, uchg, and FIFO without blocking") {
        let sandbox = try runner.makeTempSandbox(prefix: "fops-eng-meta")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let engine = FileOperationsEngine(safetyGuard: SafetyGuard(homeDirectory: sandbox))

        let reg = sandbox.appendingPathComponent("sample.json")
        try Data("{\"ok\":true}".utf8).write(to: reg)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: reg.path)

        let regMeta = try engine.inspectMetadata(at: reg)
        try runner.expectEqual(regMeta.kind, .regularFile)
        try runner.expectEqual(regMeta.sizeBytes, 11)
        try runner.expectEqual(regMeta.posixPermissions, 0o640)
        try runner.expectEqual(regMeta.posixPermissionsOctal, "0640")
        try runner.expect(!regMeta.isDirectory && !regMeta.isSymbolicLink && !regMeta.isUserImmutable && !regMeta.isHidden)
        try runner.expectEqual(regMeta.utiIdentifier, "public.json")

        let subDir = sandbox.appendingPathComponent("Sub")
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)
        let dirMeta = try engine.inspectMetadata(at: subDir)
        try runner.expectEqual(dirMeta.kind, .directory)
        try runner.expect(dirMeta.isDirectory && !dirMeta.isSymbolicLink)

        let validLink = sandbox.appendingPathComponent("valid-link")
        try fm.createSymbolicLink(at: validLink, withDestinationURL: reg)
        let validLinkMeta = try engine.inspectMetadata(at: validLink)
        try runner.expectEqual(validLinkMeta.kind, .symbolicLink)
        try runner.expect(validLinkMeta.isSymbolicLink && validLinkMeta.isSymlink && !validLinkMeta.isSymlinkBroken)
        try runner.expectEqual(validLinkMeta.symlinkTarget, reg.path)
        try runner.expect(validLinkMeta.resolvedTargetPath != nil)

        let brokenLink = sandbox.appendingPathComponent("broken-link")
        try fm.createSymbolicLink(at: brokenLink, withDestinationURL: sandbox.appendingPathComponent("missing.txt"))
        let brokenMeta = try engine.inspectMetadata(at: brokenLink)
        try runner.expect(brokenMeta.isSymbolicLink && brokenMeta.isSymlinkBroken)
        try runner.expect(brokenMeta.resolvedTargetPath == nil)

        let dotfile = sandbox.appendingPathComponent(".env")
        try Data("A=1".utf8).write(to: dotfile)
        let dotMeta = try engine.inspectMetadata(at: dotfile)
        try runner.expect(dotMeta.isHidden)

        if chflags(reg.path, UInt32(UF_IMMUTABLE)) == 0 {
            defer { _ = chflags(reg.path, 0) }
            let lockedMeta = try engine.inspectMetadata(at: reg)
            try runner.expect(lockedMeta.isUserImmutable)
        }

        let fifoURL = sandbox.appendingPathComponent("pipe.fifo")
        if mkfifo(fifoURL.path, 0o600) == 0 {
            let fifoMeta = try engine.inspectMetadata(at: fifoURL)
            try runner.expectEqual(fifoMeta.kind, .special)
            try runner.expect(fifoMeta.allocatedSizeBytes == nil)
        }
    }

    runner.run("Remediation regressions: /private selfDataPaths, non-existent protectedPaths, '..' traversal, .app interior, Apple Group Containers") {
        let rawSandbox = try runner.makeTempSandbox(prefix: "fops-r2-sg")
        defer { try? FileManager.default.removeItem(at: rawSandbox) }

        let fm = FileManager.default
        // Strip /private if present so homeDirectory mimics /var/folders/... standardized URL
        let varPath = rawSandbox.path.hasPrefix("/private/var/")
            ? String(rawSandbox.path.dropFirst("/private".count))
            : rawSandbox.path
        let varHome = URL(fileURLWithPath: varPath)

        // 1. P1.7: Existing Library/Application Support/MacSweep under /var must stay protected via /private/var/... symlink escape
        let selfAppSupport = varHome.appendingPathComponent("Library/Application Support/MacSweep")
        let work = varHome.appendingPathComponent("Work")
        let archive = varHome.appendingPathComponent("Archive")
        let caches = varHome.appendingPathComponent("Library/Caches")
        let msCache = caches.appendingPathComponent("Microsoft/OneNote")
        let protectedApp = varHome.appendingPathComponent("Applications/MyProtected.app/Contents/Resources")
        for d in [selfAppSupport, work, archive, msCache, protectedApp] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.acme.protected"],
            format: .xml,
            options: 0
        ).write(to: varHome.appendingPathComponent("Applications/MyProtected.app/Contents/Info.plist"))

        let selfDataLink = work.appendingPathComponent("l_selfdata")
        try fm.createSymbolicLink(at: selfDataLink, withDestinationURL: selfAppSupport)

        let linkToWork = varHome.appendingPathComponent("LinkToWork")
        try fm.createSymbolicLink(at: linkToWork, withDestinationURL: work)

        let appEscapeLink = work.appendingPathComponent("EscapeToApp")
        try fm.createSymbolicLink(at: appEscapeLink, withDestinationURL: varHome.appendingPathComponent("Applications/MyProtected.app"))

        let payload = work.appendingPathComponent("payload.txt")
        try Data("payload".utf8).write(to: payload)

        let futureTmpUUID = "macsweep_future_\(UUID().uuidString)"
        let sg = SafetyGuard(
            homeDirectory: varHome,
            selfBundlePath: varHome.appendingPathComponent("Applications/MacSweep.app").path,
            protectedPaths: [
                "",
                "   ",
                "/tmp/\(futureTmpUUID)",
                linkToWork.appendingPathComponent("FutureVault").path,
            ],
            protectedBundleIDs: ["com.acme.protected"]
        )

        // P1.7 checks
        try runner.expect(!sg.validateForRemoval(selfDataLink.appendingPathComponent("a/b/c/k")).isAllowed,
                          "P1.7: selfData via symlink must be blocked even when existing under /var")
        try runner.expect(!sg.validateDirectoryCreation(at: selfDataLink.appendingPathComponent("a/b/c/k")).isAllowed,
                          "P1.7: mkdir inside selfData via symlink must be blocked")
        try runner.expect(!sg.validateForMoveOrRename(source: payload, destination: selfDataLink.appendingPathComponent("a/b/c/k")).isAllowed,
                          "P1.7: move into selfData via symlink must be blocked")

        // P1.12 & P1.13 checks (non-existent protectedPaths under symlink & /tmp vs /private/tmp)
        try runner.expect(!sg.validateDirectoryCreation(at: URL(fileURLWithPath: "/private/tmp/\(futureTmpUUID)/sub/dir")).isAllowed,
                          "P1.13: non-existent /tmp protectedPath must block /private/tmp equivalent")
        try runner.expect(!sg.validateForMoveOrRename(source: payload, destination: URL(fileURLWithPath: "/private/tmp/\(futureTmpUUID)/file.txt")).isAllowed,
                          "P1.13: move into /private/tmp equivalent of /tmp protectedPath must be blocked")
        try runner.expect(!sg.validateForMoveOrRename(source: payload, destination: work.appendingPathComponent("FutureVault/sub/file.txt")).isAllowed,
                          "P1.12: symlinked non-existent protectedPath must block real target path")
        try runner.expect(!sg.validateDirectoryCreation(at: work.appendingPathComponent("FutureVault/sub")).isAllowed,
                          "P1.12: mkdir inside symlinked non-existent protectedPath must be blocked")
        // Verify whitespace protectedPath entry did not pollute cwd protection
        try runner.expect(sg.validateDirectoryCreation(at: archive.appendingPathComponent("AllowedNewDir")).isAllowed,
                          "Empty/whitespace protectedPaths must be ignored without blocking normal dirs")

        // P8.2: .app interior blocked for protectedBundleIDs (direct & via symlink)
        try runner.expect(!sg.validateForMoveOrRename(source: payload, destination: protectedApp.appendingPathComponent("payload.txt")).isAllowed,
                          "P8.2: move into protected .app/Contents/Resources must be blocked")
        try runner.expect(!sg.validateDirectoryCreation(at: protectedApp.appendingPathComponent("NewSub")).isAllowed,
                          "P8.2: mkdir inside protected .app/Contents/Resources must be blocked")
        try runner.expect(!sg.validateForRemoval(protectedApp).isAllowed,
                          "P8.2: removing protected .app interior must be blocked")
        try runner.expect(!sg.validateForMoveOrRename(source: payload, destination: appEscapeLink.appendingPathComponent("Contents/Resources/payload.txt")).isAllowed,
                          "P8.2: move into protected .app interior via symlink must be blocked")

        // P5.18: Apple Group Containers blocked in validateCacheSubpath
        try runner.expect(!sg.validateCacheSubpath(caches.appendingPathComponent("group.com.apple.notes")).isAllowed,
                          "P5.18: Apple group container in Caches must be blocked")
        try runner.expect(!sg.validateCacheSubpath(caches.appendingPathComponent("group.com.apple.notes/Sub")).isAllowed,
                          "P5.18: descendant of Apple group container in Caches must be blocked")

        // Finding 3: '..' traversal rejected before .standardizedFileURL in SafetyGuard & FileOperationsEngine
        let dotDotSource = work.appendingPathComponent("Sub/../payload.txt")
        let dotDotDest = archive.appendingPathComponent("Sub/../payload.txt")
        let dotDotDir = archive.appendingPathComponent("Sub/..")
        try runner.expect(!sg.validateForMoveOrRename(source: dotDotSource, destination: archive.appendingPathComponent("payload.txt")).isAllowed,
                          "'..' in source pathComponents must be rejected")
        try runner.expect(!sg.validateForMoveOrRename(source: payload, destination: dotDotDest).isAllowed,
                          "'..' in destination pathComponents must be rejected")
        try runner.expect(!sg.validateDirectoryCreation(at: work.appendingPathComponent("Sub/../NewDir")).isAllowed,
                          "'..' in mkdir pathComponents must be rejected")
        try runner.expect(!sg.validateCacheSubpath(caches.appendingPathComponent("Microsoft/OneNote/sub/..")).isAllowed,
                          "'..' in cache subpath must be rejected")

        let engine = FileOperationsEngine(safetyGuard: sg)
        let workParent = PrivilegedExecutor.canonicalParentPath(forTargetURL: payload)

        var threwDotDotMoveSrc = false
        do {
            _ = try runAsync {
                try await engine.moveItem(from: dotDotSource, to: archive, expectedSourceCanonicalParent: workParent)
            }
        } catch FileOperationError.invalidName {
            threwDotDotMoveSrc = true
        }
        try runner.expect(threwDotDotMoveSrc, "moveItem must reject '..' in source before standardizing")
        try runner.expect(fm.fileExists(atPath: payload.path), "Original payload must remain untouched")

        var threwDotDotMoveDst = false
        do {
            _ = try runAsync {
                try await engine.moveItem(from: payload, to: dotDotDir, expectedSourceCanonicalParent: workParent)
            }
        } catch FileOperationError.invalidName {
            threwDotDotMoveDst = true
        }
        try runner.expect(threwDotDotMoveDst, "moveItem must reject '..' in destinationDirectory before standardizing")

        var threwDotDotRename = false
        do {
            _ = try runAsync {
                try await engine.renameItem(at: dotDotSource, toNewName: "renamed.txt", expectedSourceCanonicalParent: workParent)
            }
        } catch FileOperationError.invalidName {
            threwDotDotRename = true
        }
        try runner.expect(threwDotDotRename, "renameItem must reject '..' in source before standardizing")

        var threwDotDotMkdir = false
        do {
            _ = try runAsync {
                try await engine.createDirectory(named: "NewDir", in: dotDotDir)
            }
        } catch FileOperationError.invalidName {
            threwDotDotMkdir = true
        }
        try runner.expect(threwDotDotMkdir, "createDirectory must reject '..' in parentDirectory before standardizing")

        var threwDotDotMeta = false
        do {
            _ = try engine.inspectMetadata(at: dotDotSource)
        } catch FileOperationError.invalidName {
            threwDotDotMeta = true
        }
        try runner.expect(threwDotDotMeta, "inspectMetadata must reject '..' before standardizing")
    }

    runner.run("Remediation regressions: EXDEV 0o555 tree source removal, S_IFREG mode fidelity, and staging cleanup on error") {
        let sandbox = try runner.makeTempSandbox(prefix: "fops-r2-exdev")
        let fm = FileManager.default
        let roTree = sandbox.appendingPathComponent("Src/ROTree")
        let roSub = roTree.appendingPathComponent("ROSub")
        let roGroupWrite = roTree.appendingPathComponent("GroupWrite")
        let dstROTree = sandbox.appendingPathComponent("Dst/ROTree")
        let dstROSub = dstROTree.appendingPathComponent("ROSub")
        let dstROGroupWrite = dstROTree.appendingPathComponent("GroupWrite")
        let failSrcDir = sandbox.appendingPathComponent("FailSrc")
        let failTree = failSrcDir.appendingPathComponent("FailTree")
        let failROSub = failTree.appendingPathComponent("ROSub")
        let failDstDir = sandbox.appendingPathComponent("FailDst")

        defer {
            for p in [roTree, roSub, roGroupWrite, dstROTree, dstROSub, dstROGroupWrite, failTree, failROSub] {
                _ = chmod(p.path, 0o755)
            }
            try? fm.removeItem(at: sandbox)
        }

        let srcParent = sandbox.appendingPathComponent("Src")
        let dstParent = sandbox.appendingPathComponent("Dst")
        try fm.createDirectory(at: roSub, withIntermediateDirectories: true)
        try fm.createDirectory(at: roGroupWrite, withIntermediateDirectories: true)
        try fm.createDirectory(at: dstParent, withIntermediateDirectories: true)

        let srcFile = roSub.appendingPathComponent("secret.bin")
        try Data("ro-payload".utf8).write(to: srcFile)
        try runner.expectEqual(chmod(srcFile.path, 0o640), 0)
        try runner.expectEqual(chmod(roGroupWrite.path, 0o775), 0)
        try runner.expectEqual(chmod(roSub.path, 0o555), 0)
        try runner.expectEqual(chmod(roTree.path, 0o555), 0)

        let sFD = open(srcParent.path, O_SEARCH | O_DIRECTORY)
        let dFD = open(dstParent.path, O_SEARCH | O_DIRECTORY)
        try runner.expect(sFD >= 0 && dFD >= 0)
        defer {
            if sFD >= 0 { close(sFD) }
            if dFD >= 0 { close(dFD) }
        }

        let previousUmask = umask(0o022)
        defer { _ = umask(previousUmask) }

        try FileOperationsEngine.moveAcrossVolumesConfined(
            srcParentFD: sFD,
            srcName: "ROTree",
            dstParentFD: dFD,
            dstName: "ROTree",
            srcDisplayPath: roTree.path,
            dstDisplayPath: dstROTree.path
        )

        // P7.11: source 0o555 tree must be completely removed
        try runner.expect(!fm.fileExists(atPath: roTree.path), "P7.11: source ROTree must be completely removed after EXDEV move")
        let dstFile = dstROSub.appendingPathComponent("secret.bin")
        try runner.expectEqual(try Data(contentsOf: dstFile), Data("ro-payload".utf8))

        // Verify exact permissions preserved on file (not stripped by umask), 0o555 dirs, and 0o775 dirs
        var fileSt = stat()
        try runner.expectEqual(lstat(dstFile.path, &fileSt), 0)
        try runner.expectEqual(fileSt.st_mode & 0o7777, 0o640, "S_IFREG permissions must be preserved via fchmod")
        var rootDstSt = stat()
        try runner.expectEqual(lstat(dstROTree.path, &rootDstSt), 0)
        try runner.expectEqual(rootDstSt.st_mode & 0o7777, 0o555, "0o555 root directory permissions must be restored at destination")
        var subSt = stat()
        try runner.expectEqual(lstat(dstROSub.path, &subSt), 0)
        try runner.expectEqual(subSt.st_mode & 0o7777, 0o555, "0o555 directory permissions must be restored at destination")
        var gwSt = stat()
        try runner.expectEqual(lstat(dstROGroupWrite.path, &gwSt), 0)
        try runner.expectEqual(gwSt.st_mode & 0o7777, 0o775, "0o775 directory permissions must not be stripped by umask")

        // Finding 2: mid-copy failure after copying 0o555 subdir must clean up staging directory completely
        try fm.createDirectory(at: failROSub, withIntermediateDirectories: true)
        try fm.createDirectory(at: failDstDir, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: failROSub.appendingPathComponent("ok.txt"))
        try runner.expectEqual(chmod(failROSub.path, 0o555), 0)
        let badFifo = failTree.appendingPathComponent("zz_pipe.fifo")
        try runner.expectEqual(mkfifo(badFifo.path, 0o600), 0)

        let fsFD = open(failSrcDir.path, O_SEARCH | O_DIRECTORY)
        let fdFD = open(failDstDir.path, O_SEARCH | O_DIRECTORY)
        try runner.expect(fsFD >= 0 && fdFD >= 0)
        defer {
            if fsFD >= 0 { close(fsFD) }
            if fdFD >= 0 { close(fdFD) }
        }

        var failedMidCopy = false
        do {
            try FileOperationsEngine.moveAcrossVolumesConfined(
                srcParentFD: fsFD,
                srcName: "FailTree",
                dstParentFD: fdFD,
                dstName: "FailTree",
                srcDisplayPath: failTree.path,
                dstDisplayPath: failDstDir.appendingPathComponent("FailTree").path
            )
        } catch FileOperationError.crossVolumeMoveFailed {
            failedMidCopy = true
        }
        try runner.expect(failedMidCopy, "Unsupported FIFO inside EXDEV tree must fail cleanly")
        let leftovers = try fm.contentsOfDirectory(atPath: failDstDir.path)
        try runner.expect(leftovers.isEmpty, "Failed EXDEV copy with 0o555 subdir must leave zero staging orphans; found=\(leftovers)")
        try runner.expect(fm.fileExists(atPath: failTree.path), "Source tree must remain intact when EXDEV copy fails")
    }

    runner.run("FileOperationsEngine rejects destinationNotADirectory, sourceNotFound, destinationParentNotFound, dot component, and symlink-descendant moves") {
        let sandbox = try runner.makeTempSandbox(prefix: "fops-adv-errs")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let work = sandbox.appendingPathComponent("Work")
        let subDir = work.appendingPathComponent("ParentDir/Child")
        try fm.createDirectory(at: subDir, withIntermediateDirectories: true)

        let srcFile = work.appendingPathComponent("hello.txt")
        try Data("hi".utf8).write(to: srcFile)
        let notADirFile = work.appendingPathComponent("not-a-dir")
        try Data("x".utf8).write(to: notADirFile)

        let parentDir = work.appendingPathComponent("ParentDir")
        let symToChild = work.appendingPathComponent("sym-to-child")
        try fm.createSymbolicLink(at: symToChild, withDestinationURL: subDir)

        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)
        let engine = FileOperationsEngine(safetyGuard: sg)

        // 1. destinationNotADirectory
        var gotNotADir = false
        do {
            _ = try runAsync {
                try await engine.moveItem(
                    from: srcFile,
                    to: notADirFile,
                    expectedSourceCanonicalParent: PrivilegedExecutor.canonicalParentPath(forTargetURL: srcFile)
                )
            }
        } catch FileOperationError.destinationNotADirectory {
            gotNotADir = true
        }
        try runner.expect(gotNotADir, "Expected destinationNotADirectory")

        // 2. sourceNotFound
        let missingSrc = work.appendingPathComponent("missing.txt")
        var gotSourceNotFound = false
        do {
            _ = try runAsync {
                try await engine.moveItem(
                    from: missingSrc,
                    to: parentDir,
                    expectedSourceCanonicalParent: PrivilegedExecutor.canonicalParentPath(forTargetURL: missingSrc)
                )
            }
        } catch FileOperationError.sourceNotFound {
            gotSourceNotFound = true
        }
        try runner.expect(gotSourceNotFound, "Expected sourceNotFound")

        // 3. destinationParentNotFound
        let missingDst = work.appendingPathComponent("NoSuchDir")
        var gotDstParentNotFound = false
        do {
            _ = try runAsync {
                try await engine.moveItem(
                    from: srcFile,
                    to: missingDst,
                    expectedSourceCanonicalParent: PrivilegedExecutor.canonicalParentPath(forTargetURL: srcFile)
                )
            }
        } catch FileOperationError.destinationParentNotFound {
            gotDstParentNotFound = true
        }
        try runner.expect(gotDstParentNotFound, "Expected destinationParentNotFound")

        // 4. Move directory into symlink pointing to descendant of source
        var gotMoveIntoSelf = false
        do {
            _ = try runAsync {
                try await engine.moveItem(
                    from: parentDir,
                    to: symToChild,
                    expectedSourceCanonicalParent: PrivilegedExecutor.canonicalParentPath(forTargetURL: parentDir)
                )
            }
        } catch let err as FileOperationError {
            if case .cannotMoveDirectoryIntoItself = err { gotMoveIntoSelf = true }
            else if case .blockedBySafetyGuard = err { gotMoveIntoSelf = true }
        }
        try runner.expect(gotMoveIntoSelf, "Moving ParentDir into symlink to its descendant must be blocked")

        // 5. Reject `.` path component in validateRawFileURL
        let dotURL = URL(string: "file://" + work.path + "/./hello.txt")!
        var rejectedDot = false
        do {
            _ = try runAsync {
                try await engine.renameItem(
                    at: dotURL,
                    toNewName: "renamed.txt",
                    expectedSourceCanonicalParent: PrivilegedExecutor.canonicalParentPath(forTargetURL: srcFile)
                )
            }
        } catch FileOperationError.blockedBySafetyGuard {
            rejectedDot = true
        } catch FileOperationError.invalidName {
            rejectedDot = true
        }
        try runner.expect(rejectedDot, "Dot path component must be rejected")
    }

    runner.run("FileOperationsEngine handles NFC/NFD rename on APFS and moveAcrossVolumesConfined rolls back cleanly on uchg nested child") {
        let sandbox = try runner.makeTempSandbox(prefix: "fops-nfc-exdev")
        let fm = FileManager.default
        let work = sandbox.appendingPathComponent("Work")
        let srcDir = sandbox.appendingPathComponent("Src")
        let lockedTree = srcDir.appendingPathComponent("LockedTree")
        let lockedSub = lockedTree.appendingPathComponent("Sub")
        let lockedFile = lockedSub.appendingPathComponent("imm.bin")
        let dstDir = sandbox.appendingPathComponent("Dst")

        defer {
            _ = chflags(lockedFile.path, 0)
            _ = chmod(lockedSub.path, 0o755)
            _ = chmod(lockedTree.path, 0o755)
            try? fm.removeItem(at: sandbox)
        }

        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.createDirectory(at: lockedSub, withIntermediateDirectories: true)
        try fm.createDirectory(at: dstDir, withIntermediateDirectories: true)

        // 1. NFC -> NFD rename on same directory (same inode, distinct canonical form)
        let nfcFile = work.appendingPathComponent("r\u{00E9}sum\u{00E9}.txt")
        try Data("nfc".utf8).write(to: nfcFile)
        let sg = SafetyGuard(homeDirectory: sandbox, selfBundlePath: nil)
        let engine = FileOperationsEngine(safetyGuard: sg)
        let nfdName = "re\u{0301}sume\u{0301}-v2.txt"
        let renamed = try runAsync {
            try await engine.renameItem(
                at: nfcFile,
                toNewName: nfdName,
                expectedSourceCanonicalParent: PrivilegedExecutor.canonicalParentPath(forTargetURL: nfcFile)
            )
        }
        try runner.expect(fm.fileExists(atPath: renamed.path))
        try runner.expectEqual(try Data(contentsOf: renamed), Data("nfc".utf8))

        // 2. moveAcrossVolumesConfined rollback when nested file is uchg (cannot unlink source after copy)
        try Data("immutable".utf8).write(to: lockedFile)
        try runner.expectEqual(chflags(lockedFile.path, UInt32(UF_IMMUTABLE)), 0)

        let sFD = open(srcDir.path, O_SEARCH | O_DIRECTORY)
        let dFD = open(dstDir.path, O_SEARCH | O_DIRECTORY)
        try runner.expect(sFD >= 0 && dFD >= 0)
        defer {
            if sFD >= 0 { close(sFD) }
            if dFD >= 0 { close(dFD) }
        }

        var failedEXDEV = false
        do {
            try FileOperationsEngine.moveAcrossVolumesConfined(
                srcParentFD: sFD,
                srcName: "LockedTree",
                dstParentFD: dFD,
                dstName: "LockedTree",
                srcDisplayPath: lockedTree.path,
                dstDisplayPath: dstDir.appendingPathComponent("LockedTree").path
            )
        } catch FileOperationError.userImmutable {
            failedEXDEV = true
        } catch FileOperationError.crossVolumeMoveFailed {
            failedEXDEV = true
        }
        try runner.expect(failedEXDEV, "EXDEV move with uchg nested child must fail cleanly")
        let dstLeftovers = try fm.contentsOfDirectory(atPath: dstDir.path)
        try runner.expect(dstLeftovers.isEmpty, "Failed EXDEV move must roll back destination staging cleanly; found=\(dstLeftovers)")
        try runner.expect(fm.fileExists(atPath: lockedFile.path), "Source uchg file must remain intact")
    }

    runner.run("Audit regression: moveAcrossVolumesConfined preserves file mtime, xattrs, directory mtime, and deep trees") {
        let sandbox = try runner.makeTempSandbox(prefix: "fops-r3-meta")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: sandbox) }

        let srcParent = sandbox.appendingPathComponent("Src")
        let dstParent = sandbox.appendingPathComponent("Dst")
        let rootTree = srcParent.appendingPathComponent("DeepTree")
        try fm.createDirectory(at: rootTree, withIntermediateDirectories: true)
        try fm.createDirectory(at: dstParent, withIntermediateDirectories: true)

        var cursor = rootTree
        for level in 0..<24 {
            cursor = cursor.appendingPathComponent("lvl_\(level)")
        }
        try fm.createDirectory(at: cursor, withIntermediateDirectories: true)

        let leafFile = cursor.appendingPathComponent("payload.bin")
        let payload = Data("cross-volume-metadata-payload".utf8)
        try payload.write(to: leafFile)

        let attrName = "com.macsweep.test.meta"
        let attrVal = Array("preserved-xattr".utf8)
        let setRes = setxattr(leafFile.path, attrName, attrVal, attrVal.count, 0, XATTR_NOFOLLOW)
        try runner.expectEqual(setRes, 0, "setxattr failed with errno=\(errno)")

        let targetEpoch: time_t = 1_700_000_000
        var tv = [timeval(tv_sec: targetEpoch, tv_usec: 0), timeval(tv_sec: targetEpoch, tv_usec: 0)]
        try runner.expectEqual(utimes(leafFile.path, &tv), 0, "utimes on leafFile failed")
        try runner.expectEqual(utimes(rootTree.path, &tv), 0, "utimes on rootTree failed")

        let sFD = open(srcParent.path, O_SEARCH | O_DIRECTORY)
        let dFD = open(dstParent.path, O_SEARCH | O_DIRECTORY)
        try runner.expect(sFD >= 0 && dFD >= 0)
        defer {
            if sFD >= 0 { close(sFD) }
            if dFD >= 0 { close(dFD) }
        }

        try FileOperationsEngine.moveAcrossVolumesConfined(
            srcParentFD: sFD,
            srcName: "DeepTree",
            dstParentFD: dFD,
            dstName: "DeepTree",
            srcDisplayPath: rootTree.path,
            dstDisplayPath: dstParent.appendingPathComponent("DeepTree").path
        )

        let dstRoot = dstParent.appendingPathComponent("DeepTree")
        var dstLeaf = dstRoot
        for level in 0..<24 {
            dstLeaf = dstLeaf.appendingPathComponent("lvl_\(level)")
        }
        dstLeaf = dstLeaf.appendingPathComponent("payload.bin")

        try runner.expect(!fm.fileExists(atPath: rootTree.path), "Source tree must be removed after cross-volume move")
        try runner.expectEqual(try Data(contentsOf: dstLeaf), payload)

        var fileSt = stat()
        try runner.expectEqual(lstat(dstLeaf.path, &fileSt), 0)
        try runner.expectEqual(fileSt.st_mtimespec.tv_sec, targetEpoch, "File mtime must be preserved across EXDEV move")

        var rootSt = stat()
        try runner.expectEqual(lstat(dstRoot.path, &rootSt), 0)
        try runner.expectEqual(rootSt.st_mtimespec.tv_sec, targetEpoch, "Directory mtime must be preserved across EXDEV move")

        var buf = [UInt8](repeating: 0, count: 64)
        let gotLen = getxattr(dstLeaf.path, attrName, &buf, buf.count, 0, XATTR_NOFOLLOW)
        try runner.expectEqual(gotLen, attrVal.count, "Extended attribute length must be preserved across EXDEV move")
        try runner.expectEqual(String(decoding: buf.prefix(max(0, gotLen)), as: UTF8.self), "preserved-xattr")
    }
}

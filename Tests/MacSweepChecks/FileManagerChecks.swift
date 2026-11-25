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

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [DiskScanProgress] = []

    func record(_ event: DiskScanProgress) {
        lock.withLock { events.append(event) }
    }

    func snapshot() -> [DiskScanProgress] {
        lock.withLock { events }
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

private func writeExactFile(at url: URL, byteCount: Int, fill: UInt8 = 0x41) throws -> UInt64 {
    try Data(repeating: fill, count: byteCount).write(to: url)
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return UInt64(byteCount) }
    return st.st_blocks > 0 ? UInt64(st.st_blocks) * 512 : UInt64(max(0, st.st_size))
}

func runFileManagerChecks(_ runner: CheckRunner) {
    print("== File Manager (M2) Checks ==")

    runner.run("DiskSpaceAnalyzer computes exact tree sizes, descending order, and accurate isTruncated roll-ups across depth & child caps") {
        let sandbox = try runner.makeTempSandbox(prefix: "fm-analyzer-tree")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let dirA = sandbox.appendingPathComponent("Alpha")
        let dirB = sandbox.appendingPathComponent("Beta")
        let dirBNested = dirB.appendingPathComponent("Deep")
        let emptyDir = sandbox.appendingPathComponent("Empty")
        let capDir = sandbox.appendingPathComponent("ManyFiles")

        for dir in [dirA, dirBNested, emptyDir, capDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let bAlpha = try writeExactFile(at: dirA.appendingPathComponent("a.bin"), byteCount: 32_768)
        let bBetaTop = try writeExactFile(at: dirB.appendingPathComponent("b1.bin"), byteCount: 8_192)
        let bBetaDeep = try writeExactFile(at: dirBNested.appendingPathComponent("b2.bin"), byteCount: 65_536)

        var capBytes: [UInt64] = []
        for (i, size) in [4_096, 20_480, 8_192, 40_960, 12_288].enumerated() {
            let actual = try writeExactFile(at: capDir.appendingPathComponent("f\(i).bin"), byteCount: size)
            capBytes.append(actual)
        }
        let capTotal = capBytes.reduce(0, +)
        let capSortedDesc = capBytes.sorted(by: >)
        let sg = SafetyGuard(homeDirectory: sandbox)

        // 1. Uncapped scan
        let fullAnalyzer = DiskSpaceAnalyzer(safetyGuard: sg, maxChildrenPerDirectory: 100)
        let fullRoot = try runAsync {
            try await fullAnalyzer.analyze(root: sandbox, maxDepth: 5)
        }
        let expectedTotal = bAlpha + bBetaTop + bBetaDeep + capTotal
        try runner.expectEqual(fullRoot.bytes, expectedTotal)
        try runner.expectEqual(fullRoot.fileCount, 8)
        try runner.expectEqual(fullRoot.folderCount, 5)
        try runner.expect(!fullRoot.isTruncated)
        try runner.expect(!fullRoot.hasTruncatedDescendant)
        // Children sorted descending by bytes: ManyFiles (86016) > Beta (73728) > Alpha (32768) > Empty (0)
        try runner.expectEqual(fullRoot.children.map(\.name), ["ManyFiles", "Beta", "Alpha", "Empty"])

        // 2. Depth-capped scan (maxDepth: 1) preserves exact parent roll-up!
        let depthCapped = try runAsync {
            try await fullAnalyzer.analyze(root: sandbox, maxDepth: 1)
        }
        try runner.expectEqual(depthCapped.bytes, expectedTotal)
        try runner.expectEqual(depthCapped.fileCount, 8)
        try runner.expectEqual(depthCapped.folderCount, 5)
        try runner.expect(!depthCapped.isTruncated)
        try runner.expect(depthCapped.hasTruncatedDescendant)
        let betaNode = depthCapped.children.first { $0.name == "Beta" }
        let emptyNode = depthCapped.children.first { $0.name == "Empty" }
        try runner.expectEqual(betaNode?.children.count, 0)
        try runner.expectEqual(betaNode?.isTruncated, true)
        try runner.expectEqual(betaNode?.bytes, bBetaTop + bBetaDeep)
        try runner.expectEqual(betaNode?.fileCount, 2)
        try runner.expectEqual(betaNode?.folderCount, 1)
        try runner.expectEqual(emptyNode?.isTruncated, false)

        // 3. Child-capped scan (maxChildrenPerDirectory: 2) keeps top 2 and exact roll-up
        let childCapAnalyzer = DiskSpaceAnalyzer(safetyGuard: sg, maxChildrenPerDirectory: 2)
        let capRoot = try runAsync {
            try await childCapAnalyzer.analyze(root: capDir, maxDepth: 3)
        }
        try runner.expectEqual(capRoot.bytes, capTotal)
        try runner.expectEqual(capRoot.children.count, 2)
        try runner.expectEqual(capRoot.children.map(\.bytes), Array(capSortedDesc.prefix(2)))
        try runner.expect(capRoot.isTruncated)
        try runner.expectEqual(capRoot.truncatedChildCount, 3)
        try runner.expectEqual(capRoot.unlistedChildrenBytes, capSortedDesc.dropFirst(2).reduce(0, +))
    }

    runner.run("DiskSpaceAnalyzer skips symlinks (no loop, no external bytes) and deduplicates hardlinks by (st_dev, st_ino)") {
        let sandbox = try runner.makeTempSandbox(prefix: "fm-analyzer-links")
        let external = try runner.makeTempSandbox(prefix: "fm-analyzer-ext")
        defer {
            try? FileManager.default.removeItem(at: sandbox)
            try? FileManager.default.removeItem(at: external)
        }

        let fm = FileManager.default
        let extFile = external.appendingPathComponent("secret.bin")
        _ = try writeExactFile(at: extFile, byteCount: 100_000)

        let origFile = sandbox.appendingPathComponent("original.bin")
        let origBytes = try writeExactFile(at: origFile, byteCount: 32_768)
        let hardlinkFile = sandbox.appendingPathComponent("hardlink.bin")
        try runner.expectEqual(Darwin.link(origFile.path, hardlinkFile.path), 0)

        let extSym = sandbox.appendingPathComponent("ext-link")
        try fm.createSymbolicLink(at: extSym, withDestinationURL: external)
        let cycleSym = sandbox.appendingPathComponent("self-cycle")
        try fm.createSymbolicLink(at: cycleSym, withDestinationURL: sandbox)

        let recorder = ProgressRecorder()
        let analyzer = DiskSpaceAnalyzer(safetyGuard: SafetyGuard(homeDirectory: sandbox), progressThrottleInterval: 0.01)
        let rootNode = try runAsync {
            try await analyzer.analyze(root: sandbox, maxDepth: 4) { prog in
                recorder.record(prog)
            }
        }

        try runner.expectEqual(rootNode.bytes, origBytes)
        try runner.expectEqual(rootNode.fileCount, 2)
        let lastProg = recorder.snapshot().last
        try runner.expect((lastProg?.skippedSymlinks ?? 0) >= 2)
        try runner.expectEqual(lastProg?.deduplicatedHardlinks, 1)
    }

    runner.run("DiskSpaceAnalyzer skips st_dev mount boundaries and SF_DATALESS cloud placeholders via statProvider") {
        let sandbox = try runner.makeTempSandbox(prefix: "fm-analyzer-boundaries")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let localFile = sandbox.appendingPathComponent("local.bin")
        let localBytes = try writeExactFile(at: localFile, byteCount: 16_384)
        let datalessFile = sandbox.appendingPathComponent("cloud.bin")
        _ = try writeExactFile(at: datalessFile, byteCount: 65_536)
        let foreignMountDir = sandbox.appendingPathComponent("MountedDrive")
        try fm.createDirectory(at: foreignMountDir, withIntermediateDirectories: true)
        _ = try writeExactFile(at: foreignMountDir.appendingPathComponent("ext.bin"), byteCount: 65_536)

        var baseStat = stat()
        try runner.expectEqual(lstat(sandbox.path, &baseStat), 0)
        let foreignDev = baseStat.st_dev &+ 1
        let datalessPath = datalessFile.standardizedFileURL.path
        let foreignPath = foreignMountDir.standardizedFileURL.path

        let analyzer = DiskSpaceAnalyzer(
            safetyGuard: SafetyGuard(homeDirectory: sandbox),
            statProvider: { path in
                var st = stat()
                guard lstat(path, &st) == 0 else { return nil }
                if path == datalessPath {
                    st.st_flags |= UInt32(SF_DATALESS)
                } else if path == foreignPath {
                    st.st_dev = foreignDev
                }
                return st
            }
        )

        let recorder = ProgressRecorder()
        let rootNode = try runAsync {
            try await analyzer.analyze(root: sandbox, maxDepth: 4) { p in
                recorder.record(p)
            }
        }

        try runner.expectEqual(rootNode.bytes, localBytes)
        try runner.expectEqual(rootNode.fileCount, 1)
        try runner.expectEqual(rootNode.folderCount, 0)
        let lastProg = recorder.snapshot().last
        try runner.expectEqual(lastProg?.skippedDataless, 1)
        try runner.expectEqual(lastProg?.skippedCrossVolume, 1)
    }

    runner.run("DiskSpaceAnalyzer supports cancellation, VolumeStorageInfo, and large/old file filtering") {
        let sandbox = try runner.makeTempSandbox(prefix: "fm-analyzer-filter")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let sub = sandbox.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let bigOldFile = sub.appendingPathComponent("archive-old.tar")
        let bigOldBytes = try writeExactFile(at: bigOldFile, byteCount: 120_000)
        let smallNewFile = sandbox.appendingPathComponent("note.txt")
        _ = try writeExactFile(at: smallNewFile, byteCount: 1_024)

        let oldDate = Date(timeIntervalSinceNow: -200 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: bigOldFile.path)

        let volInfo = try DiskSpaceAnalyzer.volumeInfo(for: sandbox)
        try runner.expect(volInfo.totalBytes > 0)
        try runner.expectEqual(volInfo.usedBytes + volInfo.availableBytes, volInfo.totalBytes)
        try runner.expect(!DiskSpaceAnalyzer.mountedVolumes().isEmpty)

        let analyzer = DiskSpaceAnalyzer(safetyGuard: SafetyGuard(homeDirectory: sandbox))
        let rootNode = try runAsync {
            try await analyzer.analyze(root: sandbox, maxDepth: 4)
        }

        let filter = DiskEntryFilter(
            minBytes: 50_000,
            olderThanDays: 90,
            ageBasis: .modificationDate,
            scope: .filesAndPackages,
            searchText: "archive"
        )
        let treeMatches = DiskSpaceAnalyzer.filterNodes(in: rootNode, filter: filter)
        try runner.expectEqual(treeMatches.count, 1)
        try runner.expectEqual(treeMatches.first?.name, "archive-old.tar")
        try runner.expectEqual(treeMatches.first?.bytes, bigOldBytes)
        try runner.expectEqual(treeMatches.first?.expectedCanonicalParent, PrivilegedExecutor.canonicalParentPath(forTargetURL: bigOldFile))

        let deepMatches = try runAsync {
            try await analyzer.findMatchingFiles(under: sandbox, filter: filter)
        }
        try runner.expectEqual(deepMatches.count, 1)
        try runner.expectEqual(deepMatches.first?.id, treeMatches.first?.id)

        // Pre-cancelled Task throws CancellationError
        var cancelledThrew = false
        let sem = DispatchSemaphore(value: 0)
        let flagBox = AsyncResultBox<Bool>()
        let cancelledTask = Task {
            try await Task.sleep(nanoseconds: 50_000_000)
            _ = try await analyzer.analyze(root: sandbox, maxDepth: 4)
        }
        cancelledTask.cancel()
        Task {
            do {
                _ = try await cancelledTask.value
                flagBox.store(.success(false))
            } catch is CancellationError {
                flagBox.store(.success(true))
            } catch {
                flagBox.store(.failure(error))
            }
            sem.signal()
        }
        sem.wait()
        cancelledThrew = try flagBox.take()!.get()
        try runner.expect(cancelledThrew)
    }

    runner.run("DiskSpaceAnalyzer and FileBrowserService produce identical parity between getattrlistbulk and readdir+fstatat fallback") {
        let sandbox = try runner.makeTempSandbox(prefix: "fm-parity")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let nested = sandbox.appendingPathComponent("Nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try writeExactFile(at: sandbox.appendingPathComponent("alpha.txt"), byteCount: 12_345)
        _ = try writeExactFile(at: sandbox.appendingPathComponent(".hidden"), byteCount: 4_096)
        _ = try writeExactFile(at: nested.appendingPathComponent("beta.bin"), byteCount: 32_768)
        try fm.createSymbolicLink(at: sandbox.appendingPathComponent("broken-link"), withDestinationURL: sandbox.appendingPathComponent("missing"))

        let sg = SafetyGuard(homeDirectory: sandbox)
        let bulkAnalyzer = DiskSpaceAnalyzer(safetyGuard: sg, enumerationMode: .bulkOnly)
        let fallbackAnalyzer = DiskSpaceAnalyzer(safetyGuard: sg, enumerationMode: .fallbackOnly)

        let bulkTree = try runAsync { try await bulkAnalyzer.analyze(root: sandbox, maxDepth: 4) }
        let fallbackTree = try runAsync { try await fallbackAnalyzer.analyze(root: sandbox, maxDepth: 4) }
        try runner.expectEqual(bulkTree.bytes, fallbackTree.bytes)
        try runner.expectEqual(bulkTree.fileCount, fallbackTree.fileCount)
        try runner.expectEqual(bulkTree.folderCount, fallbackTree.folderCount)
        try runner.expectEqual(bulkTree.children.map(\.name), fallbackTree.children.map(\.name))

        let bulkBrowser = FileBrowserService(safetyGuard: sg, homeDirectory: sandbox, enumerationMode: .bulkOnly)
        let fallbackBrowser = FileBrowserService(safetyGuard: sg, homeDirectory: sandbox, enumerationMode: .fallbackOnly)

        let bulkEntries = try bulkBrowser.listDirectory(at: sandbox, showHidden: true, sortBy: .name, ascending: true)
        let fallbackEntries = try fallbackBrowser.listDirectory(at: sandbox, showHidden: true, sortBy: .name, ascending: true)
        try runner.expectEqual(bulkEntries.map(\.name), fallbackEntries.map(\.name))
        try runner.expectEqual(bulkEntries.map(\.sizeBytes), fallbackEntries.map(\.sizeBytes))
        try runner.expectEqual(bulkEntries.map(\.kind), fallbackEntries.map(\.kind))
        try runner.expectEqual(bulkEntries.map(\.isSymlinkBroken), fallbackEntries.map(\.isSymlinkBroken))
        try runner.expectEqual(bulkEntries.map(\.isHidden), fallbackEntries.map(\.isHidden))
    }

    runner.run("FileBrowserService lists, filters hidden/search, sorts, provides favorites, and throws tccOrPermissionDenied on chmod 000") {
        let sandbox = try runner.makeTempSandbox(prefix: "fm-browser-list")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let fSmall = sandbox.appendingPathComponent("b-small.txt")
        let fBig = sandbox.appendingPathComponent("a-big.log")
        let fHidden = sandbox.appendingPathComponent(".env")
        let folder = sandbox.appendingPathComponent("c-Folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: fSmall)
        try Data(repeating: 0x42, count: 5_000).write(to: fBig)
        try Data("SECRET=1".utf8).write(to: fHidden)

        let sg = SafetyGuard(homeDirectory: sandbox)
        let browser = FileBrowserService(safetyGuard: sg, homeDirectory: sandbox)

        let visibleDefault = try browser.listDirectory(at: sandbox, showHidden: false, sortBy: .name, ascending: true)
        try runner.expectEqual(visibleDefault.map(\.name), ["a-big.log", "b-small.txt", "c-Folder"])

        let withHidden = try browser.listDirectory(at: sandbox, showHidden: true, sortBy: .size, ascending: false)
        try runner.expectEqual(withHidden.first?.name, "a-big.log")
        try runner.expect(withHidden.contains { $0.name == ".env" && $0.isHidden })

        let searched = try browser.listDirectory(at: sandbox, showHidden: true, searchQuery: "small")
        try runner.expectEqual(searched.map(\.name), ["b-small.txt"])

        let expectedParent = PrivilegedExecutor.canonicalParentPath(for: sandbox.path)
        try runner.expectEqual(visibleDefault.first?.expectedCanonicalParent, expectedParent)

        let favKinds = Set(browser.quickFavorites().map(\.kind))
        try runner.expect(favKinds.contains(.home))
        try runner.expect(favKinds.contains(.desktop))
        try runner.expect(favKinds.contains(.documents))
        try runner.expect(favKinds.contains(.downloads))
        try runner.expect(favKinds.contains(.applications))
        try runner.expect(favKinds.contains(.caches))

        if geteuid() != 0 {
            let lockedDir = sandbox.appendingPathComponent("LockedDir")
            try fm.createDirectory(at: lockedDir, withIntermediateDirectories: true)
            try runner.expectEqual(chmod(lockedDir.path, 0o000), 0)
            defer { _ = chmod(lockedDir.path, 0o755) }

            var threwTCC = false
            do {
                _ = try browser.listDirectory(at: lockedDir)
            } catch let err as FileBrowserError {
                if case .tccOrPermissionDenied = err {
                    threwTCC = true
                }
            }
            try runner.expect(threwTCC)
        }
    }

    runner.run("FileBrowserService bounded preview safely handles UTF-8 boundary truncation, binary hex, images, FIFOs, symlinks, and SF_DATALESS") {
        let sandbox = try runner.makeTempSandbox(prefix: "fm-preview")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let sg = SafetyGuard(homeDirectory: sandbox)
        let browser = FileBrowserService(safetyGuard: sg, homeDirectory: sandbox)

        // 1. UTF-8 multi-byte boundary cut ("AAAA" + "中文测试" truncated mid-scalar)
        let utf8File = sandbox.appendingPathComponent("utf8.txt")
        try Data("AAAA中文测试".utf8).write(to: utf8File)
        let textPreview = try browser.loadPreview(at: utf8File, maxTextBytes: 6) // 4 ASCII + 2 bytes of 3-byte '中'
        if case let .text(decoded, _, isTruncated, total) = textPreview.content {
            try runner.expectEqual(decoded, "AAAA")
            try runner.expect(isTruncated)
            try runner.expect((total ?? 0) > 6)
        } else {
            throw NSError(domain: "MacSweepChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected UTF-8 .text preview"])
        }

        // 2. Binary file -> .hexDump
        let binFile = sandbox.appendingPathComponent("data.bin")
        try Data([0x00, 0x01, 0xFE, 0xFF, 0x41, 0x42]).write(to: binFile)
        let hexPreview = try browser.loadPreview(at: binFile)
        if case let .hexDump(hex, byteCount, _, _) = hexPreview.content {
            try runner.expectEqual(byteCount, 6)
            try runner.expect(hex.contains("00 01 FE FF"))
        } else {
            throw NSError(domain: "MacSweepChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected .hexDump preview"])
        }

        // 3. Valid PNG image vs oversized image
        let pngBytes = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
            0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
            0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
            0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
            0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82,
        ])
        let imgFile = sandbox.appendingPathComponent("pixel.png")
        try pngBytes.write(to: imgFile)
        let imgPreview = try browser.loadPreview(at: imgFile, maxImageBytes: 1024)
        if case let .image(data, _, count) = imgPreview.content {
            try runner.expectEqual(count, pngBytes.count)
            try runner.expectEqual(data, pngBytes)
        } else {
            throw NSError(domain: "MacSweepChecks", code: 3, userInfo: [NSLocalizedDescriptionKey: "Expected .image preview"])
        }

        let bigImgPreview = try browser.loadPreview(at: imgFile, maxImageBytes: 16)
        if case .unavailable(.imageTooLarge) = bigImgPreview.content {} else {
            throw NSError(domain: "MacSweepChecks", code: 4, userInfo: [NSLocalizedDescriptionKey: "Expected .imageTooLarge preview"])
        }

        // 4. FIFO special file must never block
        let fifo = sandbox.appendingPathComponent("pipe.fifo")
        try runner.expectEqual(mkfifo(fifo.path, 0o600), 0)
        let fifoPreview = try browser.loadPreview(at: fifo)
        try runner.expectEqual(fifoPreview.content, .unavailable(reason: .specialFile))

        // 5. Symlink, directory, empty file
        let sym = sandbox.appendingPathComponent("link-utf8")
        try fm.createSymbolicLink(at: sym, withDestinationURL: utf8File)
        try runner.expectEqual(try browser.loadPreview(at: sym).content, .unavailable(reason: .symbolicLink))
        try runner.expectEqual(try browser.loadPreview(at: sandbox).content, .unavailable(reason: .directory))
        let emptyFile = sandbox.appendingPathComponent("empty.txt")
        try Data().write(to: emptyFile)
        try runner.expectEqual(try browser.loadPreview(at: emptyFile).content, .unavailable(reason: .emptyFile))

        // 6. SF_DATALESS gate via statProvider
        let datalessBrowser = FileBrowserService(
            safetyGuard: sg,
            homeDirectory: sandbox,
            statProvider: { path in
                var st = stat()
                guard lstat(path, &st) == 0 else { return nil }
                st.st_flags |= UInt32(SF_DATALESS)
                return st
            }
        )
        try runner.expectEqual(try datalessBrowser.loadPreview(at: utf8File).content, .unavailable(reason: .datalessCloudFile))
    }

    runner.run("FileBrowserService protection flags, FileOperationsEngine rename, and RemovalEngine + CleanupHistoryStore wiring preserve TOCTOU safety") {
        let sandbox = try runner.makeTempSandbox(prefix: "fm-wiring")
        let historyFile = sandbox.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let workDir = sandbox.appendingPathComponent("Work")
        let protectedFile = workDir.appendingPathComponent("protected.txt")
        let lockedFile = workDir.appendingPathComponent("locked.txt")
        let normalFile = workDir.appendingPathComponent("rename-me.txt")
        let trashTargetFile = workDir.appendingPathComponent("delete-me.txt")
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        try Data("prot".utf8).write(to: protectedFile)
        try Data("lock".utf8).write(to: lockedFile)
        try Data("norm".utf8).write(to: normalFile)
        try Data("del".utf8).write(to: trashTargetFile)

        _ = chflags(lockedFile.path, UInt32(UF_IMMUTABLE))
        defer { _ = chflags(lockedFile.path, 0) }

        let sg = SafetyGuard(homeDirectory: sandbox, protectedPaths: [protectedFile.path])
        let browser = FileBrowserService(safetyGuard: sg, homeDirectory: sandbox)
        let entries = try browser.listDirectory(at: workDir, sortBy: .name, ascending: true)

        let protEntry = entries.first { $0.name == "protected.txt" }!
        let lockEntry = entries.first { $0.name == "locked.txt" }!
        let normEntry = entries.first { $0.name == "rename-me.txt" }!
        let delEntry = entries.first { $0.name == "delete-me.txt" }!

        try runner.expect(protEntry.isProtected && protEntry.isMutationLocked && protEntry.protectionReason != nil)
        try runner.expect(lockEntry.isUserImmutable && lockEntry.isMutationLocked)
        try runner.expect(!normEntry.isMutationLocked)

        // Rename normal entry succeeds; protected & locked fail
        let renamedURL = try runAsync {
            try await browser.fileOperationsEngine.renameItem(
                at: normEntry.url,
                toNewName: "renamed.txt",
                expectedSourceCanonicalParent: normEntry.expectedCanonicalParent
            )
        }
        try runner.expect(fm.fileExists(atPath: renamedURL.path))

        var protRejected = false
        do {
            _ = try runAsync {
                try await browser.fileOperationsEngine.renameItem(
                    at: protEntry.url,
                    toNewName: "hack.txt",
                    expectedSourceCanonicalParent: protEntry.expectedCanonicalParent
                )
            }
        } catch {
            protRejected = true
        }
        try runner.expect(protRejected)

        var lockRejected = false
        do {
            _ = try runAsync {
                try await browser.fileOperationsEngine.renameItem(
                    at: lockEntry.url,
                    toNewName: "hack2.txt",
                    expectedSourceCanonicalParent: lockEntry.expectedCanonicalParent
                )
            }
        } catch {
            lockRejected = true
        }
        try runner.expect(lockRejected)

        // RemovalEngine + CleanupHistoryStore using scan-time expectedCanonicalParent
        let histStore = CleanupHistoryStore(fileURL: historyFile)
        let engine = RemovalEngine(safetyGuard: sg, historyStore: histStore)
        let report = engine.remove(
            targets: [
                RemovalTarget(
                    url: delEntry.url,
                    estimatedSize: delEntry.sizeBytes,
                    requiresAdmin: delEntry.requiresAdmin,
                    expectedCanonicalParent: delEntry.expectedCanonicalParent
                ),
            ],
            mode: .permanent,
            actionTitle: "FM Test Delete"
        )
        try runner.expect(report.isFullSuccess)
        try runner.expect(!fm.fileExists(atPath: delEntry.url.path))
        let records = histStore.load()
        try runner.expectEqual(records.count, 1)
        try runner.expectEqual(records.first?.actionTitle, "FM Test Delete")
    }

    runner.run("DiskSpaceAnalyzer findMatchingFiles deduplicates hardlinks across .app package boundaries identically to analyze + filterNodes") {
        let sandbox = try runner.makeTempSandbox(prefix: "fm-pkg-hardlink-parity")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let appMacOS = sandbox.appendingPathComponent("MyApp.app/Contents/MacOS")
        try fm.createDirectory(at: appMacOS, withIntermediateDirectories: true)
        let appInfoPlist = sandbox.appendingPathComponent("MyApp.app/Contents/Info.plist")
        let plistBytes = try writeExactFile(at: appInfoPlist, byteCount: 512)

        let outsideFile = sandbox.appendingPathComponent("outside.bin")
        let linkedBytes = try writeExactFile(at: outsideFile, byteCount: 65_536)
        let innerBin = appMacOS.appendingPathComponent("MyApp")
        try runner.expectEqual(Darwin.link(outsideFile.path, innerBin.path), 0)

        let sg = SafetyGuard(homeDirectory: sandbox)
        let analyzer = DiskSpaceAnalyzer(safetyGuard: sg)
        let tree = try runAsync {
            try await analyzer.analyze(root: sandbox, maxDepth: 6)
        }
        try runner.expectEqual(tree.bytes, linkedBytes + plistBytes)

        for scope in DiskTreeFilterScope.allCases {
            for minBytes: UInt64 in [0, 1_024, 32_768] {
                let filter = DiskEntryFilter(minBytes: minBytes, scope: scope, maxResults: 200)
                let treeMatches = DiskSpaceAnalyzer.filterNodes(in: tree, filter: filter)
                let deepMatches = try runAsync {
                    try await analyzer.findMatchingFiles(under: sandbox, filter: filter)
                }

                try runner.expectEqual(deepMatches.count, treeMatches.count)
                try runner.expectEqual(deepMatches.map(\.relativePathFromRoot), treeMatches.map(\.relativePathFromRoot))
                try runner.expectEqual(deepMatches.map(\.bytes), treeMatches.map(\.bytes))
                try runner.expectEqual(deepMatches.map(\.isPackage), treeMatches.map(\.isPackage))
                try runner.expectEqual(deepMatches.map(\.isDirectory), treeMatches.map(\.isDirectory))

                if scope == .filesAndPackages {
                    let totalFilteredBytes = deepMatches.reduce(into: UInt64(0)) { $0 &+= $1.bytes }
                    let expectedTreeBytes = treeMatches.reduce(into: UInt64(0)) { $0 &+= $1.bytes }
                    try runner.expectEqual(totalFilteredBytes, expectedTreeBytes)
                    try runner.expect(totalFilteredBytes <= linkedBytes + plistBytes)
                    if minBytes == 0 {
                        try runner.expectEqual(totalFilteredBytes, linkedBytes + plistBytes)
                    }
                }
            }
        }
    }

    runner.run("DiskSpaceAnalyzer findMatchingFiles matches filterNodes across all DiskTreeFilterScope cases for minBytes == 0 and minBytes > 0") {
        let sandbox = try runner.makeTempSandbox(prefix: "fm-scope-parity")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let folderA = sandbox.appendingPathComponent("FolderA")
        let subA = folderA.appendingPathComponent("Sub")
        let emptyDir = sandbox.appendingPathComponent("EmptyDir")
        let pkgMacOS = sandbox.appendingPathComponent("TestApp.app/Contents/MacOS")
        for dir in [subA, emptyDir, pkgMacOS] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        _ = try writeExactFile(at: sandbox.appendingPathComponent("top-big.bin"), byteCount: 32_768)
        _ = try writeExactFile(at: sandbox.appendingPathComponent("tiny.txt"), byteCount: 64)
        _ = try writeExactFile(at: folderA.appendingPathComponent("a1.bin"), byteCount: 20_480)
        _ = try writeExactFile(at: subA.appendingPathComponent("sub.bin"), byteCount: 24_576)
        _ = try writeExactFile(at: pkgMacOS.appendingPathComponent("TestApp"), byteCount: 40_960)
        try fm.createSymbolicLink(at: sandbox.appendingPathComponent("sym-top"), withDestinationURL: sandbox.appendingPathComponent("top-big.bin"))

        let sg = SafetyGuard(homeDirectory: sandbox)
        let analyzer = DiskSpaceAnalyzer(safetyGuard: sg)
        let tree = try runAsync {
            try await analyzer.analyze(root: sandbox, maxDepth: 6)
        }

        for scope in DiskTreeFilterScope.allCases {
            for minBytes: UInt64 in [0, 16_384] {
                let filter = DiskEntryFilter(minBytes: minBytes, scope: scope, maxResults: 200)
                let treeMatches = DiskSpaceAnalyzer.filterNodes(in: tree, filter: filter)
                let deepMatches = try runAsync {
                    try await analyzer.findMatchingFiles(under: sandbox, filter: filter)
                }

                try runner.expectEqual(deepMatches.count, treeMatches.count)
                try runner.expectEqual(deepMatches.map(\.id), treeMatches.map(\.id))
                try runner.expectEqual(deepMatches.map(\.relativePathFromRoot), treeMatches.map(\.relativePathFromRoot))
                try runner.expectEqual(deepMatches.map(\.bytes), treeMatches.map(\.bytes))
                try runner.expectEqual(deepMatches.map(\.isDirectory), treeMatches.map(\.isDirectory))
                try runner.expectEqual(deepMatches.map(\.isPackage), treeMatches.map(\.isPackage))
                try runner.expectEqual(deepMatches.map(\.expectedCanonicalParent), treeMatches.map(\.expectedCanonicalParent))

                if scope == .filesOnly {
                    try runner.expect(!deepMatches.contains { $0.url.path.contains("TestApp.app") })
                }
                if scope == .allItems && minBytes == 16_384 {
                    try runner.expect(deepMatches.contains { $0.relativePathFromRoot == "FolderA" && $0.isDirectory && !$0.isPackage })
                    try runner.expect(deepMatches.contains { $0.relativePathFromRoot == "FolderA/Sub" && $0.isDirectory && !$0.isPackage })
                    try runner.expect(!deepMatches.contains { $0.relativePathFromRoot == "EmptyDir" })
                    try runner.expect(!deepMatches.contains { $0.relativePathFromRoot == "tiny.txt" })
                }
            }
        }
    }

    runner.run("DiskSpaceAnalyzer skips /System/Volumes/Data mountpoint identically in bulkOnly and fallbackOnly") {
        let volumesURL = URL(fileURLWithPath: "/System/Volumes")
        guard FileManager.default.fileExists(atPath: volumesURL.path) else { return }

        let bulkAnalyzer = DiskSpaceAnalyzer(maxTotalEntries: 25, enumerationMode: .bulkOnly)
        let fallbackAnalyzer = DiskSpaceAnalyzer(maxTotalEntries: 25, enumerationMode: .fallbackOnly)

        let bulkTree = try runAsync {
            try await bulkAnalyzer.analyze(root: volumesURL, maxDepth: 1)
        }
        let fallbackTree = try runAsync {
            try await fallbackAnalyzer.analyze(root: volumesURL, maxDepth: 1)
        }

        try runner.expect(!bulkTree.children.contains { $0.name == "Data" })
        try runner.expect(!fallbackTree.children.contains { $0.name == "Data" })
        try runner.expectEqual(fallbackTree.children.map(\.name), bulkTree.children.map(\.name))

        let filter = DiskEntryFilter(minBytes: 0, scope: .allItems, maxResults: 25)
        let bulkFind = try runAsync {
            try await bulkAnalyzer.findMatchingFiles(under: volumesURL, filter: filter)
        }
        let fallbackFind = try runAsync {
            try await fallbackAnalyzer.findMatchingFiles(under: volumesURL, filter: filter)
        }

        try runner.expect(!bulkFind.contains { $0.relativePathFromRoot == "Data" || $0.relativePathFromRoot.hasPrefix("Data/") })
        try runner.expect(!fallbackFind.contains { $0.relativePathFromRoot == "Data" || $0.relativePathFromRoot.hasPrefix("Data/") })
        try runner.expectEqual(fallbackFind.map(\.relativePathFromRoot), bulkFind.map(\.relativePathFromRoot))
    }

    runner.run("DiskSpaceAnalyzer maxDepth 0 throws permissionDenied on 0o000 root, succeeds on readable root, and maxTotalEntries truncates cleanly") {
        let sandbox = try runner.makeTempSandbox(prefix: "fm-depth0-cap")
        let fm = FileManager.default
        let locked = sandbox.appendingPathComponent("Locked000")
        let readable = sandbox.appendingPathComponent("Readable")
        let deep = readable.appendingPathComponent("A/B/C")
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        let _ = try writeExactFile(at: readable.appendingPathComponent("top.bin"), byteCount: 4096)
        let _ = try writeExactFile(at: deep.appendingPathComponent("deep.bin"), byteCount: 8192)
        for i in 0..<8 {
            _ = try writeExactFile(at: readable.appendingPathComponent("f\(i).bin"), byteCount: 4096)
        }
        try runner.expectEqual(Darwin.chmod(locked.path, 0o000), 0)
        defer {
            _ = Darwin.chmod(locked.path, 0o755)
            try? fm.removeItem(at: sandbox)
        }

        let sg = SafetyGuard(homeDirectory: sandbox)
        let analyzer = DiskSpaceAnalyzer(safetyGuard: sg)

        // 1. maxDepth: 0 on 0o000 root must throw DiskScanError.permissionDenied (matching maxDepth >= 1)
        var threw0 = false
        do {
            _ = try runAsync { try await analyzer.analyze(root: locked, maxDepth: 0) }
        } catch DiskScanError.permissionDenied {
            threw0 = true
        }
        try runner.expect(threw0, "maxDepth: 0 on 0o000 root must throw DiskScanError.permissionDenied")

        var threw1 = false
        do {
            _ = try runAsync { try await analyzer.analyze(root: locked, maxDepth: 1) }
        } catch DiskScanError.permissionDenied {
            threw1 = true
        }
        try runner.expect(threw1, "maxDepth: 1 on 0o000 root must throw DiskScanError.permissionDenied")

        // 2. maxDepth: 0 on readable root returns collapsed tree
        let collapsed = try runAsync { try await analyzer.analyze(root: readable, maxDepth: 0) }
        try runner.expect(collapsed.isAccessible)
        try runner.expect(collapsed.children.isEmpty)
        try runner.expect(collapsed.bytes >= 4096 * 9)

        // 3. maxTotalEntries truncation on deep tree
        let cappedAnalyzer = DiskSpaceAnalyzer(safetyGuard: sg, maxTotalEntries: 3)
        let cappedRoot = try runAsync { try await cappedAnalyzer.analyze(root: readable, maxDepth: 6) }
        try runner.expect(cappedRoot.isTruncated, "maxTotalEntries=3 must mark tree isTruncated=true")
        try runner.expect(cappedRoot.fileCount + cappedRoot.folderCount <= 4, "Truncated scan must stop near maxTotalEntries")
    }

    runner.run("DiskSpaceAnalyzer survives transient ENOENT child directory deletion mid-scan in analyze and findMatchingFiles") {
        let sandbox = try runner.makeTempSandbox(prefix: "fm-enoent-race")
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let fm = FileManager.default
        let keepDir = sandbox.appendingPathComponent("Keep")
        let vanishDir = sandbox.appendingPathComponent("VanishMidScan")
        try fm.createDirectory(at: keepDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: vanishDir, withIntermediateDirectories: true)
        _ = try writeExactFile(at: keepDir.appendingPathComponent("keep.bin"), byteCount: 16_384)
        _ = try writeExactFile(at: vanishDir.appendingPathComponent("vanish.bin"), byteCount: 8_192)

        final class DeleteOnceBox: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            let target: URL
            init(target: URL) { self.target = target }
            func trigger() {
                let shouldRemove = lock.withLock { () -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if shouldRemove {
                    try? FileManager.default.removeItem(at: target)
                }
            }
        }
        let trigger = DeleteOnceBox(target: vanishDir)
        let analyzer = DiskSpaceAnalyzer(
            safetyGuard: SafetyGuard(homeDirectory: sandbox),
            progressThrottleInterval: 0.0,
            statProvider: { path in
                if path == vanishDir.path {
                    trigger.trigger()
                }
                var st = stat()
                return Darwin.lstat(path, &st) == 0 ? st : nil
            }
        )

        let tree = try runAsync { try await analyzer.analyze(root: sandbox, maxDepth: 4) }
        try runner.expect(tree.children.contains(where: { $0.name == "Keep" }), "Scan must survive vanished child directory")

        // Recreate vanishDir and trigger deletion during findMatchingFiles
        try fm.createDirectory(at: vanishDir, withIntermediateDirectories: true)
        _ = try writeExactFile(at: vanishDir.appendingPathComponent("vanish2.bin"), byteCount: 8_192)
        let trigger2 = DeleteOnceBox(target: vanishDir)
        let analyzer2 = DiskSpaceAnalyzer(
            safetyGuard: SafetyGuard(homeDirectory: sandbox),
            progressThrottleInterval: 0.0,
            statProvider: { path in
                if path == vanishDir.path {
                    trigger2.trigger()
                }
                var st = stat()
                return Darwin.lstat(path, &st) == 0 ? st : nil
            }
        )
        let matches = try runAsync {
            try await analyzer2.findMatchingFiles(under: sandbox, filter: DiskEntryFilter(minBytes: 4096))
        }
        try runner.expect(matches.contains(where: { $0.name == "keep.bin" }), "findMatchingFiles must survive vanished child directory")
    }

    runner.run("FileBrowserService handles valid, broken, and 0o000 symlinks plus invalid UTF-8 / C0 hexDump and 4-byte emoji truncation") {
        let sandbox = try runner.makeTempSandbox(prefix: "fm-adv-browser")
        let fm = FileManager.default
        let targetDir = sandbox.appendingPathComponent("TargetDir")
        let lockedTarget = sandbox.appendingPathComponent("LockedTarget.txt")
        let validLink = sandbox.appendingPathComponent("valid-link")
        let brokenLink = sandbox.appendingPathComponent("broken-link")
        let lockedLink = sandbox.appendingPathComponent("locked-link")
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: lockedTarget)
        try runner.expectEqual(Darwin.chmod(lockedTarget.path, 0o000), 0)
        defer {
            _ = Darwin.chmod(lockedTarget.path, 0o644)
            try? fm.removeItem(at: sandbox)
        }

        try fm.createSymbolicLink(at: validLink, withDestinationURL: targetDir)
        try fm.createSymbolicLink(at: brokenLink, withDestinationURL: sandbox.appendingPathComponent("does-not-exist"))
        try fm.createSymbolicLink(at: lockedLink, withDestinationURL: lockedTarget)

        let invalidUTF8URL = sandbox.appendingPathComponent("bad-utf8.dat")
        try Data([0xFF, 0xFE, 0x80, 0x81, 0x90]).write(to: invalidUTF8URL)

        let c0ControlURL = sandbox.appendingPathComponent("c0-control.dat")
        try Data([0x01, 0x02, 0x03, 0x04, 0x41, 0x42]).write(to: c0ControlURL)

        let emojiURL = sandbox.appendingPathComponent("emoji.txt")
        try Data("😀🎉🚀".utf8).write(to: emojiURL)

        let service = FileBrowserService(safetyGuard: SafetyGuard(homeDirectory: sandbox))
        let entries = try service.listDirectory(at: sandbox, showHidden: true, sortBy: .name, ascending: true)

        let validEntry = entries.first(where: { $0.name == "valid-link" })
        let brokenEntry = entries.first(where: { $0.name == "broken-link" })
        let lockedEntry = entries.first(where: { $0.name == "locked-link" })
        try runner.expectEqual(validEntry?.isSymbolicLink, true)
        try runner.expectEqual(validEntry?.isSymlinkBroken, false)
        try runner.expectEqual(brokenEntry?.isSymbolicLink, true)
        try runner.expectEqual(brokenEntry?.isSymlinkBroken, true)
        try runner.expectEqual(lockedEntry?.isSymbolicLink, true)

        let invalidPayload = try service.loadPreview(at: invalidUTF8URL)
        if case .hexDump = invalidPayload.content {} else {
            try runner.expect(false, "Invalid non-NUL UTF-8 bytes must fall back to .hexDump")
        }

        let c0Payload = try service.loadPreview(at: c0ControlURL)
        if case .hexDump = c0Payload.content {} else {
            try runner.expect(false, ">5% C0 control bytes must fall back to .hexDump")
        }

        for limit in [1, 2, 3, 4] {
            let emojiPayload = try service.loadPreview(at: emojiURL, maxTextBytes: limit)
            if case let .text(text, _, isTruncated, _) = emojiPayload.content {
                try runner.expect(isTruncated)
                try runner.expect(text.utf8.count <= limit, "UTF-8 truncation at maxTextBytes=\(limit) must not split 4-byte emoji")
            } else {
                try runner.expect(false, "Expected .text preview for emoji file at maxTextBytes=\(limit)")
            }
        }
    }
}

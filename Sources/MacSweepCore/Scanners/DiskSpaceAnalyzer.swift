import Darwin
import Foundation

public struct DiskSpaceAnalyzer: Sendable {
    internal typealias StatProvider = @Sendable (_ path: String) -> stat?

    internal enum EnumerationMode: Sendable {
        case automatic
        case bulkOnly
        case fallbackOnly
    }

    public let safetyGuard: SafetyGuard
    public let maxChildrenPerDirectory: Int
    public let progressThrottleInterval: TimeInterval
    public let maxTotalEntries: Int?
    public let includeHiddenFiles: Bool

    private let statProvider: StatProvider?
    private let enumerationMode: EnumerationMode

    private static let kernelSIPFlagMask = UInt32(SF_RESTRICTED) | UInt32(SF_IMMUTABLE) | UInt32(SF_NOUNLINK)
    private static let rootVirtualAndFirmlinkNames: Set<String> = [".vol", ".nofollow", ".resolve", "dev", "Volumes"]
    private static let bulkBufferSize = 128 * 1024

    public init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        maxChildrenPerDirectory: Int = 200,
        progressThrottleInterval: TimeInterval = 0.10,
        maxTotalEntries: Int? = nil,
        includeHiddenFiles: Bool = true
    ) {
        self.safetyGuard = safetyGuard
        self.maxChildrenPerDirectory = max(1, maxChildrenPerDirectory)
        self.progressThrottleInterval = max(0.01, progressThrottleInterval)
        self.maxTotalEntries = maxTotalEntries.map { max(1, $0) }
        self.includeHiddenFiles = includeHiddenFiles
        self.statProvider = nil
        self.enumerationMode = .automatic
    }

    internal init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        maxChildrenPerDirectory: Int = 200,
        progressThrottleInterval: TimeInterval = 0.10,
        maxTotalEntries: Int? = nil,
        includeHiddenFiles: Bool = true,
        statProvider: StatProvider? = nil,
        enumerationMode: EnumerationMode = .automatic
    ) {
        self.safetyGuard = safetyGuard
        self.maxChildrenPerDirectory = max(1, maxChildrenPerDirectory)
        self.progressThrottleInterval = max(0.01, progressThrottleInterval)
        self.maxTotalEntries = maxTotalEntries.map { max(1, $0) }
        self.includeHiddenFiles = includeHiddenFiles
        self.statProvider = statProvider
        self.enumerationMode = enumerationMode
    }

    // MARK: - Public Analysis API

    public func analyze(
        root: URL,
        maxDepth: Int = 5,
        onProgress: @escaping @Sendable (DiskScanProgress) -> Void = { _ in }
    ) async throws -> DiskTreeNode {
        try await analyzeInternal(
            root: root,
            maxDepth: maxDepth,
            onPartialTree: nil,
            onProgress: onProgress
        )
    }

    public func analyze(
        root: URL,
        maxDepth: Int = 5,
        onPartialTree: @escaping @Sendable (DiskTreeNode) -> Void,
        onProgress: @escaping @Sendable (DiskScanProgress) -> Void = { _ in }
    ) async throws -> DiskTreeNode {
        try await analyzeInternal(
            root: root,
            maxDepth: maxDepth,
            onPartialTree: onPartialTree,
            onProgress: onProgress
        )
    }

    private func analyzeInternal(
        root: URL,
        maxDepth: Int,
        onPartialTree: (@Sendable (DiskTreeNode) -> Void)?,
        onProgress: @escaping @Sendable (DiskScanProgress) -> Void
    ) async throws -> DiskTreeNode {
        let stdRoot = try Self.validateRootURL(root)
        let effectiveMaxDepth = max(0, maxDepth)
        let cancelFlag = CancellationFlag()
        let analyzer = self

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let node = try analyzer.analyzeSync(
                            root: stdRoot,
                            maxDepth: effectiveMaxDepth,
                            cancelFlag: cancelFlag,
                            onPartialTree: onPartialTree,
                            onProgress: onProgress
                        )
                        continuation.resume(returning: node)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    public func findMatchingFiles(
        under root: URL,
        filter: DiskEntryFilter,
        referenceDate: Date = Date(),
        onProgress: @escaping @Sendable (DiskScanProgress) -> Void = { _ in }
    ) async throws -> [DiskFilteredItem] {
        let stdRoot = try Self.validateRootURL(root)
        let cancelFlag = CancellationFlag()
        let analyzer = self

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let items = try analyzer.findMatchingFilesSync(
                            root: stdRoot,
                            filter: filter,
                            referenceDate: referenceDate,
                            cancelFlag: cancelFlag,
                            onProgress: onProgress
                        )
                        continuation.resume(returning: items)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    // MARK: - Volume Capacity & Tree Filtering Helpers

    public static func volumeInfo(for url: URL) throws -> VolumeStorageInfo {
        let rawPath = url.path
        guard url.isFileURL,
              !rawPath.isEmpty,
              !rawPath.contains("\0"),
              !SafetyGuard.hasDotDotPathComponent(url) else {
            throw DiskScanError.invalidPath(path: rawPath)
        }
        let stdURL = url.standardizedFileURL

        var st = stat()
        if lstat(stdURL.path, &st) != 0 {
            let err = errno
            if err == ENOENT { throw DiskScanError.notFound(path: stdURL.path) }
            if err == EACCES || err == EPERM { throw DiskScanError.permissionDenied(path: stdURL.path) }
            throw DiskScanError.posixError(code: err, path: stdURL.path, detail: String(cString: strerror(err)))
        }

        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsReadOnlyKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeURLKey,
        ]
        let values = try? stdURL.resourceValues(forKeys: keys)

        var sfs = statfs()
        let hasStatFS = (statfs(stdURL.path, &sfs) == 0)

        let volumeURL = values?.volume ?? (hasStatFS ? URL(fileURLWithPath: Self.cStringPath(&sfs.f_mntonname)) : stdURL)
        let name = values?.volumeName ?? (volumeURL.path == "/" ? "Macintosh HD" : volumeURL.lastPathComponent)

        let totalBytes: UInt64
        if let total = values?.volumeTotalCapacity, total > 0 {
            totalBytes = UInt64(total)
        } else if hasStatFS {
            totalBytes = UInt64(sfs.f_blocks) &* UInt64(sfs.f_bsize)
        } else {
            totalBytes = 0
        }

        let availableBytes: UInt64
        if let availImportant = values?.volumeAvailableCapacityForImportantUsage, availImportant >= 0 {
            availableBytes = min(totalBytes, UInt64(availImportant))
        } else if let avail = values?.volumeAvailableCapacity, avail >= 0 {
            availableBytes = min(totalBytes, UInt64(avail))
        } else if hasStatFS {
            availableBytes = min(totalBytes, UInt64(sfs.f_bavail) &* UInt64(sfs.f_bsize))
        } else {
            availableBytes = 0
        }

        let usedBytes = totalBytes > availableBytes ? (totalBytes - availableBytes) : 0
        let fsType = values?.volumeLocalizedFormatDescription ?? (hasStatFS ? Self.cStringPath(&sfs.f_fstypename) : nil)

        return VolumeStorageInfo(
            url: volumeURL,
            name: name,
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            usedBytes: usedBytes,
            isInternal: values?.volumeIsInternal ?? true,
            isRemovable: values?.volumeIsRemovable ?? false,
            isReadOnly: values?.volumeIsReadOnly ?? (hasStatFS && (UInt32(sfs.f_flags) & UInt32(MNT_RDONLY)) != 0),
            fileSystemType: fsType
        )
    }

    public static func mountedVolumes() -> [VolumeStorageInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
            .volumeIsInternalKey,
            .volumeIsRemovableKey,
            .volumeIsReadOnlyKey,
            .volumeLocalizedFormatDescriptionKey,
            .volumeURLKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        var infos: [VolumeStorageInfo] = []
        var seen = Set<String>()
        for url in urls {
            guard let info = try? volumeInfo(for: url) else { continue }
            if seen.insert(info.id).inserted {
                infos.append(info)
            }
        }
        infos.sort { lhs, rhs in
            if lhs.id == "/" && rhs.id != "/" { return true }
            if rhs.id == "/" && lhs.id != "/" { return false }
            if lhs.isInternal != rhs.isInternal { return lhs.isInternal && !rhs.isInternal }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return infos
    }

    public static func filterNodes(
        in root: DiskTreeNode,
        filter: DiskEntryFilter,
        referenceDate: Date = Date()
    ) -> [DiskFilteredItem] {
        let cutoffDate: Date? = filter.olderThanDays.flatMap { days in
            days > 0 ? referenceDate.addingTimeInterval(-TimeInterval(days) * 86_400) : nil
        }
        let query = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootPath = root.url.path

        var results: [DiskFilteredItem] = []
        var stack: [(node: DiskTreeNode, ancestorHidden: Bool)] = root.children.reversed().map { ($0, false) }

        while let frame = stack.popLast() {
            let node = frame.node
            if !filter.includeHiddenFiles && node.isHidden {
                continue
            }
            let effectiveHidden = node.isHidden || frame.ancestorHidden

            if !node.isSymlink {
                let relativePath = Self.relativePath(of: node.url.path, under: rootPath)
                let scopeMatches: Bool
                switch filter.scope {
                case .filesOnly:
                    scopeMatches = !node.isDirectory
                case .filesAndPackages:
                    scopeMatches = !node.isDirectory || node.isPackage
                case .allItems:
                    scopeMatches = true
                }

                if scopeMatches,
                   node.bytes >= filter.minBytes,
                   !(filter.excludeProtected && node.isProtected),
                   Self.matchesAge(
                       modDate: node.modificationDate,
                       accDate: node.accessDate,
                       cutoffDate: cutoffDate,
                       basis: filter.ageBasis
                   ),
                   Self.matchesSearch(name: node.name, relativePath: relativePath, query: query) {
                    results.append(DiskFilteredItem(
                        url: node.url,
                        name: node.name,
                        isDirectory: node.isDirectory,
                        isPackage: node.isPackage,
                        bytes: node.bytes,
                        modificationDate: node.modificationDate,
                        accessDate: node.accessDate,
                        expectedCanonicalParent: node.expectedCanonicalParent,
                        isProtected: node.isProtected,
                        isUserImmutable: node.isUserImmutable,
                        isHidden: effectiveHidden,
                        relativePathFromRoot: relativePath
                    ))
                }
            }

            if node.isDirectory && !node.isPackage && !node.children.isEmpty {
                for child in node.children.reversed() {
                    stack.append((child, effectiveHidden))
                }
            }
        }

        results.sort { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            let cmp = lhs.name.localizedStandardCompare(rhs.name)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return lhs.relativePathFromRoot < rhs.relativePathFromRoot
        }
        if results.count > filter.maxResults {
            return Array(results.prefix(filter.maxResults))
        }
        return results
    }

    // MARK: - Core Traversal Implementation

    private struct FileInodeKey: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    private struct RawDirEntry {
        let name: String
        let objType: UInt32 // VREG, VDIR, VLNK, etc.
        let dev: dev_t
        let modDate: Date?
        let accDate: Date?
        let flags: UInt32
        let fileID: UInt64
        let dirMountStatus: UInt32
        let linkCount: UInt32
        let allocSize: Int64
        let dataLength: Int64
    }

    private final class BulkReadScratch {
        let buffer: UnsafeMutableRawBufferPointer

        init(capacity: Int = DiskSpaceAnalyzer.bulkBufferSize) {
            self.buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: capacity, alignment: 16)
        }

        deinit {
            buffer.deallocate()
        }
    }

    private final class SharedHardlinkTable: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = Set<FileInodeKey>()

        func insertIfNew(_ key: FileInodeKey) -> Bool {
            lock.lock()
            let inserted = seen.insert(key).inserted
            lock.unlock()
            return inserted
        }
    }

    private final class SharedProgressTracker: @unchecked Sendable {
        private let lock = NSLock()
        private let startTime: CFAbsoluteTime
        private let throttleInterval: TimeInterval
        private let onProgress: @Sendable (DiskScanProgress) -> Void

        private var scannedFiles: Int = 0
        private var scannedFolders: Int = 0
        private var totalBytes: UInt64 = 0
        private var skippedSymlinks: Int = 0
        private var skippedDataless: Int = 0
        private var skippedCrossVolume: Int = 0
        private var deduplicatedHardlinks: Int = 0
        private var lastEmitTime: CFAbsoluteTime

        init(
            startTime: CFAbsoluteTime,
            throttleInterval: TimeInterval,
            onProgress: @escaping @Sendable (DiskScanProgress) -> Void
        ) {
            self.startTime = startTime
            self.throttleInterval = throttleInterval
            self.onProgress = onProgress
            self.lastEmitTime = startTime
        }

        func addDelta(
            files: Int,
            folders: Int,
            bytes: UInt64,
            skippedSymlinks: Int,
            skippedDataless: Int,
            skippedCrossVolume: Int,
            deduplicatedHardlinks: Int,
            currentPath: String
        ) {
            var payload: DiskScanProgress?
            lock.lock()
            self.scannedFiles += files
            self.scannedFolders += folders
            self.totalBytes &+= bytes
            self.skippedSymlinks += skippedSymlinks
            self.skippedDataless += skippedDataless
            self.skippedCrossVolume += skippedCrossVolume
            self.deduplicatedHardlinks += deduplicatedHardlinks
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastEmitTime >= throttleInterval {
                lastEmitTime = now
                payload = DiskScanProgress(
                    scannedFiles: self.scannedFiles,
                    scannedFolders: self.scannedFolders,
                    totalBytes: self.totalBytes,
                    currentPath: currentPath,
                    elapsedSeconds: max(0, now - startTime),
                    skippedSymlinks: self.skippedSymlinks,
                    skippedDataless: self.skippedDataless,
                    skippedCrossVolume: self.skippedCrossVolume,
                    deduplicatedHardlinks: self.deduplicatedHardlinks
                )
            }
            lock.unlock()
            if let payload {
                onProgress(payload)
            }
        }

        func emitFinal(currentPath: String) {
            lock.lock()
            let now = CFAbsoluteTimeGetCurrent()
            let payload = DiskScanProgress(
                scannedFiles: self.scannedFiles,
                scannedFolders: self.scannedFolders,
                totalBytes: self.totalBytes,
                currentPath: currentPath,
                elapsedSeconds: max(0, now - startTime),
                skippedSymlinks: self.skippedSymlinks,
                skippedDataless: self.skippedDataless,
                skippedCrossVolume: self.skippedCrossVolume,
                deduplicatedHardlinks: self.deduplicatedHardlinks
            )
            lock.unlock()
            onProgress(payload)
        }
    }

    private struct ScanSession {
        let rootPath: String
        let rootDevice: dev_t
        let maxDepth: Int
        let startTime: CFAbsoluteTime
        let onProgress: @Sendable (DiskScanProgress) -> Void
        let progressThrottleInterval: TimeInterval
        let maxTotalEntries: Int?
        let cancelFlag: CancellationFlag
        let scratch: BulkReadScratch
        let sharedHardlinks: SharedHardlinkTable?
        let sharedProgress: SharedProgressTracker?

        var seenHardlinks = Set<FileInodeKey>()
        var scannedFiles: Int = 0
        var scannedFolders: Int = 0
        var visitedEntries: Int = 0
        var totalBytes: UInt64 = 0
        var skippedSymlinks: Int = 0
        var skippedDataless: Int = 0
        var skippedCrossVolume: Int = 0
        var deduplicatedHardlinks: Int = 0
        var hitGlobalCap: Bool = false
        var lastEmitTime: CFAbsoluteTime = 0

        // Unflushed deltas when running inside a parallel worker
        var pendingFiles: Int = 0
        var pendingFolders: Int = 0
        var pendingBytes: UInt64 = 0
        var pendingSkippedSymlinks: Int = 0
        var pendingSkippedDataless: Int = 0
        var pendingSkippedCrossVolume: Int = 0
        var pendingDedupHardlinks: Int = 0

        mutating func insertHardlinkIfNew(_ key: FileInodeKey) -> Bool {
            if let sharedHardlinks {
                return sharedHardlinks.insertIfNew(key)
            }
            return seenHardlinks.insert(key).inserted
        }

        mutating func recordFile(bytes: UInt64) {
            scannedFiles += 1
            totalBytes &+= bytes
            if sharedProgress != nil {
                pendingFiles += 1
                pendingBytes &+= bytes
            }
        }

        mutating func recordFolder() {
            scannedFolders += 1
            if sharedProgress != nil {
                pendingFolders += 1
            }
        }

        mutating func recordSkippedSymlink() {
            skippedSymlinks += 1
            if sharedProgress != nil { pendingSkippedSymlinks += 1 }
        }

        mutating func recordSkippedDataless() {
            skippedDataless += 1
            if sharedProgress != nil { pendingSkippedDataless += 1 }
        }

        mutating func recordSkippedCrossVolume() {
            skippedCrossVolume += 1
            if sharedProgress != nil { pendingSkippedCrossVolume += 1 }
        }

        mutating func recordDedupHardlink() {
            deduplicatedHardlinks += 1
            if sharedProgress != nil { pendingDedupHardlinks += 1 }
        }

        mutating func flushSharedProgress(currentPath: String) {
            guard let sharedProgress else { return }
            if pendingFiles != 0 || pendingFolders != 0 || pendingBytes != 0
                || pendingSkippedSymlinks != 0 || pendingSkippedDataless != 0
                || pendingSkippedCrossVolume != 0 || pendingDedupHardlinks != 0 {
                sharedProgress.addDelta(
                    files: pendingFiles,
                    folders: pendingFolders,
                    bytes: pendingBytes,
                    skippedSymlinks: pendingSkippedSymlinks,
                    skippedDataless: pendingSkippedDataless,
                    skippedCrossVolume: pendingSkippedCrossVolume,
                    deduplicatedHardlinks: pendingDedupHardlinks,
                    currentPath: currentPath
                )
                pendingFiles = 0
                pendingFolders = 0
                pendingBytes = 0
                pendingSkippedSymlinks = 0
                pendingSkippedDataless = 0
                pendingSkippedCrossVolume = 0
                pendingDedupHardlinks = 0
            }
        }

        mutating func recordVisitedEntry(currentPath: String) throws {
            visitedEntries += 1
            if let cap = maxTotalEntries, visitedEntries > cap {
                hitGlobalCap = true
            }
            if (visitedEntries & 0x3F) == 0 {
                if cancelFlag.isCancelled || Task.isCancelled {
                    throw CancellationError()
                }
                if sharedProgress != nil {
                    if (visitedEntries & 0xFF) == 0 || progressThrottleInterval <= 0.02 {
                        flushSharedProgress(currentPath: currentPath)
                    }
                } else {
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - lastEmitTime >= progressThrottleInterval {
                        lastEmitTime = now
                        emitProgress(currentPath: currentPath, now: now)
                    }
                }
            }
        }

        func emitProgress(currentPath: String, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
            onProgress(DiskScanProgress(
                scannedFiles: scannedFiles,
                scannedFolders: scannedFolders,
                totalBytes: totalBytes,
                currentPath: currentPath,
                elapsedSeconds: max(0, now - startTime),
                skippedSymlinks: skippedSymlinks,
                skippedDataless: skippedDataless,
                skippedCrossVolume: skippedCrossVolume,
                deduplicatedHardlinks: deduplicatedHardlinks
            ))
        }
    }

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }

        func cancel() {
            lock.withLock { cancelled = true }
        }
    }

    private func analyzeSync(
        root stdRoot: URL,
        maxDepth: Int,
        cancelFlag: CancellationFlag,
        onPartialTree: (@Sendable (DiskTreeNode) -> Void)?,
        onProgress: @escaping @Sendable (DiskScanProgress) -> Void
    ) throws -> DiskTreeNode {
        let rootStat = try obtainStat(at: stdRoot.path)
        let rootMode = rootStat.st_mode & S_IFMT
        let rootParent = PrivilegedExecutor.canonicalParentPath(forTargetURL: stdRoot)
        let rootProtected = !safetyGuard.validateForRemoval(stdRoot).isAllowed
        let rootImmutable = (rootStat.st_flags & UInt32(UF_IMMUTABLE)) != 0
        let rootMod = Self.dateFromTimespec(rootStat.st_mtimespec)
        let rootAcc = Self.dateFromTimespec(rootStat.st_atimespec)
        let displayName = stdRoot.path == "/" ? "/" : stdRoot.lastPathComponent
        let rootHidden = Self.isEntryHidden(name: displayName, flags: rootStat.st_flags)

        if rootMode == S_IFLNK {
            return DiskTreeNode(
                url: stdRoot,
                name: displayName,
                isDirectory: false,
                isPackage: false,
                isSymlink: true,
                bytes: 0,
                fileCount: 0,
                folderCount: 0,
                modificationDate: rootMod,
                accessDate: rootAcc,
                children: [],
                isTruncated: false,
                isAccessible: true,
                isProtected: rootProtected,
                isUserImmutable: rootImmutable,
                isHidden: rootHidden,
                expectedCanonicalParent: rootParent
            )
        }

        if (rootStat.st_flags & UInt32(SF_DATALESS)) != 0 {
            return DiskTreeNode(
                url: stdRoot,
                name: displayName,
                isDirectory: rootMode == S_IFDIR,
                isPackage: false,
                isSymlink: false,
                bytes: 0,
                fileCount: 0,
                folderCount: 0,
                modificationDate: rootMod,
                accessDate: rootAcc,
                children: [],
                isTruncated: false,
                isAccessible: true,
                isProtected: rootProtected,
                isUserImmutable: rootImmutable,
                isHidden: rootHidden,
                expectedCanonicalParent: rootParent
            )
        }

        if rootMode != S_IFDIR {
            let fileBytes: UInt64
            if rootMode == S_IFREG {
                fileBytes = rootStat.st_blocks > 0
                    ? UInt64(rootStat.st_blocks) * 512
                    : UInt64(max(0, rootStat.st_size))
            } else {
                fileBytes = 0
            }
            let node = DiskTreeNode(
                url: stdRoot,
                name: displayName,
                isDirectory: false,
                isPackage: false,
                isSymlink: false,
                bytes: fileBytes,
                fileCount: rootMode == S_IFREG ? 1 : 0,
                folderCount: 0,
                modificationDate: rootMod,
                accessDate: rootAcc,
                children: [],
                isTruncated: false,
                isAccessible: true,
                isProtected: rootProtected,
                isUserImmutable: rootImmutable,
                isHidden: rootHidden,
                expectedCanonicalParent: rootParent
            )
            onProgress(DiskScanProgress(
                scannedFiles: node.fileCount,
                scannedFolders: 0,
                totalBytes: fileBytes,
                currentPath: stdRoot.path,
                elapsedSeconds: 0
            ))
            return node
        }

        // Parallel 2-level fan-out for unconstrained scans (no artificial entry cap or injected statProvider).
        if maxTotalEntries == nil && statProvider == nil && maxDepth >= 1 {
            return try analyzeRootParallel(
                stdRoot: stdRoot,
                displayName: displayName,
                rootDevice: rootStat.st_dev,
                rootMod: rootMod,
                rootAcc: rootAcc,
                rootImmutable: rootImmutable,
                rootHidden: rootHidden,
                rootProtected: rootProtected,
                rootParent: rootParent,
                maxDepth: maxDepth,
                cancelFlag: cancelFlag,
                onPartialTree: onPartialTree,
                onProgress: onProgress
            )
        }

        let scratch = BulkReadScratch()
        var session = ScanSession(
            rootPath: stdRoot.path,
            rootDevice: rootStat.st_dev,
            maxDepth: maxDepth,
            startTime: CFAbsoluteTimeGetCurrent(),
            onProgress: onProgress,
            progressThrottleInterval: progressThrottleInterval,
            maxTotalEntries: maxTotalEntries,
            cancelFlag: cancelFlag,
            scratch: scratch,
            sharedHardlinks: nil,
            sharedProgress: nil
        )
        session.lastEmitTime = session.startTime

        guard let rawRoot = try scanDirectory(
            dirURL: stdRoot,
            dirName: displayName,
            depth: 0,
            modDate: rootMod,
            accDate: rootAcc,
            isUserImmutable: rootImmutable,
            isHidden: rootHidden,
            expectedCanonicalParent: rootParent,
            isRootCall: true,
            session: &session
        ) else {
            throw DiskScanError.notFound(path: stdRoot.path)
        }

        let annotatedRoot = rawRoot.updatingProtection(using: safetyGuard)
        session.emitProgress(currentPath: stdRoot.path)
        return annotatedRoot
    }

    private func analyzeRootParallel(
        stdRoot: URL,
        displayName: String,
        rootDevice: dev_t,
        rootMod: Date?,
        rootAcc: Date?,
        rootImmutable: Bool,
        rootHidden: Bool,
        rootProtected: Bool,
        rootParent: String,
        maxDepth: Int,
        cancelFlag: CancellationFlag,
        onPartialTree: (@Sendable (DiskTreeNode) -> Void)?,
        onProgress: @escaping @Sendable (DiskScanProgress) -> Void
    ) throws -> DiskTreeNode {
        let startTime = CFAbsoluteTimeGetCurrent()
        let rootScratch = BulkReadScratch()
        let sharedHardlinks = SharedHardlinkTable()
        let sharedProgress = SharedProgressTracker(
            startTime: startTime,
            throttleInterval: progressThrottleInterval,
            onProgress: onProgress
        )

        let rootPath = stdRoot.path
        let rootIsPackage = Self.detectIsPackage(at: stdRoot)
        let rootEntries = try readDirectoryEntries(at: stdRoot, expectedDevice: rootDevice, scratch: rootScratch)
        let canonicalSelf = PrivilegedExecutor.canonicalParentPath(for: rootPath)

        struct TopDirSlot: Sendable {
            let url: URL
            let name: String
            let isPackage: Bool
            let modDate: Date?
            let accDate: Date?
            let isUserImmutable: Bool
            let isHidden: Bool
            let isProtected: Bool
            let canonicalSelf: String
            var directFiles: [DiskTreeNode]
            var directFileBytes: UInt64
            var directFileCount: Int
            var isAccessible: Bool
            var completedSubdirNodes: [DiskTreeNode]
            var pendingSubdirCount: Int
            var finishedNode: DiskTreeNode?
        }

        struct WorkUnit: Sendable {
            let topSlotIndex: Int
            let url: URL
            let name: String
            let depth: Int
            let modDate: Date?
            let accDate: Date?
            let isUserImmutable: Bool
            let isHidden: Bool
            let expectedCanonicalParent: String
        }

        var directRootFiles: [DiskTreeNode] = []
        var rootFileBytes: UInt64 = 0
        var rootFileCount = 0
        var topDirSlots: [TopDirSlot] = []
        var workUnits: [WorkUnit] = []

        var rootSkippedSymlinks = 0
        var rootSkippedDataless = 0
        var rootSkippedCrossVolume = 0
        var rootDedupHardlinks = 0
        var rootVisitedCount = 0

        for entry in rootEntries {
            if cancelFlag.isCancelled || Task.isCancelled {
                throw CancellationError()
            }
            rootVisitedCount += 1
            if Self.shouldSkipSpecialRootChild(name: entry.name, parentPath: rootPath, scanRootPath: rootPath) {
                rootSkippedCrossVolume += 1
                continue
            }
            if entry.objType == UInt32(VLNK.rawValue) {
                rootSkippedSymlinks += 1
                continue
            }
            if (entry.flags & UInt32(SF_DATALESS)) != 0 {
                rootSkippedDataless += 1
                continue
            }
            if entry.dev != rootDevice {
                rootSkippedCrossVolume += 1
                continue
            }
            if entry.objType == UInt32(VDIR.rawValue),
               (entry.dirMountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0 {
                rootSkippedCrossVolume += 1
                continue
            }

            let childHidden = Self.isEntryHidden(name: entry.name, flags: entry.flags)
            if !includeHiddenFiles && childHidden {
                continue
            }

            let childURL = stdRoot.appendingPathComponent(entry.name)
            let childImmutable = (entry.flags & UInt32(UF_IMMUTABLE)) != 0

            if entry.objType == UInt32(VREG.rawValue) {
                var fileBytes = entry.allocSize > 0
                    ? UInt64(entry.allocSize)
                    : UInt64(max(0, entry.dataLength))
                if entry.linkCount > 1 {
                    let key = FileInodeKey(dev: entry.dev, ino: ino_t(entry.fileID))
                    if !sharedHardlinks.insertIfNew(key) {
                        fileBytes = 0
                        rootDedupHardlinks += 1
                    }
                }
                rootFileBytes &+= fileBytes
                rootFileCount += 1
                sharedProgress.addDelta(
                    files: 1,
                    folders: 0,
                    bytes: fileBytes,
                    skippedSymlinks: 0,
                    skippedDataless: 0,
                    skippedCrossVolume: 0,
                    deduplicatedHardlinks: 0,
                    currentPath: rootPath
                )
                directRootFiles.append(DiskTreeNode(
                    url: childURL,
                    name: entry.name,
                    isDirectory: false,
                    isPackage: false,
                    isSymlink: false,
                    bytes: fileBytes,
                    fileCount: 1,
                    folderCount: 0,
                    modificationDate: entry.modDate,
                    accessDate: entry.accDate,
                    children: [],
                    isTruncated: false,
                    truncatedChildCount: 0,
                    isAccessible: true,
                    isProtected: false,
                    isUserImmutable: childImmutable,
                    isHidden: childHidden,
                    expectedCanonicalParent: canonicalSelf
                ))
            } else if entry.objType == UInt32(VDIR.rawValue) {
                let slotIdx = topDirSlots.count
                let childIsPkg = Self.detectIsPackage(at: childURL)
                let childProtected = !safetyGuard.validateForRemoval(childURL).isAllowed

                if maxDepth == 1 {
                    topDirSlots.append(TopDirSlot(
                        url: childURL,
                        name: entry.name,
                        isPackage: childIsPkg,
                        modDate: entry.modDate,
                        accDate: entry.accDate,
                        isUserImmutable: childImmutable,
                        isHidden: childHidden,
                        isProtected: childProtected,
                        canonicalSelf: "",
                        directFiles: [],
                        directFileBytes: 0,
                        directFileCount: 0,
                        isAccessible: true,
                        completedSubdirNodes: [],
                        pendingSubdirCount: 1,
                        finishedNode: nil
                    ))
                    workUnits.append(WorkUnit(
                        topSlotIndex: slotIdx,
                        url: childURL,
                        name: entry.name,
                        depth: 1,
                        modDate: entry.modDate,
                        accDate: entry.accDate,
                        isUserImmutable: childImmutable,
                        isHidden: childHidden,
                        expectedCanonicalParent: canonicalSelf
                    ))
                    sharedProgress.addDelta(
                        files: 0,
                        folders: 1,
                        bytes: 0,
                        skippedSymlinks: 0,
                        skippedDataless: 0,
                        skippedCrossVolume: 0,
                        deduplicatedHardlinks: 0,
                        currentPath: childURL.path
                    )
                } else {
                    // Expand one level down (depth 1 -> depth 2) so giant folders like ~/Library
                    // or ~/Projects fan out cleanly across all worker cores with zero deadlock risk.
                    let subEntries: [RawDirEntry]
                    do {
                        subEntries = try readDirectoryEntries(at: childURL, expectedDevice: rootDevice, scratch: rootScratch)
                    } catch let scanErr as DiskScanError {
                        switch scanErr {
                        case .permissionDenied:
                            let inaccessible = DiskTreeNode(
                                url: childURL,
                                name: entry.name,
                                isDirectory: true,
                                isPackage: childIsPkg,
                                isSymlink: false,
                                bytes: 0,
                                fileCount: 0,
                                folderCount: 0,
                                modificationDate: entry.modDate,
                                accessDate: entry.accDate,
                                children: [],
                                isTruncated: true,
                                truncatedChildCount: 0,
                                isAccessible: false,
                                isProtected: childProtected,
                                isUserImmutable: childImmutable,
                                isHidden: childHidden,
                                expectedCanonicalParent: canonicalSelf
                            )
                            topDirSlots.append(TopDirSlot(
                                url: childURL,
                                name: entry.name,
                                isPackage: childIsPkg,
                                modDate: entry.modDate,
                                accDate: entry.accDate,
                                isUserImmutable: childImmutable,
                                isHidden: childHidden,
                                isProtected: childProtected,
                                canonicalSelf: "",
                                directFiles: [],
                                directFileBytes: 0,
                                directFileCount: 0,
                                isAccessible: false,
                                completedSubdirNodes: [],
                                pendingSubdirCount: 0,
                                finishedNode: inaccessible
                            ))
                            sharedProgress.addDelta(
                                files: 0,
                                folders: 1,
                                bytes: 0,
                                skippedSymlinks: 0,
                                skippedDataless: 0,
                                skippedCrossVolume: 0,
                                deduplicatedHardlinks: 0,
                                currentPath: childURL.path
                            )
                            continue
                        case .notFound, .invalidPath:
                            continue
                        default:
                            throw scanErr
                        }
                    }

                    let subCanonicalSelf = PrivilegedExecutor.canonicalParentPath(for: childURL.path)
                    var subFiles: [DiskTreeNode] = []
                    var subFileBytes: UInt64 = 0
                    var subFileCount = 0
                    var subDirWorkCount = 0
                    var subSkipSym = 0
                    var subSkipDataless = 0
                    var subSkipXVol = 0
                    var subDedup = 0

                    for sub in subEntries {
                        rootVisitedCount += 1
                        if (rootVisitedCount & 0x3F) == 0, cancelFlag.isCancelled || Task.isCancelled {
                            throw CancellationError()
                        }
                        if Self.shouldSkipSpecialRootChild(name: sub.name, parentPath: childURL.path, scanRootPath: rootPath) {
                            subSkipXVol += 1
                            continue
                        }
                        if sub.objType == UInt32(VLNK.rawValue) {
                            subSkipSym += 1
                            continue
                        }
                        if (sub.flags & UInt32(SF_DATALESS)) != 0 {
                            subSkipDataless += 1
                            continue
                        }
                        if sub.dev != rootDevice {
                            subSkipXVol += 1
                            continue
                        }
                        if sub.objType == UInt32(VDIR.rawValue),
                           (sub.dirMountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0 {
                            subSkipXVol += 1
                            continue
                        }

                        let subHidden = Self.isEntryHidden(name: sub.name, flags: sub.flags)
                        if !includeHiddenFiles && subHidden {
                            continue
                        }

                        let subURL = childURL.appendingPathComponent(sub.name)
                        let subImmutable = (sub.flags & UInt32(UF_IMMUTABLE)) != 0

                        if sub.objType == UInt32(VREG.rawValue) {
                            var fileBytes = sub.allocSize > 0
                                ? UInt64(sub.allocSize)
                                : UInt64(max(0, sub.dataLength))
                            if sub.linkCount > 1 {
                                let key = FileInodeKey(dev: sub.dev, ino: ino_t(sub.fileID))
                                if !sharedHardlinks.insertIfNew(key) {
                                    fileBytes = 0
                                    subDedup += 1
                                }
                            }
                            subFileBytes &+= fileBytes
                            subFileCount += 1
                            subFiles.append(DiskTreeNode(
                                url: subURL,
                                name: sub.name,
                                isDirectory: false,
                                isPackage: false,
                                isSymlink: false,
                                bytes: fileBytes,
                                fileCount: 1,
                                folderCount: 0,
                                modificationDate: sub.modDate,
                                accessDate: sub.accDate,
                                children: [],
                                isTruncated: false,
                                truncatedChildCount: 0,
                                isAccessible: true,
                                isProtected: false,
                                isUserImmutable: subImmutable,
                                isHidden: subHidden,
                                expectedCanonicalParent: subCanonicalSelf
                            ))
                        } else if sub.objType == UInt32(VDIR.rawValue) {
                            subDirWorkCount += 1
                            workUnits.append(WorkUnit(
                                topSlotIndex: slotIdx,
                                url: subURL,
                                name: sub.name,
                                depth: 2,
                                modDate: sub.modDate,
                                accDate: sub.accDate,
                                isUserImmutable: subImmutable,
                                isHidden: subHidden,
                                expectedCanonicalParent: subCanonicalSelf
                            ))
                        }
                    }

                    sharedProgress.addDelta(
                        files: subFileCount,
                        folders: 1,
                        bytes: subFileBytes,
                        skippedSymlinks: subSkipSym,
                        skippedDataless: subSkipDataless,
                        skippedCrossVolume: subSkipXVol,
                        deduplicatedHardlinks: subDedup,
                        currentPath: childURL.path
                    )
                    if cancelFlag.isCancelled || Task.isCancelled {
                        throw CancellationError()
                    }

                    let finishedIfNoSubdirs: DiskTreeNode?
                    if subDirWorkCount == 0 {
                        subFiles.sort { lhs, rhs in
                            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                        }
                        let trunc = subFiles.count > maxChildrenPerDirectory
                        let kept = (trunc ? Array(subFiles.prefix(maxChildrenPerDirectory)) : subFiles)
                            .map { $0.updatingProtection(using: safetyGuard) }
                        finishedIfNoSubdirs = DiskTreeNode(
                            url: childURL,
                            name: entry.name,
                            isDirectory: true,
                            isPackage: childIsPkg,
                            isSymlink: false,
                            bytes: subFileBytes,
                            fileCount: subFileCount,
                            folderCount: 0,
                            modificationDate: entry.modDate,
                            accessDate: entry.accDate,
                            children: kept,
                            isTruncated: trunc,
                            truncatedChildCount: trunc ? (subFiles.count - maxChildrenPerDirectory) : 0,
                            isAccessible: true,
                            isProtected: childProtected,
                            isUserImmutable: childImmutable,
                            isHidden: childHidden,
                            expectedCanonicalParent: canonicalSelf
                        )
                    } else {
                        finishedIfNoSubdirs = nil
                    }

                    topDirSlots.append(TopDirSlot(
                        url: childURL,
                        name: entry.name,
                        isPackage: childIsPkg,
                        modDate: entry.modDate,
                        accDate: entry.accDate,
                        isUserImmutable: childImmutable,
                        isHidden: childHidden,
                        isProtected: childProtected,
                        canonicalSelf: subCanonicalSelf,
                        directFiles: subFiles,
                        directFileBytes: subFileBytes,
                        directFileCount: subFileCount,
                        isAccessible: true,
                        completedSubdirNodes: [],
                        pendingSubdirCount: subDirWorkCount,
                        finishedNode: finishedIfNoSubdirs
                    ))
                }
            }
        }

        // Flush any skipped counters accumulated at the root level.
        if rootSkippedSymlinks != 0 || rootSkippedDataless != 0 || rootSkippedCrossVolume != 0 || rootDedupHardlinks != 0 {
            sharedProgress.addDelta(
                files: 0,
                folders: 0,
                bytes: 0,
                skippedSymlinks: rootSkippedSymlinks,
                skippedDataless: rootSkippedDataless,
                skippedCrossVolume: rootSkippedCrossVolume,
                deduplicatedHardlinks: rootDedupHardlinks,
                currentPath: rootPath
            )
        }
        if cancelFlag.isCancelled || Task.isCancelled {
            throw CancellationError()
        }

        // Annotate direct root files once (typically tiny count).
        let annotatedDirectRootFiles = directRootFiles.map { $0.updatingProtection(using: safetyGuard) }
        let capturedRootFileBytes = rootFileBytes
        let capturedRootFileCount = rootFileCount
        let capturedMaxChildren = maxChildrenPerDirectory

        let buildSnapshot: @Sendable ([TopDirSlot], Bool) -> DiskTreeNode = { slots, isFinal in
            var allChildren: [DiskTreeNode] = annotatedDirectRootFiles
            allChildren.reserveCapacity(annotatedDirectRootFiles.count + slots.count)

            var totalBytes = capturedRootFileBytes
            var totalFiles = capturedRootFileCount
            var totalFolders = 0

            for slot in slots {
                if let finished = slot.finishedNode {
                    totalBytes &+= finished.bytes
                    totalFiles += finished.fileCount
                    totalFolders += 1 + finished.folderCount
                    allChildren.append(finished)
                } else {
                    // Progressive in-flight node for live UI updates.
                    var runningBytes = slot.directFileBytes
                    var runningFiles = slot.directFileCount
                    var runningFolders = 0
                    for sub in slot.completedSubdirNodes {
                        runningBytes &+= sub.bytes
                        runningFiles += sub.fileCount
                        runningFolders += 1 + sub.folderCount
                    }
                    totalBytes &+= runningBytes
                    totalFiles += runningFiles
                    totalFolders += 1 + runningFolders

                    var partialSubChildren = slot.directFiles + slot.completedSubdirNodes
                    partialSubChildren.sort { lhs, rhs in
                        if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                    }
                    if partialSubChildren.count > capturedMaxChildren {
                        partialSubChildren = Array(partialSubChildren.prefix(capturedMaxChildren))
                    }
                    allChildren.append(DiskTreeNode(
                        url: slot.url,
                        name: slot.name,
                        isDirectory: true,
                        isPackage: slot.isPackage,
                        isSymlink: false,
                        bytes: runningBytes,
                        fileCount: runningFiles,
                        folderCount: runningFolders,
                        modificationDate: slot.modDate,
                        accessDate: slot.accDate,
                        children: partialSubChildren,
                        isTruncated: false,
                        truncatedChildCount: 0,
                        isAccessible: slot.isAccessible,
                        isProtected: slot.isProtected,
                        isUserImmutable: slot.isUserImmutable,
                        isHidden: slot.isHidden,
                        expectedCanonicalParent: canonicalSelf
                    ))
                }
            }

            allChildren.sort { lhs, rhs in
                if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }

            let trunc = allChildren.count > capturedMaxChildren
            let kept = trunc ? Array(allChildren.prefix(capturedMaxChildren)) : allChildren
            _ = isFinal

            return DiskTreeNode(
                url: stdRoot,
                name: displayName,
                isDirectory: true,
                isPackage: rootIsPackage,
                isSymlink: false,
                bytes: totalBytes,
                fileCount: totalFiles,
                folderCount: totalFolders,
                modificationDate: rootMod,
                accessDate: rootAcc,
                children: kept,
                isTruncated: trunc,
                truncatedChildCount: trunc ? (allChildren.count - capturedMaxChildren) : 0,
                isAccessible: true,
                isProtected: rootProtected,
                isUserImmutable: rootImmutable,
                isHidden: rootHidden,
                expectedCanonicalParent: rootParent
            )
        }

        // Emit immediate skeleton snapshot (< 20 ms) so the UI renders top-level folders right away.
        if let onPartialTree {
            onPartialTree(buildSnapshot(topDirSlots, false))
        }

        if !workUnits.isEmpty {
            final class ParallelCoordinator: @unchecked Sendable {
                let lock = NSLock()
                var nextUnitIndex = 0
                var slots: [TopDirSlot]
                var firstError: Error?
                var lastPartialEmit: CFAbsoluteTime

                init(slots: [TopDirSlot]) {
                    self.slots = slots
                    self.lastPartialEmit = CFAbsoluteTimeGetCurrent()
                }
            }

            let coordinator = ParallelCoordinator(slots: topDirSlots)
            let partialThrottle: TimeInterval = 0.22
            let workerCount = min(workUnits.count, min(6, max(2, ProcessInfo.processInfo.activeProcessorCount)))
            let unitsCopy = workUnits
            let analyzer = self

            DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
                let workerScratch = BulkReadScratch()
                var workerSession = ScanSession(
                    rootPath: rootPath,
                    rootDevice: rootDevice,
                    maxDepth: maxDepth,
                    startTime: startTime,
                    onProgress: onProgress,
                    progressThrottleInterval: progressThrottleInterval,
                    maxTotalEntries: nil,
                    cancelFlag: cancelFlag,
                    scratch: workerScratch,
                    sharedHardlinks: sharedHardlinks,
                    sharedProgress: sharedProgress
                )

                while true {
                    if cancelFlag.isCancelled {
                        break
                    }
                    coordinator.lock.lock()
                    if coordinator.firstError != nil || coordinator.nextUnitIndex >= unitsCopy.count {
                        coordinator.lock.unlock()
                        break
                    }
                    let unit = unitsCopy[coordinator.nextUnitIndex]
                    coordinator.nextUnitIndex += 1
                    coordinator.lock.unlock()

                    do {
                        let rawNode = try analyzer.scanDirectory(
                            dirURL: unit.url,
                            dirName: unit.name,
                            depth: unit.depth,
                            modDate: unit.modDate,
                            accDate: unit.accDate,
                            isUserImmutable: unit.isUserImmutable,
                            isHidden: unit.isHidden,
                            expectedCanonicalParent: unit.expectedCanonicalParent,
                            isRootCall: false,
                            session: &workerSession
                        )
                        if rawNode != nil {
                            if unit.depth >= 2 {
                                workerSession.recordFolder()
                            }
                        }
                        workerSession.flushSharedProgress(currentPath: unit.url.path)

                        let annotatedNode = rawNode?.updatingProtection(using: analyzer.safetyGuard)
                        var partialToEmit: DiskTreeNode?

                        coordinator.lock.lock()
                        let slotIdx = unit.topSlotIndex
                        if unit.depth == 1 {
                            coordinator.slots[slotIdx].pendingSubdirCount = 0
                            if let annotatedNode {
                                coordinator.slots[slotIdx].finishedNode = annotatedNode
                            } else {
                                coordinator.slots[slotIdx].isAccessible = false
                            }
                        } else {
                            if let annotatedNode {
                                coordinator.slots[slotIdx].completedSubdirNodes.append(annotatedNode)
                            }
                            coordinator.slots[slotIdx].pendingSubdirCount -= 1
                            if coordinator.slots[slotIdx].pendingSubdirCount <= 0 {
                                let slot = coordinator.slots[slotIdx]
                                var combined = slot.directFiles + slot.completedSubdirNodes
                                combined.sort { lhs, rhs in
                                    if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                                }
                                let trunc = combined.count > capturedMaxChildren
                                let rawKept = trunc ? Array(combined.prefix(capturedMaxChildren)) : combined
                                let kept = rawKept.map { node in
                                    node.isDirectory ? node : node.updatingProtection(using: analyzer.safetyGuard)
                                }
                                let subBytes = slot.completedSubdirNodes.reduce(slot.directFileBytes) { $0 &+ $1.bytes }
                                let subFiles = slot.completedSubdirNodes.reduce(slot.directFileCount) { $0 + $1.fileCount }
                                let subFolders = slot.completedSubdirNodes.reduce(0) { $0 + 1 + $1.folderCount }

                                coordinator.slots[slotIdx].finishedNode = DiskTreeNode(
                                    url: slot.url,
                                    name: slot.name,
                                    isDirectory: true,
                                    isPackage: slot.isPackage,
                                    isSymlink: false,
                                    bytes: subBytes,
                                    fileCount: subFiles,
                                    folderCount: subFolders,
                                    modificationDate: slot.modDate,
                                    accessDate: slot.accDate,
                                    children: kept,
                                    isTruncated: trunc,
                                    truncatedChildCount: trunc ? (combined.count - capturedMaxChildren) : 0,
                                    isAccessible: slot.isAccessible,
                                    isProtected: slot.isProtected,
                                    isUserImmutable: slot.isUserImmutable,
                                    isHidden: slot.isHidden,
                                    expectedCanonicalParent: canonicalSelf
                                )
                                coordinator.slots[slotIdx].directFiles = []
                                coordinator.slots[slotIdx].completedSubdirNodes = []
                            }
                        }

                        if onPartialTree != nil {
                            let now = CFAbsoluteTimeGetCurrent()
                            if now - coordinator.lastPartialEmit >= partialThrottle {
                                coordinator.lastPartialEmit = now
                                partialToEmit = buildSnapshot(coordinator.slots, false)
                            }
                        }
                        coordinator.lock.unlock()

                        if let partialToEmit, let onPartialTree {
                            onPartialTree(partialToEmit)
                        }
                    } catch {
                        coordinator.lock.lock()
                        if coordinator.firstError == nil {
                            coordinator.firstError = error
                        }
                        coordinator.lock.unlock()
                        break
                    }
                }
            }

            if cancelFlag.isCancelled || Task.isCancelled {
                throw CancellationError()
            }
            if let firstError = coordinator.firstError {
                throw firstError
            }
            // Drop any depth-1 slot that vanished mid-scan when maxDepth == 1
            topDirSlots = coordinator.slots.filter { $0.finishedNode != nil }
        }

        let finalTree = buildSnapshot(topDirSlots, true)
        sharedProgress.emitFinal(currentPath: rootPath)
        return finalTree
    }

    private func scanDirectory(
        dirURL: URL,
        dirName: String,
        depth: Int,
        modDate: Date?,
        accDate: Date?,
        isUserImmutable: Bool,
        isHidden: Bool,
        expectedCanonicalParent: String,
        isRootCall: Bool,
        session: inout ScanSession
    ) throws -> DiskTreeNode? {
        if session.cancelFlag.isCancelled || Task.isCancelled {
            throw CancellationError()
        }

        let dirPath = dirURL.path
        let isPackage = Self.detectIsPackage(at: dirURL)

        if depth >= session.maxDepth {
            let collapsed = try measureCollapsedSubtree(
                at: dirURL,
                throwOnRootPermissionDenied: isRootCall,
                session: &session
            )
            if collapsed.rootVanished {
                return nil
            }
            return DiskTreeNode(
                url: dirURL,
                name: dirName,
                isDirectory: true,
                isPackage: isPackage,
                isSymlink: false,
                bytes: collapsed.bytes,
                fileCount: collapsed.fileCount,
                folderCount: collapsed.folderCount,
                modificationDate: modDate,
                accessDate: accDate,
                children: [],
                isTruncated: !collapsed.isAccessible || collapsed.hadAnyEntry || collapsed.hitGlobalCap,
                truncatedChildCount: 0,
                isAccessible: collapsed.isAccessible,
                isProtected: false,
                isUserImmutable: isUserImmutable,
                isHidden: isHidden,
                expectedCanonicalParent: expectedCanonicalParent
            )
        }

        let entries: [RawDirEntry]
        do {
            entries = try readDirectoryEntries(at: dirURL, expectedDevice: session.rootDevice, scratch: session.scratch)
        } catch let scanErr as DiskScanError {
            if !isRootCall {
                switch scanErr {
                case .permissionDenied:
                    return DiskTreeNode(
                        url: dirURL,
                        name: dirName,
                        isDirectory: true,
                        isPackage: isPackage,
                        isSymlink: false,
                        bytes: 0,
                        fileCount: 0,
                        folderCount: 0,
                        modificationDate: modDate,
                        accessDate: accDate,
                        children: [],
                        isTruncated: true,
                        truncatedChildCount: 0,
                        isAccessible: false,
                        isProtected: false,
                        isUserImmutable: isUserImmutable,
                        isHidden: isHidden,
                        expectedCanonicalParent: expectedCanonicalParent
                    )
                case .notFound, .invalidPath:
                    return nil
                default:
                    break
                }
            }
            throw scanErr
        }

        let canonicalSelf = PrivilegedExecutor.canonicalParentPath(for: dirPath)
        var allChildren: [DiskTreeNode] = []
        allChildren.reserveCapacity(min(entries.count, maxChildrenPerDirectory))

        var totalBytes: UInt64 = 0
        var totalFiles = 0
        var totalFolders = 0
        var hitCapHere = false

        for entry in entries {
            if session.hitGlobalCap {
                hitCapHere = true
                break
            }
            try session.recordVisitedEntry(currentPath: dirPath)
            if session.hitGlobalCap {
                hitCapHere = true
                break
            }

            if Self.shouldSkipSpecialRootChild(
                name: entry.name,
                parentPath: dirPath,
                scanRootPath: session.rootPath
            ) {
                session.recordSkippedCrossVolume()
                continue
            }

            if entry.objType == UInt32(VLNK.rawValue) {
                session.recordSkippedSymlink()
                continue
            }

            if (entry.flags & UInt32(SF_DATALESS)) != 0 {
                session.recordSkippedDataless()
                continue
            }

            if entry.dev != session.rootDevice {
                session.recordSkippedCrossVolume()
                continue
            }

            if entry.objType == UInt32(VDIR.rawValue),
               (entry.dirMountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0 {
                session.recordSkippedCrossVolume()
                continue
            }

            let childHidden = Self.isEntryHidden(name: entry.name, flags: entry.flags)
            if !includeHiddenFiles && childHidden {
                continue
            }

            let childURL = dirURL.appendingPathComponent(entry.name)
            let childImmutable = (entry.flags & UInt32(UF_IMMUTABLE)) != 0

            if entry.objType == UInt32(VREG.rawValue) {
                var fileBytes = entry.allocSize > 0
                    ? UInt64(entry.allocSize)
                    : UInt64(max(0, entry.dataLength))

                if entry.linkCount > 1 {
                    let key = FileInodeKey(dev: entry.dev, ino: ino_t(entry.fileID))
                    if !session.insertHardlinkIfNew(key) {
                        fileBytes = 0
                        session.recordDedupHardlink()
                    }
                }

                session.recordFile(bytes: fileBytes)
                totalBytes &+= fileBytes
                totalFiles += 1

                allChildren.append(DiskTreeNode(
                    url: childURL,
                    name: entry.name,
                    isDirectory: false,
                    isPackage: false,
                    isSymlink: false,
                    bytes: fileBytes,
                    fileCount: 1,
                    folderCount: 0,
                    modificationDate: entry.modDate,
                    accessDate: entry.accDate,
                    children: [],
                    isTruncated: false,
                    truncatedChildCount: 0,
                    isAccessible: true,
                    isProtected: false,
                    isUserImmutable: childImmutable,
                    isHidden: childHidden,
                    expectedCanonicalParent: canonicalSelf
                ))
            } else if entry.objType == UInt32(VDIR.rawValue) {
                if let childNode = try scanDirectory(
                    dirURL: childURL,
                    dirName: entry.name,
                    depth: depth + 1,
                    modDate: entry.modDate,
                    accDate: entry.accDate,
                    isUserImmutable: childImmutable,
                    isHidden: childHidden,
                    expectedCanonicalParent: canonicalSelf,
                    isRootCall: false,
                    session: &session
                ) {
                    session.recordFolder()
                    totalBytes &+= childNode.bytes
                    totalFiles += childNode.fileCount
                    totalFolders += 1 + childNode.folderCount
                    allChildren.append(childNode)
                }
                if session.hitGlobalCap {
                    hitCapHere = true
                }
            } else {
                // Skip FIFOs, sockets, char/block special files without opening.
                continue
            }
        }

        allChildren.sort { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        let truncatedByChildCap = allChildren.count > maxChildrenPerDirectory
        let truncatedCount = truncatedByChildCap ? (allChildren.count - maxChildrenPerDirectory) : 0
        let keptChildren = truncatedByChildCap ? Array(allChildren.prefix(maxChildrenPerDirectory)) : allChildren

        return DiskTreeNode(
            url: dirURL,
            name: dirName,
            isDirectory: true,
            isPackage: isPackage,
            isSymlink: false,
            bytes: totalBytes,
            fileCount: totalFiles,
            folderCount: totalFolders,
            modificationDate: modDate,
            accessDate: accDate,
            children: keptChildren,
            isTruncated: truncatedByChildCap || hitCapHere || session.hitGlobalCap,
            truncatedChildCount: truncatedCount,
            isAccessible: true,
            isProtected: false,
            isUserImmutable: isUserImmutable,
            isHidden: isHidden,
            expectedCanonicalParent: expectedCanonicalParent
        )
    }

    private func measureCollapsedSubtree(
        at rootDirURL: URL,
        throwOnRootPermissionDenied: Bool = false,
        includeHiddenOverride: Bool? = nil,
        session: inout ScanSession
    ) throws -> (bytes: UInt64, fileCount: Int, folderCount: Int, hadAnyEntry: Bool, hitGlobalCap: Bool, isAccessible: Bool, rootVanished: Bool) {
        let allowHidden = includeHiddenOverride ?? includeHiddenFiles
        let shouldUseBulk: Bool
        switch enumerationMode {
        case .automatic:
            shouldUseBulk = (statProvider == nil)
        case .bulkOnly:
            shouldUseBulk = true
        case .fallbackOnly:
            shouldUseBulk = false
        }

        var stack: [String] = [rootDirURL.path]
        var totalBytes: UInt64 = 0
        var totalFiles = 0
        var totalFolders = 0
        var hadAnyEntry = false
        var rootAccessible = true
        var rootVanished = false
        var isFirst = true

        var fastAlist = attrlist()
        fastAlist.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        fastAlist.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
            | UInt32(ATTR_CMN_NAME)
            | UInt32(ATTR_CMN_DEVID)
            | UInt32(ATTR_CMN_OBJTYPE)
            | UInt32(ATTR_CMN_FLAGS)
            | UInt32(ATTR_CMN_FILEID)
            | UInt32(ATTR_CMN_ERROR)
        fastAlist.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS)
        fastAlist.fileattr = UInt32(ATTR_FILE_LINKCOUNT)
            | UInt32(ATTR_FILE_ALLOCSIZE)
            | UInt32(ATTR_FILE_DATALENGTH)

        let rawBuf = session.scratch.buffer

        while let currentPath = stack.popLast() {
            if session.cancelFlag.isCancelled || Task.isCancelled {
                throw CancellationError()
            }
            if session.hitGlobalCap {
                return (totalBytes, totalFiles, totalFolders, hadAnyEntry, true, rootAccessible, rootVanished)
            }

            if shouldUseBulk {
                let fd = open(currentPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if fd < 0 {
                    let err = errno
                    if err == EACCES || err == EPERM {
                        if isFirst {
                            if throwOnRootPermissionDenied {
                                throw DiskScanError.permissionDenied(path: currentPath)
                            }
                            rootAccessible = false
                        }
                        isFirst = false
                        continue
                    }
                    if err == ENOENT || err == ELOOP || err == ENOTDIR {
                        if isFirst {
                            if throwOnRootPermissionDenied {
                                throw err == ENOENT
                                    ? DiskScanError.notFound(path: currentPath)
                                    : DiskScanError.invalidPath(path: currentPath)
                            }
                            rootVanished = true
                        }
                        isFirst = false
                        continue
                    }
                    throw DiskScanError.posixError(code: err, path: currentPath, detail: String(cString: strerror(err)))
                }

                var ownsFD = true
                defer {
                    if ownsFD { close(fd) }
                }

                if statProvider == nil {
                    var openedStat = stat()
                    if fstat(fd, &openedStat) == 0, openedStat.st_dev != session.rootDevice {
                        isFirst = false
                        continue
                    }
                }

                let needsSpecialRootCheck = (currentPath == "/" || currentPath == "/System/Volumes")
                let pathPrefix = currentPath == "/" ? "/" : (currentPath + "/")
                var firstBatch = true
                var fellBack = false

                while true {
                    let count = getattrlistbulk(fd, &fastAlist, rawBuf.baseAddress, rawBuf.count, 0)
                    if count == 0 { break }
                    if count < 0 {
                        let err = errno
                        if firstBatch && (err == ENOTSUP || err == EINVAL || err == ERANGE) {
                            if enumerationMode == .bulkOnly {
                                throw DiskScanError.posixError(code: ENOTSUP, path: currentPath, detail: "getattrlistbulk not supported")
                            }
                            fellBack = true
                            break
                        }
                        if err == EACCES || err == EPERM {
                            if isFirst {
                                if throwOnRootPermissionDenied {
                                    throw DiskScanError.permissionDenied(path: currentPath)
                                }
                                rootAccessible = false
                            }
                            break
                        }
                        if err == ENOENT {
                            if isFirst {
                                if throwOnRootPermissionDenied {
                                    throw DiskScanError.notFound(path: currentPath)
                                }
                                rootVanished = true
                            }
                            break
                        }
                        throw DiskScanError.posixError(code: err, path: currentPath, detail: String(cString: strerror(err)))
                    }
                    firstBatch = false

                    guard let base = rawBuf.baseAddress else { break }
                    var entryOffset = 0
                    for _ in 0..<Int(count) {
                        guard entryOffset + 4 <= rawBuf.count else { break }
                        let entryStart = base.advanced(by: entryOffset)
                        let entryLength = Int(entryStart.loadUnaligned(as: UInt32.self))
                        guard entryLength >= 4, entryOffset + entryLength <= rawBuf.count else { break }
                        entryOffset += entryLength

                        var cursor = entryStart.advanced(by: 4)
                        let entryEnd = entryStart.advanced(by: entryLength)

                        guard cursor.advanced(by: MemoryLayout<attribute_set_t>.size) <= entryEnd else { continue }
                        let returned = cursor.loadUnaligned(as: attribute_set_t.self)
                        cursor = cursor.advanced(by: MemoryLayout<attribute_set_t>.size)

                        var nameSliceStart: UnsafeRawPointer?
                        var nameSliceLen = 0
                        if (returned.commonattr & UInt32(ATTR_CMN_NAME)) != 0 {
                            guard cursor.advanced(by: MemoryLayout<attrreference_t>.size) <= entryEnd else { continue }
                            let refPtr = cursor
                            let nameRef = refPtr.loadUnaligned(as: attrreference_t.self)
                            cursor = cursor.advanced(by: MemoryLayout<attrreference_t>.size)
                            let strStart = refPtr.advanced(by: Int(nameRef.attr_dataoffset))
                            let strLen = Int(nameRef.attr_length)
                            if strStart >= entryStart && strStart.advanced(by: strLen) <= entryEnd && strLen > 0 {
                                nameSliceStart = UnsafeRawPointer(strStart)
                                nameSliceLen = strLen
                            }
                        }

                        var dev: dev_t = 0
                        if (returned.commonattr & UInt32(ATTR_CMN_DEVID)) != 0 {
                            guard cursor.advanced(by: MemoryLayout<dev_t>.size) <= entryEnd else { continue }
                            dev = cursor.loadUnaligned(as: dev_t.self)
                            cursor = cursor.advanced(by: MemoryLayout<dev_t>.size)
                        }

                        var objType: UInt32 = 0
                        if (returned.commonattr & UInt32(ATTR_CMN_OBJTYPE)) != 0 {
                            guard cursor.advanced(by: MemoryLayout<fsobj_type_t>.size) <= entryEnd else { continue }
                            objType = cursor.loadUnaligned(as: UInt32.self)
                            cursor = cursor.advanced(by: MemoryLayout<fsobj_type_t>.size)
                        }

                        var flags: UInt32 = 0
                        if (returned.commonattr & UInt32(ATTR_CMN_FLAGS)) != 0 {
                            guard cursor.advanced(by: MemoryLayout<UInt32>.size) <= entryEnd else { continue }
                            flags = cursor.loadUnaligned(as: UInt32.self)
                            cursor = cursor.advanced(by: MemoryLayout<UInt32>.size)
                        }

                        var fileID: UInt64 = 0
                        if (returned.commonattr & UInt32(ATTR_CMN_FILEID)) != 0 {
                            guard cursor.advanced(by: MemoryLayout<UInt64>.size) <= entryEnd else { continue }
                            fileID = cursor.loadUnaligned(as: UInt64.self)
                            cursor = cursor.advanced(by: MemoryLayout<UInt64>.size)
                        }

                        var entryError: UInt32 = 0
                        if (returned.commonattr & UInt32(ATTR_CMN_ERROR)) != 0 {
                            guard cursor.advanced(by: MemoryLayout<UInt32>.size) <= entryEnd else { continue }
                            entryError = cursor.loadUnaligned(as: UInt32.self)
                            cursor = cursor.advanced(by: MemoryLayout<UInt32>.size)
                        }

                        var dirMountStatus: UInt32 = 0
                        if (returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS)) != 0 {
                            guard cursor.advanced(by: MemoryLayout<UInt32>.size) <= entryEnd else { continue }
                            dirMountStatus = cursor.loadUnaligned(as: UInt32.self)
                            cursor = cursor.advanced(by: MemoryLayout<UInt32>.size)
                        }

                        var linkCount: UInt32 = 1
                        if (returned.fileattr & UInt32(ATTR_FILE_LINKCOUNT)) != 0 {
                            guard cursor.advanced(by: MemoryLayout<UInt32>.size) <= entryEnd else { continue }
                            linkCount = cursor.loadUnaligned(as: UInt32.self)
                            cursor = cursor.advanced(by: MemoryLayout<UInt32>.size)
                        }

                        var allocSize: Int64 = 0
                        if (returned.fileattr & UInt32(ATTR_FILE_ALLOCSIZE)) != 0 {
                            guard cursor.advanced(by: MemoryLayout<off_t>.size) <= entryEnd else { continue }
                            allocSize = cursor.loadUnaligned(as: off_t.self)
                            cursor = cursor.advanced(by: MemoryLayout<off_t>.size)
                        }

                        var dataLength: Int64 = 0
                        if (returned.fileattr & UInt32(ATTR_FILE_DATALENGTH)) != 0 {
                            guard cursor.advanced(by: MemoryLayout<off_t>.size) <= entryEnd else { continue }
                            dataLength = cursor.loadUnaligned(as: off_t.self)
                            cursor = cursor.advanced(by: MemoryLayout<off_t>.size)
                        }

                        guard let nStart = nameSliceStart, nameSliceLen > 0 else { continue }
                        let firstByte = nStart.load(as: UInt8.self)
                        if firstByte == 0 { continue }
                        if firstByte == 0x2E { // '.'
                            let trimmed = UnsafeRawBufferPointer(start: nStart, count: nameSliceLen).firstIndex(of: 0) ?? nameSliceLen
                            if trimmed == 1 || (trimmed == 2 && nStart.advanced(by: 1).load(as: UInt8.self) == 0x2E) {
                                continue
                            }
                        }
                        if entryError != 0 && objType == 0 { continue }

                        if session.hitGlobalCap {
                            return (totalBytes, totalFiles, totalFolders, hadAnyEntry, true, rootAccessible, rootVanished)
                        }
                        try session.recordVisitedEntry(currentPath: currentPath)
                        if session.hitGlobalCap {
                            return (totalBytes, totalFiles, totalFolders, hadAnyEntry, true, rootAccessible, rootVanished)
                        }

                        if needsSpecialRootCheck {
                            let bytes = UnsafeRawBufferPointer(start: nStart, count: nameSliceLen)
                            let trimmed = bytes.firstIndex(of: 0) ?? bytes.count
                            let nameStr = String(decoding: bytes.prefix(trimmed), as: UTF8.self)
                            if Self.shouldSkipSpecialRootChild(name: nameStr, parentPath: currentPath, scanRootPath: session.rootPath) {
                                session.recordSkippedCrossVolume()
                                continue
                            }
                        }

                        if objType == UInt32(VLNK.rawValue) {
                            session.recordSkippedSymlink()
                            continue
                        }
                        if (flags & UInt32(SF_DATALESS)) != 0 {
                            session.recordSkippedDataless()
                            continue
                        }
                        if dev != session.rootDevice {
                            session.recordSkippedCrossVolume()
                            continue
                        }
                        if objType == UInt32(VDIR.rawValue),
                           (dirMountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0 {
                            session.recordSkippedCrossVolume()
                            continue
                        }
                        if !allowHidden && (firstByte == 0x2E || (flags & UInt32(UF_HIDDEN)) != 0) {
                            continue
                        }

                        if objType == UInt32(VREG.rawValue) {
                            hadAnyEntry = true
                            var fileBytes = allocSize > 0
                                ? UInt64(allocSize)
                                : UInt64(max(0, dataLength))
                            if linkCount > 1 {
                                let key = FileInodeKey(dev: dev, ino: ino_t(fileID))
                                if !session.insertHardlinkIfNew(key) {
                                    fileBytes = 0
                                    session.recordDedupHardlink()
                                }
                            }
                            session.recordFile(bytes: fileBytes)
                            totalBytes &+= fileBytes
                            totalFiles += 1
                        } else if objType == UInt32(VDIR.rawValue) {
                            hadAnyEntry = true
                            session.recordFolder()
                            totalFolders += 1
                            let bytes = UnsafeRawBufferPointer(start: nStart, count: nameSliceLen)
                            let trimmed = bytes.firstIndex(of: 0) ?? bytes.count
                            let nameStr = String(decoding: bytes.prefix(trimmed), as: UTF8.self)
                            stack.append(pathPrefix + nameStr)
                        }
                    }
                }

                if !fellBack {
                    isFirst = false
                    continue
                }
                _ = lseek(fd, 0, SEEK_SET)
                let fallbackEntries = try readDirectoryEntriesFallback(
                    dirFD: fd,
                    ownsFD: &ownsFD,
                    dirURL: URL(fileURLWithPath: currentPath)
                )
                isFirst = false
                for entry in fallbackEntries {
                    if session.hitGlobalCap {
                        return (totalBytes, totalFiles, totalFolders, hadAnyEntry, true, rootAccessible, rootVanished)
                    }
                    try session.recordVisitedEntry(currentPath: currentPath)
                    if session.hitGlobalCap {
                        return (totalBytes, totalFiles, totalFolders, hadAnyEntry, true, rootAccessible, rootVanished)
                    }
                    if Self.shouldSkipSpecialRootChild(name: entry.name, parentPath: currentPath, scanRootPath: session.rootPath) {
                        session.recordSkippedCrossVolume()
                        continue
                    }
                    if entry.objType == UInt32(VLNK.rawValue) { session.recordSkippedSymlink(); continue }
                    if (entry.flags & UInt32(SF_DATALESS)) != 0 { session.recordSkippedDataless(); continue }
                    if entry.dev != session.rootDevice { session.recordSkippedCrossVolume(); continue }
                    if entry.objType == UInt32(VDIR.rawValue), (entry.dirMountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0 {
                        session.recordSkippedCrossVolume()
                        continue
                    }
                    if !allowHidden && Self.isEntryHidden(name: entry.name, flags: entry.flags) {
                        continue
                    }
                    if entry.objType == UInt32(VREG.rawValue) {
                        hadAnyEntry = true
                        var fileBytes = entry.allocSize > 0 ? UInt64(entry.allocSize) : UInt64(max(0, entry.dataLength))
                        if entry.linkCount > 1 {
                            let key = FileInodeKey(dev: entry.dev, ino: ino_t(entry.fileID))
                            if !session.insertHardlinkIfNew(key) { fileBytes = 0; session.recordDedupHardlink() }
                        }
                        session.recordFile(bytes: fileBytes)
                        totalBytes &+= fileBytes
                        totalFiles += 1
                    } else if entry.objType == UInt32(VDIR.rawValue) {
                        hadAnyEntry = true
                        session.recordFolder()
                        totalFolders += 1
                        stack.append(pathPrefix + entry.name)
                    }
                }
                continue
            }

            let currentURL = URL(fileURLWithPath: currentPath)
            let entries: [RawDirEntry]
            do {
                entries = try readDirectoryEntries(at: currentURL, expectedDevice: session.rootDevice, scratch: session.scratch)
            } catch let scanErr as DiskScanError {
                switch scanErr {
                case .permissionDenied:
                    if isFirst {
                        if throwOnRootPermissionDenied {
                            throw scanErr
                        }
                        rootAccessible = false
                    }
                    isFirst = false
                    continue
                case .notFound, .invalidPath:
                    if isFirst {
                        if throwOnRootPermissionDenied {
                            throw scanErr
                        }
                        rootVanished = true
                    }
                    isFirst = false
                    continue
                default:
                    throw scanErr
                }
            }
            isFirst = false

            let pathPrefix = currentPath == "/" ? "/" : (currentPath + "/")
            for entry in entries {
                if session.hitGlobalCap {
                    return (totalBytes, totalFiles, totalFolders, hadAnyEntry, true, rootAccessible, rootVanished)
                }
                try session.recordVisitedEntry(currentPath: currentPath)
                if session.hitGlobalCap {
                    return (totalBytes, totalFiles, totalFolders, hadAnyEntry, true, rootAccessible, rootVanished)
                }

                if Self.shouldSkipSpecialRootChild(
                    name: entry.name,
                    parentPath: currentPath,
                    scanRootPath: session.rootPath
                ) {
                    session.recordSkippedCrossVolume()
                    continue
                }

                if entry.objType == UInt32(VLNK.rawValue) {
                    session.recordSkippedSymlink()
                    continue
                }
                if (entry.flags & UInt32(SF_DATALESS)) != 0 {
                    session.recordSkippedDataless()
                    continue
                }
                if entry.dev != session.rootDevice {
                    session.recordSkippedCrossVolume()
                    continue
                }
                if entry.objType == UInt32(VDIR.rawValue),
                   (entry.dirMountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0 {
                    session.recordSkippedCrossVolume()
                    continue
                }
                if !allowHidden && Self.isEntryHidden(name: entry.name, flags: entry.flags) {
                    continue
                }

                if entry.objType == UInt32(VREG.rawValue) {
                    hadAnyEntry = true
                    var fileBytes = entry.allocSize > 0
                        ? UInt64(entry.allocSize)
                        : UInt64(max(0, entry.dataLength))
                    if entry.linkCount > 1 {
                        let key = FileInodeKey(dev: entry.dev, ino: ino_t(entry.fileID))
                        if !session.insertHardlinkIfNew(key) {
                            fileBytes = 0
                            session.recordDedupHardlink()
                        }
                    }
                    session.recordFile(bytes: fileBytes)
                    totalBytes &+= fileBytes
                    totalFiles += 1
                } else if entry.objType == UInt32(VDIR.rawValue) {
                    hadAnyEntry = true
                    session.recordFolder()
                    totalFolders += 1
                    stack.append(pathPrefix + entry.name)
                }
            }
        }

        return (totalBytes, totalFiles, totalFolders, hadAnyEntry, session.hitGlobalCap, rootAccessible, rootVanished)
    }

    private func findMatchingFilesSync(
        root stdRoot: URL,
        filter: DiskEntryFilter,
        referenceDate: Date,
        cancelFlag: CancellationFlag,
        onProgress: @escaping @Sendable (DiskScanProgress) -> Void
    ) throws -> [DiskFilteredItem] {
        let rootStat = try obtainStat(at: stdRoot.path)
        let rootMode = rootStat.st_mode & S_IFMT
        guard rootMode != S_IFLNK, (rootStat.st_flags & UInt32(SF_DATALESS)) == 0 else {
            return []
        }

        let cutoffDate: Date? = filter.olderThanDays.flatMap { days in
            days > 0 ? referenceDate.addingTimeInterval(-TimeInterval(days) * 86_400) : nil
        }
        let query = filter.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowHidden = includeHiddenFiles && filter.includeHiddenFiles

        let scratch = BulkReadScratch()
        var session = ScanSession(
            rootPath: stdRoot.path,
            rootDevice: rootStat.st_dev,
            maxDepth: Int.max,
            startTime: CFAbsoluteTimeGetCurrent(),
            onProgress: onProgress,
            progressThrottleInterval: progressThrottleInterval,
            maxTotalEntries: maxTotalEntries,
            cancelFlag: cancelFlag,
            scratch: scratch,
            sharedHardlinks: nil,
            sharedProgress: nil
        )
        session.lastEmitTime = session.startTime

        var results: [DiskFilteredItem] = []

        if rootMode == S_IFREG {
            let bytes = rootStat.st_blocks > 0
                ? UInt64(rootStat.st_blocks) * 512
                : UInt64(max(0, rootStat.st_size))
            let modDate = Self.dateFromTimespec(rootStat.st_mtimespec)
            let accDate = Self.dateFromTimespec(rootStat.st_atimespec)
            let isProtected = !safetyGuard.validateForRemoval(stdRoot).isAllowed
            let isImmutable = (rootStat.st_flags & UInt32(UF_IMMUTABLE)) != 0
            let isHidden = Self.isEntryHidden(name: stdRoot.lastPathComponent, flags: rootStat.st_flags)
            if (allowHidden || !isHidden),
               bytes >= filter.minBytes,
               !(filter.excludeProtected && isProtected),
               Self.matchesAge(modDate: modDate, accDate: accDate, cutoffDate: cutoffDate, basis: filter.ageBasis),
               Self.matchesSearch(name: stdRoot.lastPathComponent, relativePath: stdRoot.lastPathComponent, query: query) {
                results.append(DiskFilteredItem(
                    url: stdRoot,
                    name: stdRoot.lastPathComponent,
                    isDirectory: false,
                    isPackage: false,
                    bytes: bytes,
                    modificationDate: modDate,
                    accessDate: accDate,
                    expectedCanonicalParent: PrivilegedExecutor.canonicalParentPath(forTargetURL: stdRoot),
                    isProtected: isProtected,
                    isUserImmutable: isImmutable,
                    isHidden: isHidden,
                    relativePathFromRoot: stdRoot.lastPathComponent
                ))
            }
            session.emitProgress(currentPath: stdRoot.path)
            return results
        }

        guard rootMode == S_IFDIR else { return [] }

        struct FindDirFrame {
            let url: URL
            let name: String
            let modDate: Date?
            let accDate: Date?
            let isProtected: Bool
            let isUserImmutable: Bool
            let isHidden: Bool
            let hasHiddenAncestor: Bool
            let expectedCanonicalParent: String
            let relativePath: String
            let canonicalSelf: String
            let entries: [RawDirEntry]
            let emitSelfWhenDone: Bool
            var nextIndex: Int = 0
            var accumulatedBytes: UInt64 = 0
        }

        let rootEntries = try readDirectoryEntries(at: stdRoot, expectedDevice: session.rootDevice, scratch: session.scratch)
        let rootCanonicalSelf = PrivilegedExecutor.canonicalParentPath(for: stdRoot.path)
        var frameStack: [FindDirFrame] = [
            FindDirFrame(
                url: stdRoot,
                name: stdRoot.lastPathComponent,
                modDate: nil,
                accDate: nil,
                isProtected: false,
                isUserImmutable: false,
                isHidden: false,
                hasHiddenAncestor: false,
                expectedCanonicalParent: "",
                relativePath: "",
                canonicalSelf: rootCanonicalSelf,
                entries: rootEntries,
                emitSelfWhenDone: false
            ),
        ]

        while !frameStack.isEmpty {
            if cancelFlag.isCancelled || Task.isCancelled {
                throw CancellationError()
            }

            var frame = frameStack[frameStack.count - 1]
            var descended = false

            while frame.nextIndex < frame.entries.count {
                if session.hitGlobalCap { break }
                let entry = frame.entries[frame.nextIndex]
                frame.nextIndex += 1
                try session.recordVisitedEntry(currentPath: frame.url.path)
                if session.hitGlobalCap { break }

                if Self.shouldSkipSpecialRootChild(
                    name: entry.name,
                    parentPath: frame.url.path,
                    scanRootPath: session.rootPath
                ) {
                    session.recordSkippedCrossVolume()
                    continue
                }

                if entry.objType == UInt32(VLNK.rawValue) {
                    session.recordSkippedSymlink()
                    continue
                }
                if (entry.flags & UInt32(SF_DATALESS)) != 0 {
                    session.recordSkippedDataless()
                    continue
                }
                if entry.dev != session.rootDevice {
                    session.recordSkippedCrossVolume()
                    continue
                }
                if entry.objType == UInt32(VDIR.rawValue),
                   (entry.dirMountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0 {
                    session.recordSkippedCrossVolume()
                    continue
                }

                let entryHidden = Self.isEntryHidden(name: entry.name, flags: entry.flags)
                if !allowHidden && entryHidden {
                    continue
                }
                let effectiveHidden = entryHidden || frame.hasHiddenAncestor
                let childImmutable = (entry.flags & UInt32(UF_IMMUTABLE)) != 0

                if entry.objType == UInt32(VREG.rawValue) {
                    var fileBytes = entry.allocSize > 0
                        ? UInt64(entry.allocSize)
                        : UInt64(max(0, entry.dataLength))
                    if entry.linkCount > 1 {
                        let key = FileInodeKey(dev: entry.dev, ino: ino_t(entry.fileID))
                        if !session.insertHardlinkIfNew(key) {
                            fileBytes = 0
                            session.recordDedupHardlink()
                        }
                    }
                    session.recordFile(bytes: fileBytes)
                    frame.accumulatedBytes &+= fileBytes

                    if fileBytes >= filter.minBytes,
                       Self.matchesAge(modDate: entry.modDate, accDate: entry.accDate, cutoffDate: cutoffDate, basis: filter.ageBasis) {
                        let relPath = frame.relativePath.isEmpty ? entry.name : "\(frame.relativePath)/\(entry.name)"
                        if Self.matchesSearch(name: entry.name, relativePath: relPath, query: query) {
                            let childURL = frame.url.appendingPathComponent(entry.name)
                            let childProtected = !safetyGuard.validateForRemoval(childURL).isAllowed
                            if !(filter.excludeProtected && childProtected) {
                                results.append(DiskFilteredItem(
                                    url: childURL,
                                    name: entry.name,
                                    isDirectory: false,
                                    isPackage: false,
                                    bytes: fileBytes,
                                    modificationDate: entry.modDate,
                                    accessDate: entry.accDate,
                                    expectedCanonicalParent: frame.canonicalSelf,
                                    isProtected: childProtected,
                                    isUserImmutable: childImmutable,
                                    isHidden: effectiveHidden,
                                    relativePathFromRoot: relPath
                                ))
                            }
                        }
                    }
                } else if entry.objType == UInt32(VDIR.rawValue) {
                    session.recordFolder()
                    let childURL = frame.url.appendingPathComponent(entry.name)
                    let relPath = frame.relativePath.isEmpty ? entry.name : "\(frame.relativePath)/\(entry.name)"
                    let isPkg = Self.detectIsPackage(at: childURL)
                    if isPkg {
                        // Measure package sharing `session` (seenHardlinks, maxTotalEntries, hitGlobalCap).
                        // Never descend into `.app` packages for `.filesOnly` item emission.
                        let pkgMeas = try measureCollapsedSubtree(
                            at: childURL,
                            includeHiddenOverride: allowHidden,
                            session: &session
                        )
                        frame.accumulatedBytes &+= pkgMeas.bytes

                        if (filter.scope == .filesAndPackages || filter.scope == .allItems),
                           pkgMeas.bytes >= filter.minBytes,
                           Self.matchesAge(modDate: entry.modDate, accDate: entry.accDate, cutoffDate: cutoffDate, basis: filter.ageBasis),
                           Self.matchesSearch(name: entry.name, relativePath: relPath, query: query) {
                            let childProtected = !safetyGuard.validateForRemoval(childURL).isAllowed
                            if !(filter.excludeProtected && childProtected) {
                                results.append(DiskFilteredItem(
                                    url: childURL,
                                    name: entry.name,
                                    isDirectory: true,
                                    isPackage: true,
                                    bytes: pkgMeas.bytes,
                                    modificationDate: entry.modDate,
                                    accessDate: entry.accDate,
                                    expectedCanonicalParent: frame.canonicalSelf,
                                    isProtected: childProtected,
                                    isUserImmutable: childImmutable,
                                    isHidden: effectiveHidden,
                                    relativePathFromRoot: relPath
                                ))
                            }
                        }
                    } else {
                        let childEntries: [RawDirEntry]
                        do {
                            childEntries = try readDirectoryEntries(at: childURL, expectedDevice: session.rootDevice, scratch: session.scratch)
                        } catch let scanErr as DiskScanError {
                            switch scanErr {
                            case .permissionDenied:
                                childEntries = []
                            case .notFound, .invalidPath:
                                continue
                            default:
                                throw scanErr
                            }
                        }

                        frameStack[frameStack.count - 1] = frame
                        let childCanonicalSelf = PrivilegedExecutor.canonicalParentPath(for: childURL.path)
                        frameStack.append(FindDirFrame(
                            url: childURL,
                            name: entry.name,
                            modDate: entry.modDate,
                            accDate: entry.accDate,
                            isProtected: false,
                            isUserImmutable: childImmutable,
                            isHidden: entryHidden,
                            hasHiddenAncestor: effectiveHidden,
                            expectedCanonicalParent: frame.canonicalSelf,
                            relativePath: relPath,
                            canonicalSelf: childCanonicalSelf,
                            entries: childEntries,
                            emitSelfWhenDone: filter.scope == .allItems
                        ))
                        descended = true
                        break
                    }
                }
            }

            if descended {
                continue
            }

            frameStack.removeLast()
            if frame.emitSelfWhenDone,
               frame.accumulatedBytes >= filter.minBytes,
               Self.matchesAge(modDate: frame.modDate, accDate: frame.accDate, cutoffDate: cutoffDate, basis: filter.ageBasis),
               Self.matchesSearch(name: frame.name, relativePath: frame.relativePath, query: query) {
                let frameProtected = !safetyGuard.validateForRemoval(frame.url).isAllowed
                if !(filter.excludeProtected && frameProtected) {
                    results.append(DiskFilteredItem(
                        url: frame.url,
                        name: frame.name,
                        isDirectory: true,
                        isPackage: false,
                        bytes: frame.accumulatedBytes,
                        modificationDate: frame.modDate,
                        accessDate: frame.accDate,
                        expectedCanonicalParent: frame.expectedCanonicalParent,
                        isProtected: frameProtected,
                        isUserImmutable: frame.isUserImmutable,
                        isHidden: frame.hasHiddenAncestor,
                        relativePathFromRoot: frame.relativePath
                    ))
                }
            }
            if !frameStack.isEmpty {
                frameStack[frameStack.count - 1].accumulatedBytes &+= frame.accumulatedBytes
            }
        }

        results.sort { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            let cmp = lhs.name.localizedStandardCompare(rhs.name)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return lhs.relativePathFromRoot < rhs.relativePathFromRoot
        }
        session.emitProgress(currentPath: stdRoot.path)
        if results.count > filter.maxResults {
            return Array(results.prefix(filter.maxResults))
        }
        return results
    }

    // MARK: - POSIX Enumeration (`getattrlistbulk` + `fdopendir/readdir/fstatat` fallback)

    private func obtainStat(at path: String) throws -> stat {
        if let provided = statProvider?(path) {
            return provided
        }
        var st = stat()
        if lstat(path, &st) != 0 {
            let err = errno
            if err == ENOENT { throw DiskScanError.notFound(path: path) }
            if err == EACCES || err == EPERM { throw DiskScanError.permissionDenied(path: path) }
            throw DiskScanError.posixError(code: err, path: path, detail: String(cString: strerror(err)))
        }
        return st
    }

    private func readDirectoryEntries(
        at dirURL: URL,
        expectedDevice: dev_t,
        scratch: BulkReadScratch
    ) throws -> [RawDirEntry] {
        let path = dirURL.path
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd < 0 {
            let err = errno
            if err == ENOENT { throw DiskScanError.notFound(path: path) }
            if err == EACCES || err == EPERM { throw DiskScanError.permissionDenied(path: path) }
            if err == ELOOP || err == ENOTDIR { return [] }
            throw DiskScanError.posixError(code: err, path: path, detail: String(cString: strerror(err)))
        }

        var ownsFD = true
        defer {
            if ownsFD {
                close(fd)
            }
        }

        if statProvider == nil {
            var openedStat = stat()
            if fstat(fd, &openedStat) == 0, openedStat.st_dev != expectedDevice {
                return []
            }
        }

        let shouldUseBulk: Bool
        switch enumerationMode {
        case .automatic:
            shouldUseBulk = (statProvider == nil)
        case .bulkOnly:
            shouldUseBulk = true
        case .fallbackOnly:
            shouldUseBulk = false
        }

        if shouldUseBulk {
            do {
                return try readDirectoryEntriesBulk(dirFD: fd, dirPath: path, scratch: scratch)
            } catch let fallbackSignal as BulkUnsupportedError {
                _ = fallbackSignal
                if enumerationMode == .bulkOnly {
                    throw DiskScanError.posixError(code: ENOTSUP, path: path, detail: "getattrlistbulk not supported")
                }
                _ = lseek(fd, 0, SEEK_SET)
                return try readDirectoryEntriesFallback(dirFD: fd, ownsFD: &ownsFD, dirURL: dirURL)
            }
        } else {
            return try readDirectoryEntriesFallback(dirFD: fd, ownsFD: &ownsFD, dirURL: dirURL)
        }
    }

    private struct BulkUnsupportedError: Error {}

    private func readDirectoryEntriesBulk(
        dirFD: Int32,
        dirPath: String,
        scratch: BulkReadScratch
    ) throws -> [RawDirEntry] {
        var alist = attrlist()
        alist.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)

        var cmn: UInt32 = 0
        cmn |= UInt32(ATTR_CMN_RETURNED_ATTRS)
        cmn |= UInt32(ATTR_CMN_NAME)
        cmn |= UInt32(ATTR_CMN_DEVID)
        cmn |= UInt32(ATTR_CMN_OBJTYPE)
        cmn |= UInt32(ATTR_CMN_MODTIME)
        cmn |= UInt32(ATTR_CMN_ACCTIME)
        cmn |= UInt32(ATTR_CMN_FLAGS)
        cmn |= UInt32(ATTR_CMN_FILEID)
        cmn |= UInt32(ATTR_CMN_ERROR)
        alist.commonattr = cmn

        alist.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS)

        var fileAttr: UInt32 = 0
        fileAttr |= UInt32(ATTR_FILE_LINKCOUNT)
        fileAttr |= UInt32(ATTR_FILE_ALLOCSIZE)
        fileAttr |= UInt32(ATTR_FILE_DATALENGTH)
        alist.fileattr = fileAttr

        let rawBuf = scratch.buffer
        var results: [RawDirEntry] = []
        var firstBatch = true

        while true {
            let count = getattrlistbulk(dirFD, &alist, rawBuf.baseAddress, rawBuf.count, 0)
            if count == 0 {
                break
            }
            if count < 0 {
                let err = errno
                if firstBatch && (err == ENOTSUP || err == EINVAL || err == ERANGE) {
                    throw BulkUnsupportedError()
                }
                if err == EACCES || err == EPERM {
                    throw DiskScanError.permissionDenied(path: dirPath)
                }
                if err == ENOENT {
                    throw DiskScanError.notFound(path: dirPath)
                }
                throw DiskScanError.posixError(code: err, path: dirPath, detail: String(cString: strerror(err)))
            }
            firstBatch = false

            guard let base = rawBuf.baseAddress else { break }
            do {
                var entryOffset = 0
                for _ in 0..<Int(count) {
                    guard entryOffset + 4 <= rawBuf.count else { break }
                    let entryStart = base.advanced(by: entryOffset)
                    let entryLength = Int(entryStart.loadUnaligned(as: UInt32.self))
                    guard entryLength >= 4, entryOffset + entryLength <= rawBuf.count else { break }
                    defer { entryOffset += entryLength }

                    var cursor = entryStart.advanced(by: 4)
                    let entryEnd = entryStart.advanced(by: entryLength)

                    guard cursor.advanced(by: MemoryLayout<attribute_set_t>.size) <= entryEnd else { continue }
                    let returned = cursor.loadUnaligned(as: attribute_set_t.self)
                    cursor = cursor.advanced(by: MemoryLayout<attribute_set_t>.size)

                    // Decode strictly in <sys/attr.h> ascending bit-flag order.
                    var name = ""
                    if (returned.commonattr & UInt32(ATTR_CMN_NAME)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<attrreference_t>.size) <= entryEnd else { continue }
                        let refPtr = cursor
                        let nameRef = refPtr.loadUnaligned(as: attrreference_t.self)
                        cursor = cursor.advanced(by: MemoryLayout<attrreference_t>.size)
                        let strStart = refPtr.advanced(by: Int(nameRef.attr_dataoffset))
                        let strLen = Int(nameRef.attr_length)
                        if strStart >= entryStart && strStart.advanced(by: strLen) <= entryEnd && strLen > 0 {
                            let bytes = UnsafeRawBufferPointer(start: strStart, count: strLen)
                            let trimmedCount = bytes.firstIndex(of: 0) ?? bytes.count
                            name = String(decoding: bytes.prefix(trimmedCount), as: UTF8.self)
                        }
                    }

                    var dev: dev_t = 0
                    if (returned.commonattr & UInt32(ATTR_CMN_DEVID)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<dev_t>.size) <= entryEnd else { continue }
                        dev = cursor.loadUnaligned(as: dev_t.self)
                        cursor = cursor.advanced(by: MemoryLayout<dev_t>.size)
                    }

                    var objType: UInt32 = 0
                    if (returned.commonattr & UInt32(ATTR_CMN_OBJTYPE)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<fsobj_type_t>.size) <= entryEnd else { continue }
                        objType = cursor.loadUnaligned(as: UInt32.self)
                        cursor = cursor.advanced(by: MemoryLayout<fsobj_type_t>.size)
                    }

                    var modDate: Date?
                    if (returned.commonattr & UInt32(ATTR_CMN_MODTIME)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<timespec>.size) <= entryEnd else { continue }
                        let ts = cursor.loadUnaligned(as: timespec.self)
                        modDate = Self.dateFromTimespec(ts)
                        cursor = cursor.advanced(by: MemoryLayout<timespec>.size)
                    }

                    var accDate: Date?
                    if (returned.commonattr & UInt32(ATTR_CMN_ACCTIME)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<timespec>.size) <= entryEnd else { continue }
                        let ts = cursor.loadUnaligned(as: timespec.self)
                        accDate = Self.dateFromTimespec(ts)
                        cursor = cursor.advanced(by: MemoryLayout<timespec>.size)
                    }

                    var flags: UInt32 = 0
                    if (returned.commonattr & UInt32(ATTR_CMN_FLAGS)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<UInt32>.size) <= entryEnd else { continue }
                        flags = cursor.loadUnaligned(as: UInt32.self)
                        cursor = cursor.advanced(by: MemoryLayout<UInt32>.size)
                    }

                    var fileID: UInt64 = 0
                    if (returned.commonattr & UInt32(ATTR_CMN_FILEID)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<UInt64>.size) <= entryEnd else { continue }
                        fileID = cursor.loadUnaligned(as: UInt64.self)
                        cursor = cursor.advanced(by: MemoryLayout<UInt64>.size)
                    }

                    var entryError: UInt32 = 0
                    if (returned.commonattr & UInt32(ATTR_CMN_ERROR)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<UInt32>.size) <= entryEnd else { continue }
                        entryError = cursor.loadUnaligned(as: UInt32.self)
                        cursor = cursor.advanced(by: MemoryLayout<UInt32>.size)
                    }

                    var dirMountStatus: UInt32 = 0
                    if (returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<UInt32>.size) <= entryEnd else { continue }
                        dirMountStatus = cursor.loadUnaligned(as: UInt32.self)
                        cursor = cursor.advanced(by: MemoryLayout<UInt32>.size)
                    }

                    var linkCount: UInt32 = 1
                    if (returned.fileattr & UInt32(ATTR_FILE_LINKCOUNT)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<UInt32>.size) <= entryEnd else { continue }
                        linkCount = cursor.loadUnaligned(as: UInt32.self)
                        cursor = cursor.advanced(by: MemoryLayout<UInt32>.size)
                    }

                    var allocSize: Int64 = 0
                    if (returned.fileattr & UInt32(ATTR_FILE_ALLOCSIZE)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<off_t>.size) <= entryEnd else { continue }
                        allocSize = cursor.loadUnaligned(as: off_t.self)
                        cursor = cursor.advanced(by: MemoryLayout<off_t>.size)
                    }

                    var dataLength: Int64 = 0
                    if (returned.fileattr & UInt32(ATTR_FILE_DATALENGTH)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<off_t>.size) <= entryEnd else { continue }
                        dataLength = cursor.loadUnaligned(as: off_t.self)
                        cursor = cursor.advanced(by: MemoryLayout<off_t>.size)
                    }

                    guard !name.isEmpty, name != ".", name != ".." else { continue }
                    if entryError != 0 && objType == 0 {
                        continue
                    }

                    results.append(RawDirEntry(
                        name: name,
                        objType: objType,
                        dev: dev,
                        modDate: modDate,
                        accDate: accDate,
                        flags: flags,
                        fileID: fileID,
                        dirMountStatus: dirMountStatus,
                        linkCount: linkCount,
                        allocSize: allocSize,
                        dataLength: dataLength
                    ))
                }
            }
        }

        return results
    }

    private func readDirectoryEntriesFallback(
        dirFD: Int32,
        ownsFD: inout Bool,
        dirURL: URL
    ) throws -> [RawDirEntry] {
        guard let dirStream = fdopendir(dirFD) else {
            let err = errno
            throw DiskScanError.posixError(code: err, path: dirURL.path, detail: String(cString: strerror(err)))
        }
        ownsFD = false
        defer { closedir(dirStream) }

        let streamFD = dirfd(dirStream)
        var results: [RawDirEntry] = []

        while let entPtr = readdir(dirStream) {
            let name = withUnsafePointer(to: &entPtr.pointee.d_name) { ptr -> String in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { cStr in
                    String(cString: cStr)
                }
            }
            if name.isEmpty || name == "." || name == ".." { continue }

            var childStat = stat()
            if let provided = statProvider?(dirURL.appendingPathComponent(name).path) {
                childStat = provided
            } else {
                guard fstatat(streamFD, name, &childStat, AT_SYMLINK_NOFOLLOW) == 0 else {
                    continue
                }
            }

            let mode = childStat.st_mode & S_IFMT
            let objType: UInt32
            switch mode {
            case S_IFREG: objType = UInt32(VREG.rawValue)
            case S_IFDIR: objType = UInt32(VDIR.rawValue)
            case S_IFLNK: objType = UInt32(VLNK.rawValue)
            case S_IFBLK: objType = UInt32(VBLK.rawValue)
            case S_IFCHR: objType = UInt32(VCHR.rawValue)
            case S_IFIFO: objType = UInt32(VFIFO.rawValue)
            case S_IFSOCK: objType = UInt32(VSOCK.rawValue)
            default: objType = UInt32(VNON.rawValue)
            }

            var dirMountStatus: UInt32 = 0
            if mode == S_IFDIR && statProvider == nil {
                dirMountStatus = Self.detectDirectoryMountStatus(at: dirURL.appendingPathComponent(name).path)
            }

            results.append(RawDirEntry(
                name: name,
                objType: objType,
                dev: childStat.st_dev,
                modDate: Self.dateFromTimespec(childStat.st_mtimespec),
                accDate: Self.dateFromTimespec(childStat.st_atimespec),
                flags: childStat.st_flags,
                fileID: UInt64(childStat.st_ino),
                dirMountStatus: dirMountStatus,
                linkCount: UInt32(childStat.st_nlink),
                allocSize: Int64(childStat.st_blocks) * 512,
                dataLength: childStat.st_size
            ))
        }

        return results
    }

    // MARK: - Helpers

    private static func detectDirectoryMountStatus(at path: String) -> UInt32 {
        var alist = attrlist()
        alist.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        alist.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        alist.dirattr = UInt32(ATTR_DIR_MOUNTSTATUS)

        let returnedOffset = 4
        let mountStatusOffset = returnedOffset + MemoryLayout<attribute_set_t>.size
        let bufSize = mountStatusOffset + MemoryLayout<UInt32>.size
        var buffer = [UInt8](repeating: 0, count: bufSize)

        let rc = buffer.withUnsafeMutableBytes { rawBuf -> Int32 in
            guard let base = rawBuf.baseAddress else { return -1 }
            return getattrlist(path, &alist, base, rawBuf.count, UInt32(FSOPT_NOFOLLOW))
        }
        if rc == 0 {
            let result = buffer.withUnsafeBytes { rawBuf -> UInt32? in
                guard let base = rawBuf.baseAddress, rawBuf.count >= bufSize else { return nil }
                let returned = base.advanced(by: returnedOffset).loadUnaligned(as: attribute_set_t.self)
                guard (returned.dirattr & UInt32(ATTR_DIR_MOUNTSTATUS)) != 0 else { return nil }
                return base.advanced(by: mountStatusOffset).loadUnaligned(as: UInt32.self)
            }
            if let result {
                return result
            }
        }

        var sfs = statfs()
        if statfs(path, &sfs) == 0, cStringPath(&sfs.f_mntonname) == path {
            return UInt32(DIR_MNTSTATUS_MNTPOINT)
        }
        return 0
    }

    private static func validateRootURL(_ url: URL) throws -> URL {
        let rawPath = url.path
        guard url.isFileURL,
              !rawPath.isEmpty,
              !rawPath.contains("\0"),
              !url.absoluteString.lowercased().contains("%00"),
              !SafetyGuard.hasDotDotPathComponent(url) else {
            throw DiskScanError.invalidPath(path: rawPath)
        }
        return url.standardizedFileURL
    }

    private static func shouldSkipSpecialRootChild(
        name: String,
        parentPath: String,
        scanRootPath: String
    ) -> Bool {
        if parentPath == "/" && rootVirtualAndFirmlinkNames.contains(name) {
            return true
        }
        if parentPath == "/System/Volumes" && name == "Data",
           scanRootPath != "/System/Volumes/Data",
           !scanRootPath.hasPrefix("/System/Volumes/Data/") {
            return true
        }
        return false
    }

    private static func isEntryHidden(name: String, flags: UInt32) -> Bool {
        name.hasPrefix(".") || (flags & UInt32(UF_HIDDEN)) != 0
    }

    private static func detectIsPackage(at url: URL) -> Bool {
        guard !url.pathExtension.isEmpty else { return false }
        return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }

    private static func dateFromTimespec(_ ts: timespec) -> Date? {
        guard ts.tv_sec != 0 || ts.tv_nsec != 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000.0)
    }

    private static func relativePath(of path: String, under rootPath: String) -> String {
        if rootPath == "/" {
            return path.hasPrefix("/") ? String(path.dropFirst()) : path
        }
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func matchesAge(
        modDate: Date?,
        accDate: Date?,
        cutoffDate: Date?,
        basis: DiskAgeDateBasis
    ) -> Bool {
        guard let cutoffDate else { return true }
        switch basis {
        case .modificationDate:
            guard let d = modDate else { return false }
            return d <= cutoffDate
        case .accessDate:
            guard let d = accDate else { return false }
            return d <= cutoffDate
        case .latestOfModificationAndAccess:
            let dates = [modDate, accDate].compactMap { $0 }
            guard let latest = dates.max() else { return false }
            return latest <= cutoffDate
        }
    }

    private static func matchesSearch(name: String, relativePath: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(query)
            || relativePath.localizedCaseInsensitiveContains(query)
    }

    private static func cStringPath<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { cStr in
                String(cString: cStr)
            }
        }
    }
}

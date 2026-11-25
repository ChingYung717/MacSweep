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

    private let statProvider: StatProvider?
    private let enumerationMode: EnumerationMode

    private static let kernelSIPFlagMask = UInt32(SF_RESTRICTED) | UInt32(SF_IMMUTABLE) | UInt32(SF_NOUNLINK)
    private static let rootVirtualAndFirmlinkNames: Set<String> = [".vol", ".nofollow", ".resolve", "dev", "Volumes"]
    private static let bulkBufferSize = 128 * 1024

    public init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        maxChildrenPerDirectory: Int = 200,
        progressThrottleInterval: TimeInterval = 0.10,
        maxTotalEntries: Int? = nil
    ) {
        self.safetyGuard = safetyGuard
        self.maxChildrenPerDirectory = max(1, maxChildrenPerDirectory)
        self.progressThrottleInterval = max(0.01, progressThrottleInterval)
        self.maxTotalEntries = maxTotalEntries.map { max(1, $0) }
        self.statProvider = nil
        self.enumerationMode = .automatic
    }

    internal init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        maxChildrenPerDirectory: Int = 200,
        progressThrottleInterval: TimeInterval = 0.10,
        maxTotalEntries: Int? = nil,
        statProvider: StatProvider? = nil,
        enumerationMode: EnumerationMode = .automatic
    ) {
        self.safetyGuard = safetyGuard
        self.maxChildrenPerDirectory = max(1, maxChildrenPerDirectory)
        self.progressThrottleInterval = max(0.01, progressThrottleInterval)
        self.maxTotalEntries = maxTotalEntries.map { max(1, $0) }
        self.statProvider = statProvider
        self.enumerationMode = enumerationMode
    }

    // MARK: - Public Analysis API

    public func analyze(
        root: URL,
        maxDepth: Int = 5,
        onProgress: @escaping @Sendable (DiskScanProgress) -> Void = { _ in }
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
        var stack: [DiskTreeNode] = Array(root.children.reversed())

        while let node = stack.popLast() {
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
                        relativePathFromRoot: relativePath
                    ))
                }
            }

            if node.isDirectory && !node.isPackage && !node.children.isEmpty {
                for child in node.children.reversed() {
                    stack.append(child)
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

    private struct ScanSession {
        let rootPath: String
        let rootDevice: dev_t
        let maxDepth: Int
        let startTime: CFAbsoluteTime
        let onProgress: @Sendable (DiskScanProgress) -> Void
        let progressThrottleInterval: TimeInterval
        let maxTotalEntries: Int?
        let cancelFlag: CancellationFlag

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

        mutating func recordVisitedEntry(currentPath: String) throws {
            if cancelFlag.isCancelled || Task.isCancelled {
                throw CancellationError()
            }
            visitedEntries += 1
            if let cap = maxTotalEntries, visitedEntries > cap {
                hitGlobalCap = true
            }
            if (visitedEntries & 0x3F) == 0 {
                let now = CFAbsoluteTimeGetCurrent()
                if now - lastEmitTime >= progressThrottleInterval {
                    lastEmitTime = now
                    emitProgress(currentPath: currentPath, now: now)
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

        var session = ScanSession(
            rootPath: stdRoot.path,
            rootDevice: rootStat.st_dev,
            maxDepth: maxDepth,
            startTime: CFAbsoluteTimeGetCurrent(),
            onProgress: onProgress,
            progressThrottleInterval: progressThrottleInterval,
            maxTotalEntries: maxTotalEntries,
            cancelFlag: cancelFlag
        )
        session.lastEmitTime = session.startTime

        guard let rootNode = try scanDirectory(
            dirURL: stdRoot,
            dirName: displayName,
            depth: 0,
            modDate: rootMod,
            accDate: rootAcc,
            isUserImmutable: rootImmutable,
            isProtected: rootProtected,
            expectedCanonicalParent: rootParent,
            isRootCall: true,
            session: &session
        ) else {
            throw DiskScanError.notFound(path: stdRoot.path)
        }

        session.emitProgress(currentPath: stdRoot.path)
        return rootNode
    }

    private func scanDirectory(
        dirURL: URL,
        dirName: String,
        depth: Int,
        modDate: Date?,
        accDate: Date?,
        isUserImmutable: Bool,
        isProtected: Bool,
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
                isProtected: isProtected,
                isUserImmutable: isUserImmutable,
                expectedCanonicalParent: expectedCanonicalParent
            )
        }

        let entries: [RawDirEntry]
        do {
            entries = try readDirectoryEntries(at: dirURL, expectedDevice: session.rootDevice)
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
                        isProtected: isProtected,
                        isUserImmutable: isUserImmutable,
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
                session.skippedCrossVolume += 1
                continue
            }

            if entry.objType == UInt32(VLNK.rawValue) {
                session.skippedSymlinks += 1
                continue
            }

            if (entry.flags & UInt32(SF_DATALESS)) != 0 {
                session.skippedDataless += 1
                continue
            }

            if entry.dev != session.rootDevice {
                session.skippedCrossVolume += 1
                continue
            }

            if entry.objType == UInt32(VDIR.rawValue),
               (entry.dirMountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0 {
                session.skippedCrossVolume += 1
                continue
            }

            let childURL = dirURL.appendingPathComponent(entry.name)
            let childProtected = !safetyGuard.validateForRemoval(childURL).isAllowed
            let childImmutable = (entry.flags & UInt32(UF_IMMUTABLE)) != 0

            if entry.objType == UInt32(VREG.rawValue) {
                var fileBytes = entry.allocSize > 0
                    ? UInt64(entry.allocSize)
                    : UInt64(max(0, entry.dataLength))

                if entry.linkCount > 1 {
                    let key = FileInodeKey(dev: entry.dev, ino: ino_t(entry.fileID))
                    if !session.seenHardlinks.insert(key).inserted {
                        fileBytes = 0
                        session.deduplicatedHardlinks += 1
                    }
                }

                session.scannedFiles += 1
                session.totalBytes &+= fileBytes
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
                    isProtected: childProtected,
                    isUserImmutable: childImmutable,
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
                    isProtected: childProtected,
                    expectedCanonicalParent: canonicalSelf,
                    isRootCall: false,
                    session: &session
                ) {
                    session.scannedFolders += 1
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
            isProtected: isProtected,
            isUserImmutable: isUserImmutable,
            expectedCanonicalParent: expectedCanonicalParent
        )
    }

    private func measureCollapsedSubtree(
        at rootDirURL: URL,
        throwOnRootPermissionDenied: Bool = false,
        session: inout ScanSession
    ) throws -> (bytes: UInt64, fileCount: Int, folderCount: Int, hadAnyEntry: Bool, hitGlobalCap: Bool, isAccessible: Bool, rootVanished: Bool) {
        var stack: [URL] = [rootDirURL]
        var totalBytes: UInt64 = 0
        var totalFiles = 0
        var totalFolders = 0
        var hadAnyEntry = false
        var rootAccessible = true
        var rootVanished = false
        var isFirst = true

        while let currentURL = stack.popLast() {
            if session.cancelFlag.isCancelled || Task.isCancelled {
                throw CancellationError()
            }
            if session.hitGlobalCap {
                return (totalBytes, totalFiles, totalFolders, hadAnyEntry, true, rootAccessible, rootVanished)
            }

            let entries: [RawDirEntry]
            do {
                entries = try readDirectoryEntries(at: currentURL, expectedDevice: session.rootDevice)
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

            let currentPath = currentURL.path
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
                    session.skippedCrossVolume += 1
                    continue
                }

                if entry.objType == UInt32(VLNK.rawValue) {
                    session.skippedSymlinks += 1
                    continue
                }
                if (entry.flags & UInt32(SF_DATALESS)) != 0 {
                    session.skippedDataless += 1
                    continue
                }
                if entry.dev != session.rootDevice {
                    session.skippedCrossVolume += 1
                    continue
                }
                if entry.objType == UInt32(VDIR.rawValue),
                   (entry.dirMountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0 {
                    session.skippedCrossVolume += 1
                    continue
                }

                if entry.objType == UInt32(VREG.rawValue) {
                    hadAnyEntry = true
                    var fileBytes = entry.allocSize > 0
                        ? UInt64(entry.allocSize)
                        : UInt64(max(0, entry.dataLength))
                    if entry.linkCount > 1 {
                        let key = FileInodeKey(dev: entry.dev, ino: ino_t(entry.fileID))
                        if !session.seenHardlinks.insert(key).inserted {
                            fileBytes = 0
                            session.deduplicatedHardlinks += 1
                        }
                    }
                    session.scannedFiles += 1
                    session.totalBytes &+= fileBytes
                    totalBytes &+= fileBytes
                    totalFiles += 1
                } else if entry.objType == UInt32(VDIR.rawValue) {
                    hadAnyEntry = true
                    session.scannedFolders += 1
                    totalFolders += 1
                    stack.append(currentURL.appendingPathComponent(entry.name))
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

        var session = ScanSession(
            rootPath: stdRoot.path,
            rootDevice: rootStat.st_dev,
            maxDepth: Int.max,
            startTime: CFAbsoluteTimeGetCurrent(),
            onProgress: onProgress,
            progressThrottleInterval: progressThrottleInterval,
            maxTotalEntries: maxTotalEntries,
            cancelFlag: cancelFlag
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
            if bytes >= filter.minBytes,
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
            let expectedCanonicalParent: String
            let relativePath: String
            let canonicalSelf: String
            let entries: [RawDirEntry]
            let emitSelfWhenDone: Bool
            var nextIndex: Int = 0
            var accumulatedBytes: UInt64 = 0
        }

        let rootEntries = try readDirectoryEntries(at: stdRoot, expectedDevice: session.rootDevice)
        let rootCanonicalSelf = PrivilegedExecutor.canonicalParentPath(for: stdRoot.path)
        var frameStack: [FindDirFrame] = [
            FindDirFrame(
                url: stdRoot,
                name: stdRoot.lastPathComponent,
                modDate: nil,
                accDate: nil,
                isProtected: false,
                isUserImmutable: false,
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
                    session.skippedCrossVolume += 1
                    continue
                }

                if entry.objType == UInt32(VLNK.rawValue) {
                    session.skippedSymlinks += 1
                    continue
                }
                if (entry.flags & UInt32(SF_DATALESS)) != 0 {
                    session.skippedDataless += 1
                    continue
                }
                if entry.dev != session.rootDevice {
                    session.skippedCrossVolume += 1
                    continue
                }
                if entry.objType == UInt32(VDIR.rawValue),
                   (entry.dirMountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0 {
                    session.skippedCrossVolume += 1
                    continue
                }

                let childURL = frame.url.appendingPathComponent(entry.name)
                let relPath = Self.relativePath(of: childURL.path, under: stdRoot.path)
                let childProtected = !safetyGuard.validateForRemoval(childURL).isAllowed
                let childImmutable = (entry.flags & UInt32(UF_IMMUTABLE)) != 0

                if entry.objType == UInt32(VREG.rawValue) {
                    var fileBytes = entry.allocSize > 0
                        ? UInt64(entry.allocSize)
                        : UInt64(max(0, entry.dataLength))
                    if entry.linkCount > 1 {
                        let key = FileInodeKey(dev: entry.dev, ino: ino_t(entry.fileID))
                        if !session.seenHardlinks.insert(key).inserted {
                            fileBytes = 0
                            session.deduplicatedHardlinks += 1
                        }
                    }
                    session.scannedFiles += 1
                    session.totalBytes &+= fileBytes
                    frame.accumulatedBytes &+= fileBytes

                    if fileBytes >= filter.minBytes,
                       !(filter.excludeProtected && childProtected),
                       Self.matchesAge(modDate: entry.modDate, accDate: entry.accDate, cutoffDate: cutoffDate, basis: filter.ageBasis),
                       Self.matchesSearch(name: entry.name, relativePath: relPath, query: query) {
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
                            relativePathFromRoot: relPath
                        ))
                    }
                } else if entry.objType == UInt32(VDIR.rawValue) {
                    session.scannedFolders += 1
                    let isPkg = Self.detectIsPackage(at: childURL)
                    if isPkg {
                        // Measure package sharing `session` (seenHardlinks, maxTotalEntries, hitGlobalCap).
                        // Never descend into `.app` packages for `.filesOnly` item emission.
                        let pkgMeas = try measureCollapsedSubtree(at: childURL, session: &session)
                        frame.accumulatedBytes &+= pkgMeas.bytes

                        if (filter.scope == .filesAndPackages || filter.scope == .allItems),
                           pkgMeas.bytes >= filter.minBytes,
                           !(filter.excludeProtected && childProtected),
                           Self.matchesAge(modDate: entry.modDate, accDate: entry.accDate, cutoffDate: cutoffDate, basis: filter.ageBasis),
                           Self.matchesSearch(name: entry.name, relativePath: relPath, query: query) {
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
                                relativePathFromRoot: relPath
                            ))
                        }
                    } else {
                        let childEntries: [RawDirEntry]
                        do {
                            childEntries = try readDirectoryEntries(at: childURL, expectedDevice: session.rootDevice)
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
                            isProtected: childProtected,
                            isUserImmutable: childImmutable,
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
               !(filter.excludeProtected && frame.isProtected),
               Self.matchesAge(modDate: frame.modDate, accDate: frame.accDate, cutoffDate: cutoffDate, basis: filter.ageBasis),
               Self.matchesSearch(name: frame.name, relativePath: frame.relativePath, query: query) {
                results.append(DiskFilteredItem(
                    url: frame.url,
                    name: frame.name,
                    isDirectory: true,
                    isPackage: false,
                    bytes: frame.accumulatedBytes,
                    modificationDate: frame.modDate,
                    accessDate: frame.accDate,
                    expectedCanonicalParent: frame.expectedCanonicalParent,
                    isProtected: frame.isProtected,
                    isUserImmutable: frame.isUserImmutable,
                    relativePathFromRoot: frame.relativePath
                ))
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

    private func readDirectoryEntries(at dirURL: URL, expectedDevice: dev_t) throws -> [RawDirEntry] {
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
                return try readDirectoryEntriesBulk(dirFD: fd, dirPath: path)
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

    private func readDirectoryEntriesBulk(dirFD: Int32, dirPath: String) throws -> [RawDirEntry] {
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

        var buffer = [UInt8](repeating: 0, count: Self.bulkBufferSize)
        var results: [RawDirEntry] = []
        var firstBatch = true

        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuf -> Int32 in
                guard let base = rawBuf.baseAddress else { return -1 }
                return getattrlistbulk(dirFD, &alist, base, rawBuf.count, 0)
            }
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

            buffer.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
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

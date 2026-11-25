import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

public struct LargeAndDuplicateScanner: Sendable {
    internal typealias StatProvider = @Sendable (_ path: String) -> stat?

    internal enum EnumerationMode: Sendable {
        case automatic
        case bulkOnly
        case fallbackOnly
    }

    public let safetyGuard: SafetyGuard
    public let progressThrottleInterval: TimeInterval

    private let statProvider: StatProvider?
    private let enumerationMode: EnumerationMode

    /// Directory traversal blocks `SF_RESTRICTED` and `SF_IMMUTABLE`, but intentionally does NOT
    /// treat `SF_NOUNLINK` (`sunlnk`) as unreadable because macOS marks `/`, `/Applications`,
    /// `/Library`, and `/Users` with `sunlnk`.
    private static let traversalSIPFlagMask = UInt32(SF_RESTRICTED) | UInt32(SF_IMMUTABLE)
    private static let rootVirtualAndFirmlinkNames: Set<String> = [".vol", ".nofollow", ".resolve", "dev", "Volumes"]
    private static let bulkBufferSize = 128 * 1024

    public init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        progressThrottleInterval: TimeInterval = 0.10
    ) {
        self.safetyGuard = safetyGuard
        self.progressThrottleInterval = max(0.01, progressThrottleInterval)
        self.statProvider = nil
        self.enumerationMode = .automatic
    }

    internal init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        progressThrottleInterval: TimeInterval = 0.10,
        statProvider: StatProvider? = nil,
        enumerationMode: EnumerationMode = .automatic
    ) {
        self.safetyGuard = safetyGuard
        self.progressThrottleInterval = max(0.01, progressThrottleInterval)
        self.statProvider = statProvider
        self.enumerationMode = enumerationMode
    }

    // MARK: - Public API (F7: Large Files)

    public func scanLargeFiles(
        under root: URL,
        options: LargeFileScanOptions = LargeFileScanOptions(),
        referenceDate: Date = Date(),
        onProgress: (@Sendable (ResourceScanProgress) -> Void)? = nil
    ) async throws -> [LargeFileItem] {
        let stdRoot = try Self.validateRootURL(root)
        let cancelFlag = CancellationFlag()
        let scanner = self

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let items = try scanner.scanLargeFilesSync(
                            root: stdRoot,
                            options: options,
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

    public func scanLargeFiles(
        under root: URL,
        minBytes: UInt64,
        olderThanDays: Int? = nil,
        ageBasis: DiskAgeDateBasis = .modificationDate,
        categories: Set<LargeFileCategory> = [],
        includePackages: Bool = false,
        includeHiddenFiles: Bool = true,
        maxResults: Int = 500,
        referenceDate: Date = Date(),
        onProgress: (@Sendable (ResourceScanProgress) -> Void)? = nil
    ) async throws -> [LargeFileItem] {
        let options = LargeFileScanOptions(
            minBytes: minBytes,
            olderThanDays: olderThanDays,
            ageBasis: ageBasis,
            categories: categories,
            includePackages: includePackages,
            includeHiddenFiles: includeHiddenFiles,
            maxResults: maxResults
        )
        return try await scanLargeFiles(
            under: root,
            options: options,
            referenceDate: referenceDate,
            onProgress: onProgress
        )
    }

    // MARK: - Public API (F8: Duplicate Files)

    public func scanDuplicates(
        under root: URL,
        options: DuplicateScanOptions = DuplicateScanOptions(),
        onProgress: (@Sendable (ResourceScanProgress) -> Void)? = nil
    ) async throws -> [DuplicateGroup] {
        let stdRoot = try Self.validateRootURL(root)
        let cancelFlag = CancellationFlag()
        let scanner = self

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let groups = try scanner.scanDuplicatesSync(
                            root: stdRoot,
                            options: options,
                            cancelFlag: cancelFlag,
                            onProgress: onProgress
                        )
                        continuation.resume(returning: groups)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    public func scanDuplicates(
        under root: URL,
        minBytes: UInt64,
        includeZeroByteFiles: Bool = false,
        includeHiddenFiles: Bool = false,
        maxGroups: Int = 500,
        onProgress: (@Sendable (ResourceScanProgress) -> Void)? = nil
    ) async throws -> [DuplicateGroup] {
        let options = DuplicateScanOptions(
            minBytes: minBytes,
            includeZeroByteFiles: includeZeroByteFiles,
            includeHiddenFiles: includeHiddenFiles,
            maxGroups: maxGroups
        )
        return try await scanDuplicates(
            under: root,
            options: options,
            onProgress: onProgress
        )
    }

    public func applySmartSelection(
        to groups: [DuplicateGroup],
        preset: DuplicateSelectionPreset = .preferNonDownloads
    ) -> [DuplicateGroup] {
        groups.map { $0.applyingPreset(preset) }
    }

    // MARK: - Classification Helper

    public static func classifyLargeFileCategory(for url: URL) -> LargeFileCategory {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "m4v", "mkv", "avi", "webm", "ts", "m2ts", "flv", "wmv", "mpg", "mpeg":
            return .video
        case "pkg", "mpkg", "xip":
            return .installer
        case "dmg", "iso", "img", "cdr", "sparseimage", "sparsebundle",
             "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst":
            return .diskImageAndArchive
        case "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma":
            return .audio
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
             "pages", "numbers", "key", "txt", "rtf", "md", "csv", "json", "xml", "epub":
            return .document
        default:
            break
        }
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
            if utType.conforms(to: .movie) || utType.conforms(to: .video) {
                return .video
            }
            if utType.conforms(to: .audio) {
                return .audio
            }
            if utType.conforms(to: .archive) || utType.conforms(to: .diskImage) {
                return .diskImageAndArchive
            }
            if utType.conforms(to: .pdf) || utType.conforms(to: .text)
                || utType.conforms(to: .spreadsheet) || utType.conforms(to: .presentation) {
                return .document
            }
        }
        return .other
    }

    // MARK: - Internal Supporting Types

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

    private struct FileInodeKey: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    private struct RawDirEntry {
        let name: String
        let objType: UInt32
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

    private struct BulkUnsupportedError: Error {}

    private struct WalkStats {
        let rootPath: String
        let rootDevice: dev_t
        let startedAt: Date
        var lastEmitAt: Date = .distantPast
        var scannedFiles: Int = 0
        var candidateFiles: Int = 0
        var skippedSymlinks: Int = 0
        var skippedDataless: Int = 0
        var skippedCrossVolume: Int = 0
        var deduplicatedHardlinks: Int = 0
        var seenHardlinks: Set<FileInodeKey> = []

        mutating func emit(
            stage: ResourceScanStage,
            currentPath: String,
            hashedFiles: Int = 0,
            totalCandidateFiles: Int = 0,
            throttle: TimeInterval,
            force: Bool = false,
            onProgress: (@Sendable (ResourceScanProgress) -> Void)?
        ) {
            guard let onProgress else { return }
            let now = Date()
            if force || now.timeIntervalSince(lastEmitAt) >= throttle {
                lastEmitAt = now
                onProgress(ResourceScanProgress(
                    stage: stage,
                    currentPath: currentPath,
                    scannedFiles: scannedFiles,
                    candidateFiles: candidateFiles,
                    hashedFiles: hashedFiles,
                    totalCandidateFiles: totalCandidateFiles,
                    elapsedSeconds: now.timeIntervalSince(startedAt),
                    skippedSymlinks: skippedSymlinks,
                    skippedDataless: skippedDataless,
                    skippedCrossVolume: skippedCrossVolume,
                    deduplicatedHardlinks: deduplicatedHardlinks
                ))
            }
        }
    }

    private struct CandidateFile {
        let url: URL
        let name: String
        let size: UInt64
        let modDate: Date?
        let expectedCanonicalParent: String
        let isUserImmutable: Bool
        let isHidden: Bool
        let requiresAdmin: Bool
        let relativePath: String
    }

    // MARK: - Large Files Implementation

    private func scanLargeFilesSync(
        root: URL,
        options: LargeFileScanOptions,
        referenceDate: Date,
        cancelFlag: CancellationFlag,
        onProgress: (@Sendable (ResourceScanProgress) -> Void)?
    ) throws -> [LargeFileItem] {
        var rootStat = stat()
        guard lstat(root.path, &rootStat) == 0 else {
            let err = errno
            if err == ENOENT { throw DiskScanError.notFound(path: root.path) }
            if err == EACCES || err == EPERM { throw DiskScanError.permissionDenied(path: root.path) }
            throw DiskScanError.posixError(code: err, path: root.path, detail: String(cString: strerror(err)))
        }
        guard (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw DiskScanError.invalidPath(path: root.path)
        }
        if (rootStat.st_flags & Self.traversalSIPFlagMask) != 0 {
            throw DiskScanError.permissionDenied(path: root.path)
        }

        let cutoffDate: Date? = options.olderThanDays.flatMap { days in
            days > 0 ? referenceDate.addingTimeInterval(-TimeInterval(days) * 86_400) : nil
        }

        var stats = WalkStats(
            rootPath: root.path,
            rootDevice: rootStat.st_dev,
            startedAt: Date()
        )
        var results: [LargeFileItem] = []

        var stack: [(url: URL, ancestorHidden: Bool)] = [(root, false)]
        while let frame = stack.popLast() {
            let dirURL = frame.url
            if cancelFlag.isCancelled || Task.isCancelled {
                throw CancellationError()
            }

            let dirPath = dirURL.path
            let canonicalSelf = PrivilegedExecutor.canonicalParentPath(for: dirPath)
            let entries: [RawDirEntry]
            do {
                entries = try readDirectoryEntries(at: dirURL, expectedDevice: stats.rootDevice)
            } catch let scanErr as DiskScanError {
                switch scanErr {
                case .permissionDenied, .notFound, .invalidPath:
                    continue
                default:
                    throw scanErr
                }
            }

            for entry in entries {
                if cancelFlag.isCancelled || Task.isCancelled {
                    throw CancellationError()
                }
                let entryHidden = entry.name.hasPrefix(".") || (entry.flags & UInt32(UF_HIDDEN)) != 0
                if !options.includeHiddenFiles && entryHidden {
                    continue
                }
                let effectiveHidden = entryHidden || frame.ancestorHidden

                if Self.shouldSkipSpecialRootChild(
                    name: entry.name,
                    parentPath: dirPath,
                    scanRootPath: stats.rootPath
                ) {
                    stats.skippedCrossVolume += 1
                    continue
                }
                if entry.objType == UInt32(VLNK.rawValue) {
                    stats.skippedSymlinks += 1
                    continue
                }
                if (entry.flags & UInt32(SF_DATALESS)) != 0 {
                    stats.skippedDataless += 1
                    continue
                }
                if entry.dev != stats.rootDevice {
                    stats.skippedCrossVolume += 1
                    continue
                }
                if entry.objType == UInt32(VDIR.rawValue),
                   (entry.dirMountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0 {
                    stats.skippedCrossVolume += 1
                    continue
                }

                let childURL = dirURL.appendingPathComponent(entry.name).standardizedFileURL
                if entry.objType == UInt32(VREG.rawValue) {
                    stats.scannedFiles += 1
                    if entry.linkCount > 1 && entry.fileID != 0 {
                        let key = FileInodeKey(dev: entry.dev, ino: ino_t(entry.fileID))
                        if !stats.seenHardlinks.insert(key).inserted {
                            stats.deduplicatedHardlinks += 1
                            continue
                        }
                    }

                    let fileBytes = UInt64(max(0, entry.dataLength))
                    guard fileBytes >= options.minBytes else { continue }
                    guard Self.matchesAge(
                        modDate: entry.modDate,
                        accDate: entry.accDate,
                        cutoffDate: cutoffDate,
                        basis: options.ageBasis
                    ) else { continue }
                    guard safetyGuard.validateForRemoval(childURL).isAllowed else { continue }

                    let category = Self.classifyLargeFileCategory(for: childURL)
                    if !options.categories.isEmpty && !options.categories.contains(category) {
                        continue
                    }

                    stats.candidateFiles += 1
                    results.append(LargeFileItem(
                        url: childURL,
                        name: entry.name,
                        bytes: fileBytes,
                        modificationDate: entry.modDate,
                        accessDate: entry.accDate,
                        category: category,
                        expectedCanonicalParent: canonicalSelf,
                        isPackage: false,
                        isUserImmutable: (entry.flags & UInt32(UF_IMMUTABLE)) != 0,
                        isHidden: effectiveHidden,
                        requiresAdmin: safetyGuard.requiresAdmin(for: childURL),
                        isProtected: false,
                        isSelected: false,
                        relativePathFromRoot: Self.relativePath(of: childURL.path, under: stats.rootPath)
                    ))
                } else if entry.objType == UInt32(VDIR.rawValue) {
                    if safetyGuard.shouldPruneDirectoryScan(at: childURL) {
                        continue
                    }
                    let isPkg = Self.detectIsPackage(at: childURL)
                    if isPkg {
                        guard options.includePackages else { continue }
                        guard safetyGuard.validateForRemoval(childURL).isAllowed else { continue }
                        guard Self.matchesAge(
                            modDate: entry.modDate,
                            accDate: entry.accDate,
                            cutoffDate: cutoffDate,
                            basis: options.ageBasis
                        ) else { continue }
                        let pkgSize = UInt64(max(0, DirectorySizer.computeSizeSync(of: childURL)))
                        guard pkgSize >= options.minBytes else { continue }
                        let category = Self.classifyLargeFileCategory(for: childURL)
                        if !options.categories.isEmpty && !options.categories.contains(category) {
                            continue
                        }
                        stats.candidateFiles += 1
                        results.append(LargeFileItem(
                            url: childURL,
                            name: entry.name,
                            bytes: pkgSize,
                            modificationDate: entry.modDate,
                            accessDate: entry.accDate,
                            category: category,
                            expectedCanonicalParent: canonicalSelf,
                            isPackage: true,
                            isUserImmutable: (entry.flags & UInt32(UF_IMMUTABLE)) != 0,
                            isHidden: effectiveHidden,
                            requiresAdmin: safetyGuard.requiresAdmin(for: childURL),
                            isProtected: false,
                            isSelected: false,
                            relativePathFromRoot: Self.relativePath(of: childURL.path, under: stats.rootPath)
                        ))
                    } else {
                        stack.append((childURL, effectiveHidden))
                    }
                }
            }

            stats.emit(
                stage: .largeFiles,
                currentPath: dirPath,
                throttle: progressThrottleInterval,
                onProgress: onProgress
            )
        }

        results.sort { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            let cmp = lhs.name.localizedStandardCompare(rhs.name)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return lhs.url.path < rhs.url.path
        }
        if results.count > options.maxResults {
            results = Array(results.prefix(options.maxResults))
        }

        stats.emit(
            stage: .largeFiles,
            currentPath: root.path,
            throttle: progressThrottleInterval,
            force: true,
            onProgress: onProgress
        )
        return results
    }

    // MARK: - Duplicate Files 3-Stage Pipeline Implementation

    private func scanDuplicatesSync(
        root: URL,
        options: DuplicateScanOptions,
        cancelFlag: CancellationFlag,
        onProgress: (@Sendable (ResourceScanProgress) -> Void)?
    ) throws -> [DuplicateGroup] {
        var rootStat = stat()
        guard lstat(root.path, &rootStat) == 0 else {
            let err = errno
            if err == ENOENT { throw DiskScanError.notFound(path: root.path) }
            if err == EACCES || err == EPERM { throw DiskScanError.permissionDenied(path: root.path) }
            throw DiskScanError.posixError(code: err, path: root.path, detail: String(cString: strerror(err)))
        }
        guard (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw DiskScanError.invalidPath(path: root.path)
        }
        if (rootStat.st_flags & Self.traversalSIPFlagMask) != 0 {
            throw DiskScanError.permissionDenied(path: root.path)
        }

        let effectiveMinBytes = options.includeZeroByteFiles
            ? options.minBytes
            : max(1, options.minBytes)

        var stats = WalkStats(
            rootPath: root.path,
            rootDevice: rootStat.st_dev,
            startedAt: Date()
        )

        // Stage 1: Exact Byte Size Grouping (deduplicating hardlinks via (st_dev, st_ino))
        var sizeBuckets: [UInt64: [CandidateFile]] = [:]
        var stack: [(url: URL, ancestorHidden: Bool)] = [(root, false)]

        while let frame = stack.popLast() {
            let dirURL = frame.url
            if cancelFlag.isCancelled || Task.isCancelled {
                throw CancellationError()
            }

            let dirPath = dirURL.path
            let canonicalSelf = PrivilegedExecutor.canonicalParentPath(for: dirPath)
            let entries: [RawDirEntry]
            do {
                entries = try readDirectoryEntries(at: dirURL, expectedDevice: stats.rootDevice)
            } catch let scanErr as DiskScanError {
                switch scanErr {
                case .permissionDenied, .notFound, .invalidPath:
                    continue
                default:
                    throw scanErr
                }
            }

            for entry in entries {
                if cancelFlag.isCancelled || Task.isCancelled {
                    throw CancellationError()
                }
                if entry.name == ".DS_Store" || entry.name == ".localized" {
                    continue
                }
                let entryHidden = entry.name.hasPrefix(".") || (entry.flags & UInt32(UF_HIDDEN)) != 0
                if !options.includeHiddenFiles && entryHidden {
                    continue
                }
                let effectiveHidden = entryHidden || frame.ancestorHidden
                if Self.shouldSkipSpecialRootChild(
                    name: entry.name,
                    parentPath: dirPath,
                    scanRootPath: stats.rootPath
                ) {
                    stats.skippedCrossVolume += 1
                    continue
                }
                if entry.objType == UInt32(VLNK.rawValue) {
                    stats.skippedSymlinks += 1
                    continue
                }
                if (entry.flags & UInt32(SF_DATALESS)) != 0 {
                    stats.skippedDataless += 1
                    continue
                }
                if entry.dev != stats.rootDevice {
                    stats.skippedCrossVolume += 1
                    continue
                }
                if entry.objType == UInt32(VDIR.rawValue),
                   (entry.dirMountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0 {
                    stats.skippedCrossVolume += 1
                    continue
                }

                let childURL = dirURL.appendingPathComponent(entry.name).standardizedFileURL
                if entry.objType == UInt32(VREG.rawValue) {
                    stats.scannedFiles += 1
                    if entry.linkCount > 1 && entry.fileID != 0 {
                        let key = FileInodeKey(dev: entry.dev, ino: ino_t(entry.fileID))
                        if !stats.seenHardlinks.insert(key).inserted {
                            stats.deduplicatedHardlinks += 1
                            continue
                        }
                    }

                    guard entry.dataLength >= 0 else { continue }
                    let fileSize = UInt64(entry.dataLength)
                    guard fileSize >= effectiveMinBytes else { continue }
                    guard safetyGuard.validateForRemoval(childURL).isAllowed else { continue }

                    sizeBuckets[fileSize, default: []].append(CandidateFile(
                        url: childURL,
                        name: entry.name,
                        size: fileSize,
                        modDate: entry.modDate,
                        expectedCanonicalParent: canonicalSelf,
                        isUserImmutable: (entry.flags & UInt32(UF_IMMUTABLE)) != 0,
                        isHidden: effectiveHidden,
                        requiresAdmin: safetyGuard.requiresAdmin(for: childURL),
                        relativePath: Self.relativePath(of: childURL.path, under: stats.rootPath)
                    ))
                } else if entry.objType == UInt32(VDIR.rawValue) {
                    if safetyGuard.shouldPruneDirectoryScan(at: childURL) {
                        continue
                    }
                    // Always skip packages (.app, .photoslibrary, etc.) for Duplicate scanning.
                    if Self.detectIsPackage(at: childURL) {
                        continue
                    }
                    stack.append((childURL, effectiveHidden))
                }
            }

            stats.emit(
                stage: .duplicatesSizeGrouping,
                currentPath: dirPath,
                throttle: progressThrottleInterval,
                onProgress: onProgress
            )
        }

        let collidingSizeBuckets = sizeBuckets
            .filter { $0.value.count >= 2 }
            .sorted { $0.key > $1.key }

        let totalSizeCandidates = collidingSizeBuckets.reduce(into: 0) { $0 += $1.value.count }
        stats.candidateFiles = totalSizeCandidates

        stats.emit(
            stage: .duplicatesPartialHash,
            currentPath: root.path,
            hashedFiles: 0,
            totalCandidateFiles: totalSizeCandidates,
            throttle: progressThrottleInterval,
            force: true,
            onProgress: onProgress
        )

        // Stage 2: Bounded Prefix + Tail Partial Hash (files > 2 * partialHashChunkBytes)
        var fullHashBuckets: [(size: UInt64, candidates: [CandidateFile])] = []
        var partialChecked = 0
        let directFullThreshold = UInt64(options.partialHashChunkBytes * 2)

        for (fileSize, candidates) in collidingSizeBuckets {
            if cancelFlag.isCancelled || Task.isCancelled {
                throw CancellationError()
            }
            if fileSize <= directFullThreshold {
                fullHashBuckets.append((size: fileSize, candidates: candidates))
                partialChecked += candidates.count
                continue
            }

            var partialGroups: [String: [CandidateFile]] = [:]
            for candidate in candidates {
                if cancelFlag.isCancelled || Task.isCancelled {
                    throw CancellationError()
                }
                partialChecked += 1
                if let partialHex = computePartialHash(
                    for: candidate.url,
                    expectedSize: fileSize,
                    chunkBytes: options.partialHashChunkBytes
                ) {
                    partialGroups[partialHex, default: []].append(candidate)
                }
                stats.emit(
                    stage: .duplicatesPartialHash,
                    currentPath: candidate.url.path,
                    hashedFiles: partialChecked,
                    totalCandidateFiles: totalSizeCandidates,
                    throttle: progressThrottleInterval,
                    onProgress: onProgress
                )
            }

            for group in partialGroups.values where group.count >= 2 {
                fullHashBuckets.append((size: fileSize, candidates: group))
            }
        }

        // Stage 3: Full Streaming CryptoKit.SHA256
        let totalFullCandidates = fullHashBuckets.reduce(into: 0) { $0 += $1.candidates.count }
        var fullHashed = 0
        var duplicateGroups: [DuplicateGroup] = []

        stats.emit(
            stage: .duplicatesFullHash,
            currentPath: root.path,
            hashedFiles: 0,
            totalCandidateFiles: totalFullCandidates,
            throttle: progressThrottleInterval,
            force: true,
            onProgress: onProgress
        )

        for (fileSize, candidates) in fullHashBuckets {
            if cancelFlag.isCancelled || Task.isCancelled {
                throw CancellationError()
            }
            var shaGroups: [String: [CandidateFile]] = [:]
            for candidate in candidates {
                if cancelFlag.isCancelled || Task.isCancelled {
                    throw CancellationError()
                }
                fullHashed += 1
                if let fullHex = try computeFullSHA256(
                    for: candidate.url,
                    expectedSize: fileSize,
                    bufferSize: options.streamBufferSize,
                    cancelFlag: cancelFlag
                ) {
                    shaGroups[fullHex, default: []].append(candidate)
                }
                stats.emit(
                    stage: .duplicatesFullHash,
                    currentPath: candidate.url.path,
                    hashedFiles: fullHashed,
                    totalCandidateFiles: totalFullCandidates,
                    throttle: progressThrottleInterval,
                    onProgress: onProgress
                )
            }

            for (shaHex, matched) in shaGroups where matched.count >= 2 {
                let entries = matched
                    .map { item in
                        DuplicateFileEntry(
                            url: item.url,
                            name: item.name,
                            modificationDate: item.modDate,
                            expectedCanonicalParent: item.expectedCanonicalParent,
                            isUserImmutable: item.isUserImmutable,
                            isHidden: item.isHidden,
                            requiresAdmin: item.requiresAdmin,
                            isProtected: false,
                            isSelected: false,
                            relativePathFromRoot: item.relativePath
                        )
                    }
                    .sorted { $0.url.path < $1.url.path }

                duplicateGroups.append(DuplicateGroup(
                    sha256Hex: shaHex,
                    fileSize: fileSize,
                    files: entries
                ))
            }
        }

        duplicateGroups.sort { lhs, rhs in
            if lhs.reclaimableBytes != rhs.reclaimableBytes {
                return lhs.reclaimableBytes > rhs.reclaimableBytes
            }
            if lhs.fileSize != rhs.fileSize {
                return lhs.fileSize > rhs.fileSize
            }
            return lhs.sha256Hex < rhs.sha256Hex
        }

        if duplicateGroups.count > options.maxGroups {
            duplicateGroups = Array(duplicateGroups.prefix(options.maxGroups))
        }

        stats.emit(
            stage: .duplicatesFullHash,
            currentPath: root.path,
            hashedFiles: totalFullCandidates,
            totalCandidateFiles: totalFullCandidates,
            throttle: progressThrottleInterval,
            force: true,
            onProgress: onProgress
        )

        return duplicateGroups
    }

    // MARK: - POSIX Safe Hashing Helpers

    private func computePartialHash(
        for url: URL,
        expectedSize: UInt64,
        chunkBytes: Int
    ) -> String? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else { return nil }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard (st.st_flags & UInt32(SF_DATALESS)) == 0 else { return nil }
        guard st.st_size >= 0, UInt64(st.st_size) == expectedSize else { return nil }

        let readSize = min(chunkBytes, Int(expectedSize))
        var prefix = [UInt8](repeating: 0, count: readSize)
        var tail = [UInt8](repeating: 0, count: readSize)

        let prefixRead = Self.preadFully(fd: fd, buffer: &prefix, count: readSize, offset: 0)
        guard prefixRead == readSize else { return nil }

        let tailOffset = off_t(expectedSize - UInt64(readSize))
        let tailRead = Self.preadFully(fd: fd, buffer: &tail, count: readSize, offset: tailOffset)
        guard tailRead == readSize else { return nil }

        var hasher = SHA256()
        var leSize = expectedSize.littleEndian
        withUnsafeBytes(of: &leSize) { hasher.update(bufferPointer: $0) }
        prefix.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        tail.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func computeFullSHA256(
        for url: URL,
        expectedSize: UInt64,
        bufferSize: Int,
        cancelFlag: CancellationFlag
    ) throws -> String? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else { return nil }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard (st.st_flags & UInt32(SF_DATALESS)) == 0 else { return nil }
        guard st.st_size >= 0, UInt64(st.st_size) == expectedSize else { return nil }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var totalRead: UInt64 = 0

        while true {
            if cancelFlag.isCancelled || Task.isCancelled {
                throw CancellationError()
            }
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuf -> ssize_t in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.read(fd, base, rawBuf.count)
            }
            if bytesRead > 0 {
                totalRead &+= UInt64(bytesRead)
                buffer.withUnsafeBytes { rawBuf in
                    if let base = rawBuf.baseAddress {
                        let slice = UnsafeRawBufferPointer(start: base, count: bytesRead)
                        hasher.update(bufferPointer: slice)
                    }
                }
            } else if bytesRead == 0 {
                break
            } else {
                let err = errno
                if err == EINTR {
                    continue
                }
                return nil
            }
        }

        guard totalRead == expectedSize else { return nil }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func preadFully(
        fd: Int32,
        buffer: inout [UInt8],
        count: Int,
        offset: off_t
    ) -> Int {
        var total = 0
        while total < count {
            let n = buffer.withUnsafeMutableBytes { rawBuf -> ssize_t in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.pread(fd, base.advanced(by: total), count - total, offset + off_t(total))
            }
            if n > 0 {
                total += n
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return -1
            }
        }
        return total
    }

    // MARK: - POSIX Directory Enumeration (Mirrors DiskSpaceAnalyzer)

    private func readDirectoryEntries(at dirURL: URL, expectedDevice: dev_t) throws -> [RawDirEntry] {
        let dirFD = Darwin.open(dirURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if dirFD < 0 {
            let err = errno
            if err == EACCES || err == EPERM {
                throw DiskScanError.permissionDenied(path: dirURL.path)
            }
            if err == ENOENT {
                throw DiskScanError.notFound(path: dirURL.path)
            }
            if err == ENOTDIR || err == ELOOP {
                throw DiskScanError.invalidPath(path: dirURL.path)
            }
            throw DiskScanError.posixError(code: err, path: dirURL.path, detail: String(cString: strerror(err)))
        }

        var ownsFD = true
        defer {
            if ownsFD {
                Darwin.close(dirFD)
            }
        }

        var dirStat = stat()
        if Darwin.fstat(dirFD, &dirStat) == 0 {
            if dirStat.st_dev != expectedDevice {
                return []
            }
            if (dirStat.st_flags & Self.traversalSIPFlagMask) != 0 {
                throw DiskScanError.permissionDenied(path: dirURL.path)
            }
        }

        let useBulk: Bool
        switch enumerationMode {
        case .automatic:
            useBulk = (statProvider == nil)
        case .bulkOnly:
            useBulk = true
        case .fallbackOnly:
            useBulk = false
        }

        if useBulk {
            do {
                return try readDirectoryEntriesBulk(dirFD: dirFD, dirPath: dirURL.path)
            } catch is BulkUnsupportedError {
                guard enumerationMode != .bulkOnly else {
                    throw DiskScanError.posixError(code: ENOTSUP, path: dirURL.path, detail: "getattrlistbulk unsupported")
                }
            }
        }

        return try readDirectoryEntriesFallback(dirFD: dirFD, ownsFD: &ownsFD, dirURL: dirURL)
    }

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

    private static func cStringPath<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { cStr in
                String(cString: cStr)
            }
        }
    }
}

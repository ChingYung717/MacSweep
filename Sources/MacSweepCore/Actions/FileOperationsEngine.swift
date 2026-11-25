import Darwin
import Foundation
import UniformTypeIdentifiers

public struct FileOperationsEngine: Sendable {
    public let safetyGuard: SafetyGuard

    private static let kernelSIPFlagMask = UInt32(SF_RESTRICTED) | UInt32(SF_IMMUTABLE) | UInt32(SF_NOUNLINK)
    private static let maxCrossVolumeDepth = 128

    public init(safetyGuard: SafetyGuard = SafetyGuard()) {
        self.safetyGuard = safetyGuard
    }

    // MARK: - Public API

    public func moveItem(
        from source: URL,
        to destinationDirectory: URL,
        expectedSourceCanonicalParent: String,
        expectedDestinationCanonicalParent: String? = nil
    ) async throws -> URL {
        try Self.validateRawFileURL(source)
        try Self.validateRawFileURL(destinationDirectory)

        let srcStd = source.standardizedFileURL
        let dstDirStd = destinationDirectory.standardizedFileURL
        let sourceName = srcStd.lastPathComponent
        try Self.validateItemName(sourceName)

        let destination = dstDirStd.appendingPathComponent(sourceName)
        try validateMoveOrRenameWithGuard(
            source: srcStd,
            destination: destination,
            expectedSourceCanonicalParent: expectedSourceCanonicalParent
        )

        let guardCopy = safetyGuard
        return try await Task.detached(priority: .userInitiated) {
            let srcParentURL = srcStd.deletingLastPathComponent()
            let srcParentFD = open(srcParentURL.path, O_SEARCH | O_DIRECTORY)
            if srcParentFD < 0 {
                let err = errno
                if err == ENOENT || err == ENOTDIR {
                    throw FileOperationError.sourceNotFound(path: srcStd.path)
                }
                throw Self.mapPOSIXError(err, path: srcParentURL.path)
            }
            defer { close(srcParentFD) }

            let srcCanonicalParent = try Self.canonicalPath(forFD: srcParentFD, fallbackPath: srcParentURL.path)
            if srcCanonicalParent != expectedSourceCanonicalParent {
                throw FileOperationError.toctouMismatch(
                    path: srcStd.path,
                    expectedParent: expectedSourceCanonicalParent,
                    actualParent: srcCanonicalParent
                )
            }

            var srcStat = stat()
            if fstatat(srcParentFD, sourceName, &srcStat, AT_SYMLINK_NOFOLLOW) != 0 {
                let err = errno
                if err == ENOENT {
                    throw FileOperationError.sourceNotFound(path: srcStd.path)
                }
                throw Self.mapPOSIXError(err, path: srcStd.path)
            }
            try Self.ensureNotSIPOrUserLocked(stat: srcStat, path: srcStd.path)

            let dstParentFD = open(dstDirStd.path, O_SEARCH | O_DIRECTORY)
            if dstParentFD < 0 {
                let err = errno
                if err == ENOENT {
                    throw FileOperationError.destinationParentNotFound(path: dstDirStd.path)
                }
                if err == ENOTDIR {
                    throw FileOperationError.destinationNotADirectory(path: dstDirStd.path)
                }
                throw Self.mapPOSIXError(err, path: dstDirStd.path)
            }
            defer { close(dstParentFD) }

            let dstCanonicalParent = try Self.canonicalPath(forFD: dstParentFD, fallbackPath: dstDirStd.path)
            if let expectedDestinationCanonicalParent, dstCanonicalParent != expectedDestinationCanonicalParent {
                throw FileOperationError.toctouMismatch(
                    path: dstDirStd.path,
                    expectedParent: expectedDestinationCanonicalParent,
                    actualParent: dstCanonicalParent
                )
            }

            let canonicalSource = URL(fileURLWithPath: srcCanonicalParent).appendingPathComponent(sourceName)
            let canonicalDestination = URL(fileURLWithPath: dstCanonicalParent).appendingPathComponent(sourceName)
            if case let .blocked(reason) = guardCopy.validateForMoveOrRename(
                source: canonicalSource,
                destination: canonicalDestination,
                expectedSourceCanonicalParent: expectedSourceCanonicalParent
            ) {
                throw Self.mapGuardReason(
                    reason,
                    source: srcStd.path,
                    destination: destination.path,
                    expectedParent: expectedSourceCanonicalParent,
                    actualParent: srcCanonicalParent
                )
            }

            var dstProbe = stat()
            if fstatat(dstParentFD, sourceName, &dstProbe, AT_SYMLINK_NOFOLLOW) == 0 {
                throw FileOperationError.destinationAlreadyExists(path: destination.path)
            } else if errno != ENOENT {
                throw Self.mapPOSIXError(errno, path: destination.path)
            }

            if renameatx_np(srcParentFD, sourceName, dstParentFD, sourceName, UInt32(RENAME_EXCL)) == 0 {
                return destination
            }

            let err = errno
            switch err {
            case EEXIST:
                throw FileOperationError.destinationAlreadyExists(path: destination.path)
            case EACCES, EPERM, EROFS:
                throw FileOperationError.permissionDenied(path: destination.path, detail: String(cString: strerror(err)))
            case EINVAL:
                throw FileOperationError.cannotMoveDirectoryIntoItself(source: srcStd.path, destination: destination.path)
            case ENOTSUP:
                var probe = stat()
                if fstatat(dstParentFD, sourceName, &probe, AT_SYMLINK_NOFOLLOW) == 0 {
                    throw FileOperationError.destinationAlreadyExists(path: destination.path)
                }
                if renameat(srcParentFD, sourceName, dstParentFD, sourceName) == 0 {
                    return destination
                }
                let fallbackErr = errno
                if fallbackErr == EXDEV {
                    try Self.moveAcrossVolumesConfined(
                        srcParentFD: srcParentFD,
                        srcName: sourceName,
                        dstParentFD: dstParentFD,
                        dstName: sourceName,
                        srcDisplayPath: srcStd.path,
                        dstDisplayPath: destination.path
                    )
                    return destination
                }
                throw Self.mapPOSIXError(fallbackErr, path: destination.path)
            case EXDEV:
                try Self.moveAcrossVolumesConfined(
                    srcParentFD: srcParentFD,
                    srcName: sourceName,
                    dstParentFD: dstParentFD,
                    dstName: sourceName,
                    srcDisplayPath: srcStd.path,
                    dstDisplayPath: destination.path
                )
                return destination
            default:
                throw Self.mapPOSIXError(err, path: destination.path)
            }
        }.value
    }

    public func renameItem(
        at source: URL,
        toNewName newName: String,
        expectedSourceCanonicalParent: String
    ) async throws -> URL {
        try Self.validateItemName(newName)
        try Self.validateRawFileURL(source)

        let srcStd = source.standardizedFileURL
        let oldName = srcStd.lastPathComponent
        try Self.validateItemName(oldName)

        if oldName == newName {
            throw FileOperationError.destinationAlreadyExists(path: srcStd.path)
        }

        let parentURL = srcStd.deletingLastPathComponent()
        let destination = parentURL.appendingPathComponent(newName)
        try validateMoveOrRenameWithGuard(
            source: srcStd,
            destination: destination,
            expectedSourceCanonicalParent: expectedSourceCanonicalParent
        )

        let guardCopy = safetyGuard
        return try await Task.detached(priority: .userInitiated) {
            let parentFD = open(parentURL.path, O_SEARCH | O_DIRECTORY)
            if parentFD < 0 {
                let err = errno
                if err == ENOENT || err == ENOTDIR {
                    throw FileOperationError.sourceNotFound(path: srcStd.path)
                }
                throw Self.mapPOSIXError(err, path: parentURL.path)
            }
            defer { close(parentFD) }

            let canonicalParent = try Self.canonicalPath(forFD: parentFD, fallbackPath: parentURL.path)
            if canonicalParent != expectedSourceCanonicalParent {
                throw FileOperationError.toctouMismatch(
                    path: srcStd.path,
                    expectedParent: expectedSourceCanonicalParent,
                    actualParent: canonicalParent
                )
            }

            let canonicalSource = URL(fileURLWithPath: canonicalParent).appendingPathComponent(oldName)
            let canonicalDestination = URL(fileURLWithPath: canonicalParent).appendingPathComponent(newName)
            if case let .blocked(reason) = guardCopy.validateForMoveOrRename(
                source: canonicalSource,
                destination: canonicalDestination,
                expectedSourceCanonicalParent: expectedSourceCanonicalParent
            ) {
                throw Self.mapGuardReason(
                    reason,
                    source: srcStd.path,
                    destination: destination.path,
                    expectedParent: expectedSourceCanonicalParent,
                    actualParent: canonicalParent
                )
            }

            var srcStat = stat()
            if fstatat(parentFD, oldName, &srcStat, AT_SYMLINK_NOFOLLOW) != 0 {
                let err = errno
                if err == ENOENT {
                    throw FileOperationError.sourceNotFound(path: srcStd.path)
                }
                throw Self.mapPOSIXError(err, path: srcStd.path)
            }
            try Self.ensureNotSIPOrUserLocked(stat: srcStat, path: srcStd.path)

            var dstStat = stat()
            if fstatat(parentFD, newName, &dstStat, AT_SYMLINK_NOFOLLOW) == 0 {
                let isCaseOnlyRename = dstStat.st_dev == srcStat.st_dev
                    && dstStat.st_ino == srcStat.st_ino
                    && ((srcStat.st_mode & S_IFMT) != S_IFREG || srcStat.st_nlink == 1)
                    && oldName.precomposedStringWithCanonicalMapping.lowercased()
                        == newName.precomposedStringWithCanonicalMapping.lowercased()
                    && oldName != newName
                guard isCaseOnlyRename else {
                    throw FileOperationError.destinationAlreadyExists(path: destination.path)
                }
                if renameat(parentFD, oldName, parentFD, newName) != 0 {
                    throw Self.mapPOSIXError(errno, path: destination.path)
                }
                return destination
            } else if errno != ENOENT {
                throw Self.mapPOSIXError(errno, path: destination.path)
            }

            if renameatx_np(parentFD, oldName, parentFD, newName, UInt32(RENAME_EXCL)) == 0 {
                return destination
            }

            let err = errno
            if err == ENOTSUP {
                if renameat(parentFD, oldName, parentFD, newName) == 0 {
                    return destination
                }
                throw Self.mapPOSIXError(errno, path: destination.path)
            }
            if err == EEXIST {
                throw FileOperationError.destinationAlreadyExists(path: destination.path)
            }
            throw Self.mapPOSIXError(err, path: destination.path)
        }.value
    }

    public func createDirectory(
        named name: String,
        in parentDirectory: URL,
        expectedParentCanonicalParent: String? = nil
    ) async throws -> URL {
        try Self.validateItemName(name)
        try Self.validateRawFileURL(parentDirectory)

        let parentStd = parentDirectory.standardizedFileURL
        let destination = parentStd.appendingPathComponent(name)
        if case let .blocked(reason) = safetyGuard.validateDirectoryCreation(at: destination) {
            throw Self.mapGuardReason(
                reason,
                source: destination.path,
                destination: destination.path,
                expectedParent: expectedParentCanonicalParent
            )
        }

        let guardCopy = safetyGuard
        return try await Task.detached(priority: .userInitiated) {
            let parentFD = open(parentStd.path, O_SEARCH | O_DIRECTORY)
            if parentFD < 0 {
                let err = errno
                if err == ENOENT {
                    throw FileOperationError.destinationParentNotFound(path: parentStd.path)
                }
                if err == ENOTDIR {
                    throw FileOperationError.destinationNotADirectory(path: parentStd.path)
                }
                throw Self.mapPOSIXError(err, path: parentStd.path)
            }
            defer { close(parentFD) }

            let canonicalParent = try Self.canonicalPath(forFD: parentFD, fallbackPath: parentStd.path)
            if let expectedParentCanonicalParent, canonicalParent != expectedParentCanonicalParent {
                throw FileOperationError.toctouMismatch(
                    path: parentStd.path,
                    expectedParent: expectedParentCanonicalParent,
                    actualParent: canonicalParent
                )
            }

            let canonicalDestination = URL(fileURLWithPath: canonicalParent).appendingPathComponent(name)
            if case let .blocked(reason) = guardCopy.validateDirectoryCreation(at: canonicalDestination) {
                throw Self.mapGuardReason(
                    reason,
                    source: destination.path,
                    destination: destination.path,
                    expectedParent: expectedParentCanonicalParent,
                    actualParent: canonicalParent
                )
            }

            if mkdirat(parentFD, name, 0o755) != 0 {
                let err = errno
                if err == EEXIST {
                    throw FileOperationError.destinationAlreadyExists(path: destination.path)
                }
                throw Self.mapPOSIXError(err, path: destination.path)
            }
            return destination
        }.value
    }

    public func inspectMetadata(at url: URL) throws -> FileMetadataInfo {
        try Self.validateRawFileURL(url)
        let stdURL = url.standardizedFileURL
        let path = stdURL.path
        guard !path.isEmpty, !path.contains("\0") else {
            throw FileOperationError.invalidName(name: path, reason: "Invalid file URL")
        }

        var st = stat()
        if lstat(path, &st) != 0 {
            let err = errno
            if err == ENOENT {
                throw FileOperationError.sourceNotFound(path: path)
            }
            throw Self.mapPOSIXError(err, path: path)
        }

        let fileType = st.st_mode & S_IFMT
        let isSymbolicLink = (fileType == S_IFLNK)
        let isDirectory = (fileType == S_IFDIR)
        let isRegular = (fileType == S_IFREG)

        let isPackage: Bool
        if isDirectory {
            isPackage = (try? stdURL.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        } else {
            isPackage = false
        }

        let kind: FileItemKind
        if isSymbolicLink {
            kind = .symbolicLink
        } else if isPackage {
            kind = .package
        } else if isDirectory {
            kind = .directory
        } else if isRegular {
            kind = .regularFile
        } else {
            kind = .special
        }

        var symlinkTarget: String?
        var isSymlinkBroken = false
        var resolvedTargetPath: String?
        if isSymbolicLink {
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let len = readlink(path, &buf, buf.count - 1)
            if len >= 0 {
                symlinkTarget = String(decoding: buf[0..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            var targetStat = stat()
            isSymlinkBroken = (stat(path, &targetStat) != 0)
            if !isSymlinkBroken {
                resolvedTargetPath = SafetyGuard.posixRealpath(path)
            }
        }

        let allocatedSizeBytes: Int64?
        if isSymbolicLink || fileType == S_IFIFO || fileType == S_IFSOCK || fileType == S_IFCHR || fileType == S_IFBLK {
            allocatedSizeBytes = nil
        } else {
            allocatedSizeBytes = Int64(st.st_blocks) * 512
        }

        let utType: UTType?
        if isSymbolicLink {
            utType = .symbolicLink
        } else if isPackage {
            utType = UTType(filenameExtension: stdURL.pathExtension) ?? .package
        } else if isDirectory {
            utType = .folder
        } else if isRegular {
            let ext = stdURL.pathExtension
            utType = ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data)
        } else {
            utType = nil
        }

        let fallbackKind: String
        switch kind {
        case .symbolicLink: fallbackKind = "Symbolic Link"
        case .package: fallbackKind = "Package"
        case .directory: fallbackKind = "Folder"
        case .regularFile: fallbackKind = "Document"
        case .special: fallbackKind = "Special File"
        }

        return FileMetadataInfo(
            url: stdURL,
            name: stdURL.lastPathComponent,
            kind: kind,
            sizeBytes: Int64(st.st_size),
            allocatedSizeBytes: allocatedSizeBytes,
            createdDate: Self.dateFromTimespec(st.st_birthtimespec),
            modifiedDate: Self.dateFromTimespec(st.st_mtimespec),
            accessedDate: Self.dateFromTimespec(st.st_atimespec),
            posixPermissions: UInt16(st.st_mode & 0o7777),
            ownerUID: st.st_uid,
            groupGID: st.st_gid,
            isDirectory: isDirectory,
            isPackage: isPackage,
            isSymbolicLink: isSymbolicLink,
            isSymlinkBroken: isSymlinkBroken,
            symlinkTarget: symlinkTarget,
            resolvedTargetPath: resolvedTargetPath,
            isUserImmutable: (st.st_flags & UInt32(UF_IMMUTABLE)) != 0,
            isSIPRestricted: (st.st_flags & Self.kernelSIPFlagMask) != 0,
            isHidden: stdURL.lastPathComponent.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0,
            isDataless: (st.st_flags & UInt32(SF_DATALESS)) != 0,
            utiIdentifier: utType?.identifier,
            kindDescription: utType?.localizedDescription ?? fallbackKind,
            expectedCanonicalParent: PrivilegedExecutor.canonicalParentPath(forTargetURL: stdURL)
        )
    }

    // MARK: - Internal & Private Helpers

    private static func validateRawFileURL(_ url: URL) throws {
        let rawPath = url.path
        guard url.isFileURL,
              !rawPath.isEmpty,
              !rawPath.contains("\0"),
              !url.absoluteString.lowercased().contains("%00") else {
            throw FileOperationError.invalidName(name: rawPath, reason: "Invalid file URL")
        }
        if SafetyGuard.hasDotDotPathComponent(url) {
            throw FileOperationError.invalidName(name: rawPath, reason: "Path cannot contain '..'")
        }
        if url.pathComponents.contains(".") {
            throw FileOperationError.invalidName(name: rawPath, reason: "Path cannot contain '.'")
        }
    }

    public static func validateItemName(_ name: String) throws {
        if name.isEmpty {
            throw FileOperationError.invalidName(name: name, reason: "Name cannot be empty")
        }
        if name == "." || name == ".." {
            throw FileOperationError.invalidName(name: name, reason: "Name cannot be '.' or '..'")
        }
        if name.contains("/") {
            throw FileOperationError.invalidName(name: name, reason: "Name cannot contain '/'")
        }
        if name.contains("\0") {
            throw FileOperationError.invalidName(name: name, reason: "Name cannot contain NUL character")
        }
        if name.utf8.count > Int(NAME_MAX) {
            throw FileOperationError.invalidName(name: name, reason: "Name exceeds \(NAME_MAX) UTF-8 bytes")
        }
    }

    private func validateMoveOrRenameWithGuard(
        source: URL,
        destination: URL,
        expectedSourceCanonicalParent: String
    ) throws {
        if case let .blocked(reason) = safetyGuard.validateForMoveOrRename(
            source: source,
            destination: destination,
            expectedSourceCanonicalParent: expectedSourceCanonicalParent
        ) {
            throw Self.mapGuardReason(
                reason,
                source: source.path,
                destination: destination.path,
                expectedParent: expectedSourceCanonicalParent
            )
        }
    }

    private static func mapGuardReason(
        _ reason: String,
        source: String,
        destination: String,
        expectedParent: String? = nil,
        actualParent: String? = nil
    ) -> FileOperationError {
        if reason.contains("TOCTOU") {
            let actual = actualParent ?? SafetyGuard.canonicalPathResolvingDeepestAncestor(
                for: URL(fileURLWithPath: source).standardizedFileURL.deletingLastPathComponent()
            )
            return .toctouMismatch(path: source, expectedParent: expectedParent ?? "", actualParent: actual)
        }
        if reason.contains("Cannot move a directory into itself") {
            return .cannotMoveDirectoryIntoItself(source: source, destination: destination)
        }
        if reason.hasPrefix("Destination already exists:")
            || reason.hasPrefix("An item already exists at destination:") {
            return .destinationAlreadyExists(path: destination)
        }
        return .blockedBySafetyGuard(path: destination, reason: reason)
    }

    private static func canonicalPath(forFD fd: Int32, fallbackPath: String) throws -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buf) == 0 else {
            throw mapPOSIXError(errno, path: fallbackPath)
        }
        let nulIndex = buf.firstIndex(of: 0) ?? buf.count
        return String(decoding: buf[..<nulIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func ensureNotSIPOrUserLocked(stat st: stat, path: String) throws {
        if (st.st_flags & kernelSIPFlagMask) != 0 {
            throw FileOperationError.blockedBySafetyGuard(
                path: path,
                reason: "Protected by macOS System Integrity Protection (SIP)"
            )
        }
        if (st.st_flags & UInt32(UF_IMMUTABLE)) != 0 {
            throw FileOperationError.userImmutable(path: path)
        }
    }

    private static func dateFromTimespec(_ ts: timespec) -> Date? {
        guard ts.tv_sec != 0 || ts.tv_nsec != 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000.0)
    }

    private static func mapPOSIXError(_ code: Int32, path: String) -> FileOperationError {
        let detail = String(cString: strerror(code))
        switch code {
        case EACCES, EPERM, EROFS:
            return .permissionDenied(path: path, detail: detail)
        case EEXIST:
            return .destinationAlreadyExists(path: path)
        default:
            return .posixError(code: code, path: path, detail: detail)
        }
    }

    private struct DeferredDirectoryMetadata {
        let relativePath: String
        let mode: mode_t
        let atime: timespec
        let mtime: timespec
    }

    /// Confined cross-volume (`EXDEV`) move helper: copies into a hidden staging entry inside
    /// `dstParentFD` with metadata preservation (`fcopyfile` / `futimens`) and bounded FD usage
    /// (`closedir` before descending), atomically commits via `renameatx_np(..., RENAME_EXCL)`,
    /// and unlinks source only after commit succeeds. Exposed `internal` so tests can verify
    /// cross-volume staging directly.
    internal static func moveAcrossVolumesConfined(
        srcParentFD: Int32,
        srcName: String,
        dstParentFD: Int32,
        dstName: String,
        srcDisplayPath: String,
        dstDisplayPath: String
    ) throws {
        let stageName = ".macsweep-move.\(UUID().uuidString)"
        var deferredDirs: [DeferredDirectoryMetadata] = []
        do {
            try copyEntryConfined(
                srcParentFD: srcParentFD,
                srcName: srcName,
                dstParentFD: dstParentFD,
                dstName: stageName,
                depth: 0,
                relativePath: "",
                deferredDirs: &deferredDirs,
                srcDisplayPath: srcDisplayPath,
                dstDisplayPath: dstDisplayPath
            )
            try applyDeferredDirectoryMetadata(
                deferredDirs,
                baseParentFD: dstParentFD,
                stageName: stageName,
                srcDisplayPath: srcDisplayPath,
                dstDisplayPath: dstDisplayPath
            )

            if renameatx_np(dstParentFD, stageName, dstParentFD, dstName, UInt32(RENAME_EXCL)) != 0 {
                let err = errno
                if err == ENOTSUP {
                    var probe = stat()
                    if fstatat(dstParentFD, dstName, &probe, AT_SYMLINK_NOFOLLOW) == 0 {
                        throw FileOperationError.destinationAlreadyExists(path: dstDisplayPath)
                    }
                    if renameat(dstParentFD, stageName, dstParentFD, dstName) != 0 {
                        throw FileOperationError.crossVolumeMoveFailed(
                            source: srcDisplayPath,
                            destination: dstDisplayPath,
                            detail: String(cString: strerror(errno))
                        )
                    }
                } else if err == EEXIST {
                    throw FileOperationError.destinationAlreadyExists(path: dstDisplayPath)
                } else {
                    throw FileOperationError.crossVolumeMoveFailed(
                        source: srcDisplayPath,
                        destination: dstDisplayPath,
                        detail: String(cString: strerror(err))
                    )
                }
            }
        } catch {
            try? removeEntryTreeConfined(parentFD: dstParentFD, name: stageName)
            throw error
        }

        do {
            try removeEntryTreeConfined(parentFD: srcParentFD, name: srcName)
        } catch {
            throw FileOperationError.crossVolumeMoveFailed(
                source: srcDisplayPath,
                destination: dstDisplayPath,
                detail: "Copied to destination, but failed to remove source: \(error.localizedDescription)"
            )
        }
    }

    private static func copyEntryConfined(
        srcParentFD: Int32,
        srcName: String,
        dstParentFD: Int32,
        dstName: String,
        depth: Int,
        relativePath: String,
        deferredDirs: inout [DeferredDirectoryMetadata],
        srcDisplayPath: String,
        dstDisplayPath: String
    ) throws {
        guard depth <= maxCrossVolumeDepth else {
            throw FileOperationError.crossVolumeMoveFailed(
                source: srcDisplayPath,
                destination: dstDisplayPath,
                detail: "Maximum directory depth exceeded"
            )
        }

        var st = stat()
        guard fstatat(srcParentFD, srcName, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw FileOperationError.crossVolumeMoveFailed(
                source: srcDisplayPath,
                destination: dstDisplayPath,
                detail: String(cString: strerror(errno))
            )
        }
        try ensureNotSIPOrUserLocked(stat: st, path: srcDisplayPath)

        switch st.st_mode & S_IFMT {
        case S_IFLNK:
            var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let len = readlinkat(srcParentFD, srcName, &buf, buf.count - 1)
            guard len >= 0 else {
                throw FileOperationError.crossVolumeMoveFailed(
                    source: srcDisplayPath,
                    destination: dstDisplayPath,
                    detail: String(cString: strerror(errno))
                )
            }
            buf[len] = 0
            guard symlinkat(&buf, dstParentFD, dstName) == 0 else {
                throw FileOperationError.crossVolumeMoveFailed(
                    source: srcDisplayPath,
                    destination: dstDisplayPath,
                    detail: String(cString: strerror(errno))
                )
            }

        case S_IFREG:
            try copyRegularFileConfined(
                srcParentFD: srcParentFD,
                srcName: srcName,
                dstParentFD: dstParentFD,
                dstName: dstName,
                expectedStat: st,
                srcDisplayPath: srcDisplayPath,
                dstDisplayPath: dstDisplayPath
            )

        case S_IFDIR:
            try copyDirectoryTreeIteratively(
                rootSrcParentFD: srcParentFD,
                rootSrcName: srcName,
                rootDstParentFD: dstParentFD,
                rootDstName: dstName,
                initialDepth: depth,
                initialRelativePath: relativePath,
                deferredDirs: &deferredDirs,
                srcRootDisplayPath: srcDisplayPath,
                dstRootDisplayPath: dstDisplayPath
            )

        default:
            throw FileOperationError.crossVolumeMoveFailed(
                source: srcDisplayPath,
                destination: dstDisplayPath,
                detail: "Unsupported special file type for cross-volume move"
            )
        }
    }

    private static func copyRegularFileConfined(
        srcParentFD: Int32,
        srcName: String,
        dstParentFD: Int32,
        dstName: String,
        expectedStat st: stat,
        srcDisplayPath: String,
        dstDisplayPath: String
    ) throws {
        let inFD = openat(srcParentFD, srcName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard inFD >= 0 else {
            throw FileOperationError.crossVolumeMoveFailed(
                source: srcDisplayPath,
                destination: dstDisplayPath,
                detail: String(cString: strerror(errno))
            )
        }
        defer { close(inFD) }

        var inStat = stat()
        guard fstat(inFD, &inStat) == 0, (inStat.st_mode & S_IFMT) == S_IFREG else {
            throw FileOperationError.crossVolumeMoveFailed(
                source: srcDisplayPath,
                destination: dstDisplayPath,
                detail: "Source changed during cross-volume copy"
            )
        }

        let fileMode = mode_t(inStat.st_mode & 0o7777)
        let outFD = openat(
            dstParentFD,
            dstName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            fileMode | 0o200
        )
        guard outFD >= 0 else {
            throw FileOperationError.crossVolumeMoveFailed(
                source: srcDisplayPath,
                destination: dstDisplayPath,
                detail: String(cString: strerror(errno))
            )
        }
        defer { close(outFD) }

        var copiedViaCopyfile = false
        if fcopyfile(inFD, outFD, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 {
            copiedViaCopyfile = true
        } else {
            let err = errno
            if err == ENOTSUP || err == EPERM || err == EACCES || err == EINVAL {
                _ = lseek(inFD, 0, SEEK_SET)
                _ = lseek(outFD, 0, SEEK_SET)
                _ = ftruncate(outFD, 0)
                if fcopyfile(inFD, outFD, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_STAT)) == 0 {
                    copiedViaCopyfile = true
                }
            } else {
                throw FileOperationError.crossVolumeMoveFailed(
                    source: srcDisplayPath,
                    destination: dstDisplayPath,
                    detail: String(cString: strerror(err))
                )
            }
        }

        if !copiedViaCopyfile {
            _ = lseek(inFD, 0, SEEK_SET)
            _ = lseek(outFD, 0, SEEK_SET)
            _ = ftruncate(outFD, 0)

            let bufSize = 64 * 1024
            var buffer = [UInt8](repeating: 0, count: bufSize)
            while true {
                let bytesRead = read(inFD, &buffer, bufSize)
                if bytesRead == 0 { break }
                if bytesRead < 0 {
                    if errno == EINTR { continue }
                    throw FileOperationError.crossVolumeMoveFailed(
                        source: srcDisplayPath,
                        destination: dstDisplayPath,
                        detail: String(cString: strerror(errno))
                    )
                }
                var offset = 0
                while offset < bytesRead {
                    let written = buffer.withUnsafeBytes { rawBuf -> Int in
                        guard let base = rawBuf.baseAddress else { return -1 }
                        return write(outFD, base.advanced(by: offset), bytesRead - offset)
                    }
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw FileOperationError.crossVolumeMoveFailed(
                            source: srcDisplayPath,
                            destination: dstDisplayPath,
                            detail: String(cString: strerror(errno))
                        )
                    }
                    offset += written
                }
            }
        }

        var times: [timespec] = [inStat.st_atimespec, inStat.st_mtimespec]
        _ = futimens(outFD, &times)
        if fchmod(outFD, fileMode) != 0, errno != ENOTSUP {
            throw FileOperationError.crossVolumeMoveFailed(
                source: srcDisplayPath,
                destination: dstDisplayPath,
                detail: String(cString: strerror(errno))
            )
        }
        _ = fsync(outFD)
        _ = st
    }

    private static func copyDirectoryTreeIteratively(
        rootSrcParentFD: Int32,
        rootSrcName: String,
        rootDstParentFD: Int32,
        rootDstName: String,
        initialDepth: Int,
        initialRelativePath: String,
        deferredDirs: inout [DeferredDirectoryMetadata],
        srcRootDisplayPath: String,
        dstRootDisplayPath: String
    ) throws {
        var rootSt = stat()
        guard fstatat(rootSrcParentFD, rootSrcName, &rootSt, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw FileOperationError.crossVolumeMoveFailed(
                source: srcRootDisplayPath,
                destination: dstRootDisplayPath,
                detail: String(cString: strerror(errno))
            )
        }
        let rootMode = mode_t(rootSt.st_mode & 0o7777)
        guard mkdirat(rootDstParentFD, rootDstName, rootMode | 0o700) == 0 else {
            throw FileOperationError.crossVolumeMoveFailed(
                source: srcRootDisplayPath,
                destination: dstRootDisplayPath,
                detail: String(cString: strerror(errno))
            )
        }

        let srcRootFD = openat(rootSrcParentFD, rootSrcName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard srcRootFD >= 0 else {
            throw FileOperationError.crossVolumeMoveFailed(
                source: srcRootDisplayPath,
                destination: dstRootDisplayPath,
                detail: String(cString: strerror(errno))
            )
        }
        defer { close(srcRootFD) }

        let dstRootFD = openat(rootDstParentFD, rootDstName, O_SEARCH | O_DIRECTORY | O_NOFOLLOW)
        guard dstRootFD >= 0 else {
            throw FileOperationError.crossVolumeMoveFailed(
                source: srcRootDisplayPath,
                destination: dstRootDisplayPath,
                detail: String(cString: strerror(errno))
            )
        }
        defer { close(dstRootFD) }

        _ = fcopyfile(srcRootFD, dstRootFD, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL))
        deferredDirs.append(DeferredDirectoryMetadata(
            relativePath: initialRelativePath,
            mode: rootMode,
            atime: rootSt.st_atimespec,
            mtime: rootSt.st_mtimespec
        ))

        struct WorkItem {
            let relativeComponents: [String]
            let depth: Int
        }

        var stack: [WorkItem] = [WorkItem(relativeComponents: [], depth: initialDepth)]

        while let item = stack.popLast() {
            let relDisplaySuffix = item.relativeComponents.isEmpty ? "" : "/" + item.relativeComponents.joined(separator: "/")
            let curSrcDisplay = srcRootDisplayPath + relDisplaySuffix
            let curDstDisplay = dstRootDisplayPath + relDisplaySuffix

            let curSrcFD = try openRelativeDirectoryConfined(
                baseFD: srcRootFD,
                components: item.relativeComponents,
                flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW,
                srcDisplayPath: curSrcDisplay,
                dstDisplayPath: curDstDisplay
            )
            let curDstFD: Int32
            do {
                curDstFD = try openRelativeDirectoryConfined(
                    baseFD: dstRootFD,
                    components: item.relativeComponents,
                    flags: O_SEARCH | O_DIRECTORY | O_NOFOLLOW,
                    srcDisplayPath: curSrcDisplay,
                    dstDisplayPath: curDstDisplay
                )
            } catch {
                close(curSrcFD)
                throw error
            }
            defer { close(curDstFD) }

            let scanFD = dup(curSrcFD)
            guard scanFD >= 0 else {
                let err = errno
                close(curSrcFD)
                throw FileOperationError.crossVolumeMoveFailed(
                    source: curSrcDisplay,
                    destination: curDstDisplay,
                    detail: String(cString: strerror(err))
                )
            }
            guard let dirStream = fdopendir(scanFD) else {
                let err = errno
                close(scanFD)
                close(curSrcFD)
                throw FileOperationError.crossVolumeMoveFailed(
                    source: curSrcDisplay,
                    destination: curDstDisplay,
                    detail: String(cString: strerror(err))
                )
            }
            var childNames: [String] = []
            while let entryPtr = readdir(dirStream) {
                let name = withUnsafePointer(to: &entryPtr.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                        String(cString: $0)
                    }
                }
                if name == "." || name == ".." { continue }
                childNames.append(name)
            }
            closedir(dirStream)
            defer { close(curSrcFD) }

            for name in childNames {
                let childDepth = item.depth + 1
                guard childDepth <= maxCrossVolumeDepth else {
                    throw FileOperationError.crossVolumeMoveFailed(
                        source: "\(curSrcDisplay)/\(name)",
                        destination: "\(curDstDisplay)/\(name)",
                        detail: "Maximum directory depth exceeded"
                    )
                }

                let childSrcDisplay = "\(curSrcDisplay)/\(name)"
                let childDstDisplay = "\(curDstDisplay)/\(name)"

                var childSt = stat()
                guard fstatat(curSrcFD, name, &childSt, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw FileOperationError.crossVolumeMoveFailed(
                        source: childSrcDisplay,
                        destination: childDstDisplay,
                        detail: String(cString: strerror(errno))
                    )
                }
                try ensureNotSIPOrUserLocked(stat: childSt, path: childSrcDisplay)

                switch childSt.st_mode & S_IFMT {
                case S_IFLNK:
                    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
                    let len = readlinkat(curSrcFD, name, &buf, buf.count - 1)
                    guard len >= 0 else {
                        throw FileOperationError.crossVolumeMoveFailed(
                            source: childSrcDisplay,
                            destination: childDstDisplay,
                            detail: String(cString: strerror(errno))
                        )
                    }
                    buf[len] = 0
                    guard symlinkat(&buf, curDstFD, name) == 0 else {
                        throw FileOperationError.crossVolumeMoveFailed(
                            source: childSrcDisplay,
                            destination: childDstDisplay,
                            detail: String(cString: strerror(errno))
                        )
                    }

                case S_IFREG:
                    try copyRegularFileConfined(
                        srcParentFD: curSrcFD,
                        srcName: name,
                        dstParentFD: curDstFD,
                        dstName: name,
                        expectedStat: childSt,
                        srcDisplayPath: childSrcDisplay,
                        dstDisplayPath: childDstDisplay
                    )

                case S_IFDIR:
                    let origMode = mode_t(childSt.st_mode & 0o7777)
                    guard mkdirat(curDstFD, name, origMode | 0o700) == 0 else {
                        throw FileOperationError.crossVolumeMoveFailed(
                            source: childSrcDisplay,
                            destination: childDstDisplay,
                            detail: String(cString: strerror(errno))
                        )
                    }
                    let childSrcSubFD = openat(curSrcFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    if childSrcSubFD >= 0 {
                        let childDstSubFD = openat(curDstFD, name, O_SEARCH | O_DIRECTORY | O_NOFOLLOW)
                        if childDstSubFD >= 0 {
                            _ = fcopyfile(childSrcSubFD, childDstSubFD, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL))
                            close(childDstSubFD)
                        }
                        close(childSrcSubFD)
                    }
                    let nextComponents = item.relativeComponents + [name]
                    let childRelPath = initialRelativePath.isEmpty
                        ? nextComponents.joined(separator: "/")
                        : "\(initialRelativePath)/\(nextComponents.joined(separator: "/"))"
                    deferredDirs.append(DeferredDirectoryMetadata(
                        relativePath: childRelPath,
                        mode: origMode,
                        atime: childSt.st_atimespec,
                        mtime: childSt.st_mtimespec
                    ))
                    stack.append(WorkItem(relativeComponents: nextComponents, depth: childDepth))

                default:
                    throw FileOperationError.crossVolumeMoveFailed(
                        source: childSrcDisplay,
                        destination: childDstDisplay,
                        detail: "Unsupported special file type for cross-volume move"
                    )
                }
            }
        }
    }

    private static func openRelativeDirectoryConfined(
        baseFD: Int32,
        components: [String],
        flags: Int32,
        srcDisplayPath: String,
        dstDisplayPath: String
    ) throws -> Int32 {
        if components.isEmpty {
            let dupFD = dup(baseFD)
            guard dupFD >= 0 else {
                throw FileOperationError.crossVolumeMoveFailed(
                    source: srcDisplayPath,
                    destination: dstDisplayPath,
                    detail: String(cString: strerror(errno))
                )
            }
            return dupFD
        }
        var currentFD = baseFD
        var ownsCurrent = false
        for (idx, comp) in components.enumerated() {
            let isLast = idx == components.count - 1
            let openFlags = isLast ? flags : (O_SEARCH | O_DIRECTORY | O_NOFOLLOW)
            let nextFD = openat(currentFD, comp, openFlags)
            if ownsCurrent {
                close(currentFD)
            }
            guard nextFD >= 0 else {
                throw FileOperationError.crossVolumeMoveFailed(
                    source: srcDisplayPath,
                    destination: dstDisplayPath,
                    detail: String(cString: strerror(errno))
                )
            }
            currentFD = nextFD
            ownsCurrent = true
        }
        return currentFD
    }

    private static func applyDeferredDirectoryMetadata(
        _ entries: [DeferredDirectoryMetadata],
        baseParentFD: Int32,
        stageName: String,
        srcDisplayPath: String,
        dstDisplayPath: String
    ) throws {
        // Apply deepest children first so modifying children never resets parent timestamps or hits read-only modes.
        for entry in entries.reversed() {
            var currentFD = openat(baseParentFD, stageName, O_SEARCH | O_DIRECTORY | O_NOFOLLOW)
            guard currentFD >= 0 else {
                throw FileOperationError.crossVolumeMoveFailed(
                    source: srcDisplayPath,
                    destination: dstDisplayPath,
                    detail: String(cString: strerror(errno))
                )
            }
            if !entry.relativePath.isEmpty {
                for comp in entry.relativePath.split(separator: "/").map(String.init) {
                    let nextFD = openat(currentFD, comp, O_SEARCH | O_DIRECTORY | O_NOFOLLOW)
                    close(currentFD)
                    guard nextFD >= 0 else {
                        throw FileOperationError.crossVolumeMoveFailed(
                            source: srcDisplayPath,
                            destination: dstDisplayPath,
                            detail: String(cString: strerror(errno))
                        )
                    }
                    currentFD = nextFD
                }
            }
            defer { close(currentFD) }
            var times: [timespec] = [entry.atime, entry.mtime]
            _ = futimens(currentFD, &times)
            if fchmod(currentFD, entry.mode) != 0, errno != ENOTSUP {
                throw FileOperationError.crossVolumeMoveFailed(
                    source: srcDisplayPath,
                    destination: dstDisplayPath,
                    detail: String(cString: strerror(errno))
                )
            }
        }
    }

    private static func removeEntryTreeConfined(parentFD: Int32, name: String) throws {
        var st = stat()
        guard fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            let err = errno
            if err == ENOENT { return }
            throw mapPOSIXError(err, path: name)
        }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            let origMode = mode_t(st.st_mode & 0o7777)
            let needsChmod = (origMode & 0o700) != 0o700
            var didChmod = false

            var dirFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if dirFD < 0 && errno == EACCES && needsChmod {
                if fchmodat(parentFD, name, origMode | 0o700, AT_SYMLINK_NOFOLLOW) == 0 {
                    didChmod = true
                    dirFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                }
            }
            guard dirFD >= 0 else {
                throw mapPOSIXError(errno, path: name)
            }
            var dirClosed = false
            defer {
                if !dirClosed {
                    close(dirFD)
                }
            }

            if needsChmod && !didChmod {
                if fchmod(dirFD, origMode | 0o700) == 0 {
                    didChmod = true
                }
            }

            let scanFD = dup(dirFD)
            guard scanFD >= 0 else {
                let err = errno
                if didChmod { _ = fchmod(dirFD, origMode) }
                throw mapPOSIXError(err, path: name)
            }
            guard let stream = fdopendir(scanFD) else {
                let err = errno
                close(scanFD)
                if didChmod { _ = fchmod(dirFD, origMode) }
                throw mapPOSIXError(err, path: name)
            }
            var children: [String] = []
            while let entryPtr = readdir(stream) {
                let child = withUnsafePointer(to: &entryPtr.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                        String(cString: $0)
                    }
                }
                if child == "." || child == ".." { continue }
                children.append(child)
            }
            closedir(stream)

            do {
                for child in children {
                    try removeEntryTreeConfined(parentFD: dirFD, name: child)
                }
            } catch {
                if didChmod { _ = fchmod(dirFD, origMode) }
                throw error
            }

            close(dirFD)
            dirClosed = true

            if unlinkat(parentFD, name, AT_REMOVEDIR) != 0 {
                let err = errno
                if err != ENOENT {
                    if didChmod {
                        _ = fchmodat(parentFD, name, origMode, AT_SYMLINK_NOFOLLOW)
                    }
                    throw mapPOSIXError(err, path: name)
                }
            }
        } else {
            if unlinkat(parentFD, name, 0) != 0 {
                let err = errno
                if err != ENOENT {
                    throw mapPOSIXError(err, path: name)
                }
            }
        }
    }
}

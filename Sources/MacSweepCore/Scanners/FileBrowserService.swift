import Darwin
import Foundation
import UniformTypeIdentifiers

public struct FileBrowserService: Sendable {
    internal typealias StatProvider = @Sendable (_ path: String) -> stat?

    internal enum EnumerationMode: Sendable {
        case automatic
        case bulkOnly
        case fallbackOnly
    }

    public let safetyGuard: SafetyGuard
    public let fileOperationsEngine: FileOperationsEngine
    public let homeDirectory: URL

    private let statProvider: StatProvider?
    private let enumerationMode: EnumerationMode

    private static let kernelSIPFlagMask = UInt32(SF_RESTRICTED) | UInt32(SF_IMMUTABLE) | UInt32(SF_NOUNLINK)
    private static let bulkBufferSize = 128 * 1024

    public init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.safetyGuard = safetyGuard
        self.fileOperationsEngine = FileOperationsEngine(safetyGuard: safetyGuard)
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.statProvider = nil
        self.enumerationMode = .automatic
    }

    internal init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        statProvider: StatProvider? = nil,
        enumerationMode: EnumerationMode = .automatic
    ) {
        self.safetyGuard = safetyGuard
        self.fileOperationsEngine = FileOperationsEngine(safetyGuard: safetyGuard)
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.statProvider = statProvider
        self.enumerationMode = enumerationMode
    }

    // MARK: - Directory Listing

    public func listDirectory(
        at url: URL,
        showHidden: Bool = false,
        sortBy: FileBrowserSort = .name,
        ascending: Bool = true,
        searchQuery: String = ""
    ) throws -> [FileBrowserEntry] {
        let stdURL = try Self.validateDirectoryURL(url)
        let path = stdURL.path

        var lst = stat()
        if lstat(path, &lst) != 0 {
            let err = errno
            if err == ENOENT { throw FileBrowserError.notFound(path: path) }
            if err == EACCES || err == EPERM {
                let hasFDA = PermissionChecker.checkFullDiskAccess(homeDirectory: homeDirectory).hasFullDiskAccess
                throw FileBrowserError.tccOrPermissionDenied(path: path, needsFullDiskAccess: !hasFDA)
            }
            throw FileBrowserError.posixError(code: err, path: path, detail: String(cString: strerror(err)))
        }

        var st = stat()
        if stat(path, &st) != 0 {
            let err = errno
            if err == ENOENT { throw FileBrowserError.notFound(path: path) }
            if err == EACCES || err == EPERM {
                let hasFDA = PermissionChecker.checkFullDiskAccess(homeDirectory: homeDirectory).hasFullDiskAccess
                throw FileBrowserError.tccOrPermissionDenied(path: path, needsFullDiskAccess: !hasFDA)
            }
            throw FileBrowserError.posixError(code: err, path: path, detail: String(cString: strerror(err)))
        }

        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw FileBrowserError.notADirectory(path: path)
        }

        guard PermissionChecker.canReadDirectory(stdURL) else {
            let hasFDA = PermissionChecker.checkFullDiskAccess(homeDirectory: homeDirectory).hasFullDiskAccess
            throw FileBrowserError.tccOrPermissionDenied(path: path, needsFullDiskAccess: !hasFDA)
        }

        let canonicalParent = PrivilegedExecutor.canonicalParentPath(for: path)
        let rawEntries = try readEntries(at: stdURL)
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        var entries: [FileBrowserEntry] = []
        entries.reserveCapacity(rawEntries.count)

        for raw in rawEntries {
            let isHidden = raw.name.hasPrefix(".") || (raw.flags & UInt32(UF_HIDDEN)) != 0
            if !showHidden && isHidden {
                continue
            }
            if !query.isEmpty && !raw.name.localizedCaseInsensitiveContains(query) {
                continue
            }

            let childURL = stdURL.appendingPathComponent(raw.name)
            let isSymbolicLink = (raw.objType == UInt32(VLNK.rawValue))
            let isDir = (raw.objType == UInt32(VDIR.rawValue))
            let isRegular = (raw.objType == UInt32(VREG.rawValue))
            let isPackage = isDir ? Self.detectIsPackage(at: childURL) : false

            let kind: FileItemKind
            if isSymbolicLink {
                kind = .symbolicLink
            } else if isPackage {
                kind = .package
            } else if isDir {
                kind = .directory
            } else if isRegular {
                kind = .regularFile
            } else {
                kind = .special
            }

            let (utType, fallbackKind) = Self.classifyType(for: childURL, kind: kind)
            let validation = safetyGuard.validateForRemoval(childURL)
            let isProtected: Bool
            let protectionReason: String?
            switch validation {
            case .allowed:
                isProtected = false
                protectionReason = nil
            case let .blocked(reason):
                isProtected = true
                protectionReason = reason
            }

            entries.append(FileBrowserEntry(
                url: childURL,
                name: raw.name,
                kind: kind,
                sizeBytes: isRegular ? raw.dataLength : (isSymbolicLink ? raw.dataLength : 0),
                modificationDate: raw.modDate,
                createdDate: raw.crDate,
                isDirectory: isDir,
                isPackage: isPackage,
                isSymbolicLink: isSymbolicLink,
                isSymlinkBroken: raw.isSymlinkBroken,
                isHidden: isHidden,
                isDataless: (raw.flags & UInt32(SF_DATALESS)) != 0,
                isUserImmutable: (raw.flags & UInt32(UF_IMMUTABLE)) != 0,
                isSIPRestricted: (raw.flags & Self.kernelSIPFlagMask) != 0,
                isProtected: isProtected,
                protectionReason: protectionReason,
                requiresAdmin: safetyGuard.requiresAdmin(for: childURL),
                utiIdentifier: utType?.identifier,
                kindDescription: utType?.localizedDescription ?? fallbackKind,
                expectedCanonicalParent: canonicalParent
            ))
        }

        return Self.sortEntries(entries, by: sortBy, ascending: ascending)
    }

    // MARK: - Favorites

    public func quickFavorites() -> [FileBrowserFavorite] {
        var favorites: [FileBrowserFavorite] = [
            FileBrowserFavorite(
                kind: .home,
                title: homeDirectory.lastPathComponent.isEmpty ? "Home" : homeDirectory.lastPathComponent,
                url: homeDirectory,
                isAccessible: PermissionChecker.canReadDirectory(homeDirectory)
            ),
            FileBrowserFavorite(
                kind: .desktop,
                title: "Desktop",
                url: homeDirectory.appendingPathComponent("Desktop"),
                isAccessible: PermissionChecker.canReadDirectory(homeDirectory.appendingPathComponent("Desktop"))
            ),
            FileBrowserFavorite(
                kind: .documents,
                title: "Documents",
                url: homeDirectory.appendingPathComponent("Documents"),
                isAccessible: PermissionChecker.canReadDirectory(homeDirectory.appendingPathComponent("Documents"))
            ),
            FileBrowserFavorite(
                kind: .downloads,
                title: "Downloads",
                url: homeDirectory.appendingPathComponent("Downloads"),
                isAccessible: PermissionChecker.canReadDirectory(homeDirectory.appendingPathComponent("Downloads"))
            ),
            FileBrowserFavorite(
                kind: .applications,
                title: "Applications",
                url: URL(fileURLWithPath: "/Applications"),
                isAccessible: PermissionChecker.canReadDirectory(URL(fileURLWithPath: "/Applications"))
            ),
            FileBrowserFavorite(
                kind: .caches,
                title: "Caches",
                url: homeDirectory.appendingPathComponent("Library/Caches"),
                isAccessible: PermissionChecker.canReadDirectory(homeDirectory.appendingPathComponent("Library/Caches"))
            ),
        ]

        let volumes = DiskSpaceAnalyzer.mountedVolumes()
        for volume in volumes {
            favorites.append(FileBrowserFavorite(
                kind: .volume,
                title: volume.name,
                url: volume.url,
                isAccessible: PermissionChecker.canReadDirectory(volume.url)
            ))
        }

        return favorites
    }

    // MARK: - Metadata & Bounded Non-Blocking Preview

    public func inspectMetadata(at url: URL) throws -> FileMetadataInfo {
        try fileOperationsEngine.inspectMetadata(at: url)
    }

    public func loadPreview(
        at url: URL,
        maxTextBytes: Int = 65_536,
        maxImageBytes: Int = SafeFileReader.defaultMaxBytes
    ) throws -> FilePreviewPayload {
        var metadata = try inspectMetadata(at: url)
        if let overrideStat = statProvider?(metadata.url.path) {
            metadata = FileMetadataInfo(
                url: metadata.url,
                name: metadata.name,
                kind: metadata.kind,
                sizeBytes: Int64(overrideStat.st_size),
                allocatedSizeBytes: metadata.allocatedSizeBytes,
                createdDate: metadata.createdDate,
                modifiedDate: metadata.modifiedDate,
                accessedDate: metadata.accessedDate,
                posixPermissions: UInt16(overrideStat.st_mode & 0o7777),
                ownerUID: overrideStat.st_uid,
                groupGID: overrideStat.st_gid,
                isDirectory: metadata.isDirectory,
                isPackage: metadata.isPackage,
                isSymbolicLink: metadata.isSymbolicLink,
                isSymlinkBroken: metadata.isSymlinkBroken,
                symlinkTarget: metadata.symlinkTarget,
                resolvedTargetPath: metadata.resolvedTargetPath,
                isUserImmutable: (overrideStat.st_flags & UInt32(UF_IMMUTABLE)) != 0,
                isSIPRestricted: (overrideStat.st_flags & Self.kernelSIPFlagMask) != 0,
                isHidden: metadata.isHidden,
                isDataless: (overrideStat.st_flags & UInt32(SF_DATALESS)) != 0,
                utiIdentifier: metadata.utiIdentifier,
                kindDescription: metadata.kindDescription,
                expectedCanonicalParent: metadata.expectedCanonicalParent
            )
        }

        let validation = safetyGuard.validateForRemoval(metadata.url)
        let isProtected: Bool
        let protectionReason: String?
        switch validation {
        case .allowed:
            isProtected = false
            protectionReason = nil
        case let .blocked(reason):
            isProtected = true
            protectionReason = reason
        }

        // Strict pre-open gating order: never open dataless cloud items, directories, symlinks, or FIFOs/devices.
        if metadata.isDataless {
            return FilePreviewPayload(
                metadata: metadata,
                content: .unavailable(reason: .datalessCloudFile),
                isProtected: isProtected,
                protectionReason: protectionReason
            )
        }
        if metadata.kind == .directory || metadata.kind == .package {
            return FilePreviewPayload(
                metadata: metadata,
                content: .unavailable(reason: .directory),
                isProtected: isProtected,
                protectionReason: protectionReason
            )
        }
        if metadata.kind == .symbolicLink {
            return FilePreviewPayload(
                metadata: metadata,
                content: .unavailable(reason: .symbolicLink),
                isProtected: isProtected,
                protectionReason: protectionReason
            )
        }
        if metadata.kind == .special {
            return FilePreviewPayload(
                metadata: metadata,
                content: .unavailable(reason: .specialFile),
                isProtected: isProtected,
                protectionReason: protectionReason
            )
        }
        if metadata.sizeBytes == 0 {
            return FilePreviewPayload(
                metadata: metadata,
                content: .unavailable(reason: .emptyFile),
                isProtected: isProtected,
                protectionReason: protectionReason
            )
        }

        if let uti = metadata.utiIdentifier,
           let type = UTType(uti),
           type.conforms(to: .image) {
            let readRes = SafeFileReader.readBoundedRegularFileDetailed(at: metadata.url, maxBytes: maxImageBytes)
            switch readRes {
            case let .success(data):
                return FilePreviewPayload(
                    metadata: metadata,
                    content: .image(data, utiIdentifier: metadata.utiIdentifier, byteCount: data.count),
                    isProtected: isProtected,
                    protectionReason: protectionReason
                )
            case let .oversized(actualSize, maxBytes):
                return FilePreviewPayload(
                    metadata: metadata,
                    content: .unavailable(reason: .imageTooLarge(actualBytes: actualSize, maxBytes: maxBytes)),
                    isProtected: isProtected,
                    protectionReason: protectionReason
                )
            case .notFound:
                return FilePreviewPayload(
                    metadata: metadata,
                    content: .unavailable(reason: .notFound),
                    isProtected: isProtected,
                    protectionReason: protectionReason
                )
            case .notRegularFile:
                return FilePreviewPayload(
                    metadata: metadata,
                    content: .unavailable(reason: .specialFile),
                    isProtected: isProtected,
                    protectionReason: protectionReason
                )
            case let .readError(err):
                let reason: FilePreviewUnavailableReason = (err == EACCES || err == EPERM)
                    ? .permissionDenied
                    : .unreadable(errno: err)
                return FilePreviewPayload(
                    metadata: metadata,
                    content: .unavailable(reason: reason),
                    isProtected: isProtected,
                    protectionReason: protectionReason
                )
            }
        }

        guard let prefix = SafeFileReader.readBoundedPrefix(at: metadata.url, maxBytes: maxTextBytes) else {
            let probeFD = Darwin.open(metadata.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            let reason: FilePreviewUnavailableReason
            if probeFD >= 0 {
                Darwin.close(probeFD)
                reason = .unreadable(errno: EIO)
            } else {
                let err = errno
                if err == EACCES || err == EPERM {
                    reason = .permissionDenied
                } else if err == ENOENT {
                    reason = .notFound
                } else {
                    reason = .unreadable(errno: err)
                }
            }
            return FilePreviewPayload(
                metadata: metadata,
                content: .unavailable(reason: reason),
                isProtected: isProtected,
                protectionReason: protectionReason
            )
        }

        if let text = Self.decodeTextIfPrintableUTF8(data: prefix.data, isTruncated: prefix.isTruncated) {
            return FilePreviewPayload(
                metadata: metadata,
                content: .text(
                    text,
                    encodingDescription: "UTF-8",
                    isTruncated: prefix.isTruncated,
                    totalBytes: prefix.totalSize
                ),
                isProtected: isProtected,
                protectionReason: protectionReason
            )
        }

        let hexSlice = prefix.data.prefix(4096)
        let hexString = Self.formatHexDump(hexSlice)
        return FilePreviewPayload(
            metadata: metadata,
            content: .hexDump(
                hexString,
                byteCount: hexSlice.count,
                isTruncated: prefix.isTruncated || prefix.data.count > hexSlice.count,
                totalBytes: prefix.totalSize
            ),
            isProtected: isProtected,
            protectionReason: protectionReason
        )
    }

    public func loadPreviewAsync(
        at url: URL,
        maxTextBytes: Int = 65_536,
        maxImageBytes: Int = SafeFileReader.defaultMaxBytes
    ) async throws -> FilePreviewPayload {
        let service = self
        return try await Task.detached(priority: .userInitiated) {
            try service.loadPreview(at: url, maxTextBytes: maxTextBytes, maxImageBytes: maxImageBytes)
        }.value
    }

    // MARK: - POSIX Enumeration (`getattrlistbulk` + `fdopendir/readdir/fstatat` fallback)

    private struct RawEntry {
        let name: String
        let objType: UInt32
        let crDate: Date?
        let modDate: Date?
        let flags: UInt32
        let dataLength: Int64
        let isSymlinkBroken: Bool
    }

    private struct BulkUnsupportedError: Error {}

    private func readEntries(at dirURL: URL) throws -> [RawEntry] {
        let path = dirURL.path
        let fd = open(path, O_RDONLY | O_DIRECTORY)
        if fd < 0 {
            let err = errno
            if err == ENOENT { throw FileBrowserError.notFound(path: path) }
            if err == ENOTDIR { throw FileBrowserError.notADirectory(path: path) }
            if err == EACCES || err == EPERM {
                let hasFDA = PermissionChecker.checkFullDiskAccess(homeDirectory: homeDirectory).hasFullDiskAccess
                throw FileBrowserError.tccOrPermissionDenied(path: path, needsFullDiskAccess: !hasFDA)
            }
            throw FileBrowserError.posixError(code: err, path: path, detail: String(cString: strerror(err)))
        }

        var ownsFD = true
        defer {
            if ownsFD {
                close(fd)
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
                return try readEntriesBulk(dirFD: fd, dirURL: dirURL)
            } catch is BulkUnsupportedError {
                if enumerationMode == .bulkOnly {
                    throw FileBrowserError.posixError(code: ENOTSUP, path: path, detail: "getattrlistbulk not supported")
                }
                _ = lseek(fd, 0, SEEK_SET)
                return try readEntriesFallback(dirFD: fd, ownsFD: &ownsFD, dirURL: dirURL)
            }
        } else {
            return try readEntriesFallback(dirFD: fd, ownsFD: &ownsFD, dirURL: dirURL)
        }
    }

    private func readEntriesBulk(dirFD: Int32, dirURL: URL) throws -> [RawEntry] {
        let dirPath = dirURL.path
        var alist = attrlist()
        alist.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)

        var cmn: UInt32 = 0
        cmn |= UInt32(ATTR_CMN_RETURNED_ATTRS)
        cmn |= UInt32(ATTR_CMN_NAME)
        cmn |= UInt32(ATTR_CMN_OBJTYPE)
        cmn |= UInt32(ATTR_CMN_CRTIME)
        cmn |= UInt32(ATTR_CMN_MODTIME)
        cmn |= UInt32(ATTR_CMN_FLAGS)
        cmn |= UInt32(ATTR_CMN_ERROR)
        alist.commonattr = cmn

        alist.fileattr = UInt32(ATTR_FILE_DATALENGTH)

        var buffer = [UInt8](repeating: 0, count: Self.bulkBufferSize)
        var results: [RawEntry] = []
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
                    let hasFDA = PermissionChecker.checkFullDiskAccess(homeDirectory: homeDirectory).hasFullDiskAccess
                    throw FileBrowserError.tccOrPermissionDenied(path: dirPath, needsFullDiskAccess: !hasFDA)
                }
                if err == ENOENT {
                    throw FileBrowserError.notFound(path: dirPath)
                }
                throw FileBrowserError.posixError(code: err, path: dirPath, detail: String(cString: strerror(err)))
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

                    var objType: UInt32 = 0
                    if (returned.commonattr & UInt32(ATTR_CMN_OBJTYPE)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<fsobj_type_t>.size) <= entryEnd else { continue }
                        objType = cursor.loadUnaligned(as: UInt32.self)
                        cursor = cursor.advanced(by: MemoryLayout<fsobj_type_t>.size)
                    }

                    var crDate: Date?
                    if (returned.commonattr & UInt32(ATTR_CMN_CRTIME)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<timespec>.size) <= entryEnd else { continue }
                        crDate = Self.dateFromTimespec(cursor.loadUnaligned(as: timespec.self))
                        cursor = cursor.advanced(by: MemoryLayout<timespec>.size)
                    }

                    var modDate: Date?
                    if (returned.commonattr & UInt32(ATTR_CMN_MODTIME)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<timespec>.size) <= entryEnd else { continue }
                        modDate = Self.dateFromTimespec(cursor.loadUnaligned(as: timespec.self))
                        cursor = cursor.advanced(by: MemoryLayout<timespec>.size)
                    }

                    var flags: UInt32 = 0
                    if (returned.commonattr & UInt32(ATTR_CMN_FLAGS)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<UInt32>.size) <= entryEnd else { continue }
                        flags = cursor.loadUnaligned(as: UInt32.self)
                        cursor = cursor.advanced(by: MemoryLayout<UInt32>.size)
                    }

                    var entryError: UInt32 = 0
                    if (returned.commonattr & UInt32(ATTR_CMN_ERROR)) != 0 {
                        guard cursor.advanced(by: MemoryLayout<UInt32>.size) <= entryEnd else { continue }
                        entryError = cursor.loadUnaligned(as: UInt32.self)
                        cursor = cursor.advanced(by: MemoryLayout<UInt32>.size)
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

                    var brokenSymlink = false
                    if objType == UInt32(VLNK.rawValue) {
                        var targetStat = stat()
                        brokenSymlink = (fstatat(dirFD, name, &targetStat, 0) != 0)
                    }

                    results.append(RawEntry(
                        name: name,
                        objType: objType,
                        crDate: crDate,
                        modDate: modDate,
                        flags: flags,
                        dataLength: dataLength,
                        isSymlinkBroken: brokenSymlink
                    ))
                }
            }
        }

        return results
    }

    private func readEntriesFallback(
        dirFD: Int32,
        ownsFD: inout Bool,
        dirURL: URL
    ) throws -> [RawEntry] {
        guard let dirStream = fdopendir(dirFD) else {
            let err = errno
            throw FileBrowserError.posixError(code: err, path: dirURL.path, detail: String(cString: strerror(err)))
        }
        ownsFD = false
        defer { closedir(dirStream) }

        let streamFD = dirfd(dirStream)
        var results: [RawEntry] = []

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

            var brokenSymlink = false
            if mode == S_IFLNK {
                var targetStat = stat()
                brokenSymlink = (fstatat(streamFD, name, &targetStat, 0) != 0)
            }

            results.append(RawEntry(
                name: name,
                objType: objType,
                crDate: Self.dateFromTimespec(childStat.st_birthtimespec),
                modDate: Self.dateFromTimespec(childStat.st_mtimespec),
                flags: childStat.st_flags,
                dataLength: childStat.st_size,
                isSymlinkBroken: brokenSymlink
            ))
        }

        return results
    }

    // MARK: - Helpers

    private static func validateDirectoryURL(_ url: URL) throws -> URL {
        let rawPath = url.path
        guard url.isFileURL,
              !rawPath.isEmpty,
              !rawPath.contains("\0"),
              !url.absoluteString.lowercased().contains("%00"),
              !SafetyGuard.hasDotDotPathComponent(url) else {
            throw FileBrowserError.invalidPath(path: rawPath)
        }
        return url.standardizedFileURL
    }

    private static func detectIsPackage(at url: URL) -> Bool {
        guard !url.pathExtension.isEmpty else { return false }
        return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }

    private static func classifyType(for url: URL, kind: FileItemKind) -> (UTType?, String) {
        switch kind {
        case .symbolicLink:
            return (.symbolicLink, "Symbolic Link")
        case .package:
            let utType = UTType(filenameExtension: url.pathExtension) ?? .package
            return (utType, "Package")
        case .directory:
            return (.folder, "Folder")
        case .regularFile:
            let ext = url.pathExtension
            let utType = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
            return (utType, "Document")
        case .special:
            return (nil, "Special File")
        }
    }

    public static func sortEntries(
        _ entries: [FileBrowserEntry],
        by sortBy: FileBrowserSort,
        ascending: Bool
    ) -> [FileBrowserEntry] {
        entries.sorted { lhs, rhs in
            let order: ComparisonResult
            switch sortBy {
            case .name:
                order = lhs.name.localizedStandardCompare(rhs.name)
            case .size:
                if lhs.sizeBytes == rhs.sizeBytes {
                    order = .orderedSame
                } else {
                    order = lhs.sizeBytes < rhs.sizeBytes ? .orderedAscending : .orderedDescending
                }
            case .modificationDate:
                let ld = lhs.modificationDate ?? .distantPast
                let rd = rhs.modificationDate ?? .distantPast
                if ld == rd {
                    order = .orderedSame
                } else {
                    order = ld < rd ? .orderedAscending : .orderedDescending
                }
            case .kind:
                order = lhs.kindDescription.localizedStandardCompare(rhs.kindDescription)
            }

            if order != .orderedSame {
                return ascending ? (order == .orderedAscending) : (order == .orderedDescending)
            }
            let nameTie = lhs.name.localizedStandardCompare(rhs.name)
            if nameTie != .orderedSame {
                return nameTie == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private static func dateFromTimespec(_ ts: timespec) -> Date? {
        guard ts.tv_sec != 0 || ts.tv_nsec != 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000.0)
    }

    private static func decodeTextIfPrintableUTF8(data: Data, isTruncated: Bool) -> String? {
        guard !data.isEmpty else { return "" }
        if data.contains(0) {
            return nil
        }

        var nonWhitespaceControlCount = 0
        for byte in data {
            // Allow \t (0x09), \n (0x0A), \r (0x0D). Flag other C0 controls (< 0x20).
            if byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D {
                nonWhitespaceControlCount += 1
            }
        }
        if nonWhitespaceControlCount * 20 > data.count {
            return nil
        }

        let trimmedData = isTruncated ? trimmingTrailingIncompleteUTF8(data) : data
        return String(data: trimmedData, encoding: .utf8)
    }

    private static func trimmingTrailingIncompleteUTF8(_ data: Data) -> Data {
        let count = data.count
        guard count > 0 else { return data }

        var continuationCount = 0
        var idx = count - 1
        while idx >= 0 && continuationCount < 3 {
            let b = data[idx]
            if (b & 0xC0) == 0x80 {
                continuationCount += 1
                idx -= 1
            } else {
                break
            }
        }

        guard idx >= 0 else { return data }
        let lead = data[idx]
        let expectedLen: Int
        if (lead & 0x80) == 0 {
            expectedLen = 1
        } else if (lead & 0xE0) == 0xC0 {
            expectedLen = 2
        } else if (lead & 0xF0) == 0xE0 {
            expectedLen = 3
        } else if (lead & 0xF8) == 0xF0 {
            expectedLen = 4
        } else {
            return data
        }

        let availableLen = count - idx
        if availableLen < expectedLen {
            return data.prefix(idx)
        }
        return data
    }

    private static func formatHexDump(_ data: Data) -> String {
        var lines: [String] = []
        let bytes = Array(data)
        lines.reserveCapacity((bytes.count + 7) / 8)

        for offset in stride(from: 0, to: bytes.count, by: 8) {
            let end = min(offset + 8, bytes.count)
            let chunk = bytes[offset..<end]

            var hexParts: [String] = []
            hexParts.reserveCapacity(8)
            var ascii = ""
            ascii.reserveCapacity(chunk.count)

            for byte in chunk {
                hexParts.append(String(format: "%02X", byte))
                if byte >= 0x20 && byte <= 0x7E {
                    ascii.append(Character(UnicodeScalar(byte)))
                } else {
                    ascii.append(".")
                }
            }

            let hexJoined = hexParts.joined(separator: " ")
            let paddedHex = hexJoined.padding(toLength: 23, withPad: " ", startingAt: 0)
            lines.append(String(format: "%08X  %@  |%@|", offset, paddedHex, ascii))
        }
        return lines.joined(separator: "\n")
    }
}

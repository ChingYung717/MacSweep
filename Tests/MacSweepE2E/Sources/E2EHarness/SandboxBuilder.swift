import Darwin
import Foundation

public enum CorruptJSONVariant: Sendable {
    case truncated
    case invalidUTF8
    case wrongRootType
    case empty
}

public enum SandboxBuilderError: Error, CustomStringConvertible, Sendable {
    case invalidRelativePath(String)
    case posixFailure(operation: String, path: String, errno: Int32)

    public var description: String {
        switch self {
        case let .invalidRelativePath(path):
            return "Invalid sandbox relative path: '\(path)'"
        case let .posixFailure(operation, path, code):
            let msg = String(cString: Darwin.strerror(code))
            return "\(operation) failed for '\(path)': errno=\(code) (\(msg))"
        }
    }
}

public enum SandboxBuilder: Sendable {
    public static func canonicalPath(for url: URL) -> String {
        canonicalPath(forPath: url.standardizedFileURL.path)
    }

    public static func canonicalPath(forPath path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if let resolved = posixRealpath(standardized) {
            return resolved
        }

        var cursor = URL(fileURLWithPath: standardized)
        var trailingComponents: [String] = []
        while cursor.path != "/" && cursor.path != "" {
            if let resolved = posixRealpath(cursor.path) {
                var rebuilt = URL(fileURLWithPath: resolved)
                for component in trailingComponents.reversed() {
                    rebuilt.appendPathComponent(component)
                }
                return applyMacOSPrivatePrefix(rebuilt.standardizedFileURL.path)
            }
            trailingComponents.append(cursor.lastPathComponent)
            cursor.deleteLastPathComponent()
        }

        return applyMacOSPrivatePrefix(standardized)
    }

    public static func canonicalURL(for url: URL) -> URL {
        URL(fileURLWithPath: canonicalPath(for: url))
    }

    public static func canonicalParentPath(for url: URL) -> String {
        let parentURL = url.standardizedFileURL.deletingLastPathComponent()
        return canonicalPath(for: parentURL)
    }

    private static func posixRealpath(_ path: String) -> String? {
        guard let ptr = Darwin.realpath(path, nil) else { return nil }
        defer { Darwin.free(ptr) }
        return String(cString: ptr)
    }

    private static func applyMacOSPrivatePrefix(_ path: String) -> String {
        for prefix in ["/var", "/tmp", "/etc"] {
            if path == prefix || path.hasPrefix(prefix + "/") {
                return "/private" + path
            }
        }
        return path
    }

    /// Top-down symlink-safe unlock: clears `UF_IMMUTABLE` (`uchg`) via `lchflags` and restores
    /// `u+rwx` on directories before descending, so locked directories and nested immutable files
    /// can always be removed cleanly.
    public static func clearUserImmutableAndFixPermissionsRecursively(at root: URL) {
        let path = root.standardizedFileURL.path
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else { return }

        let fileType = st.st_mode & S_IFMT
        if fileType == S_IFLNK {
            // Never follow symlinks when modifying flags or permissions.
            if (st.st_flags & UInt32(UF_IMMUTABLE)) != 0 {
                _ = Darwin.lchflags(path, st.st_flags & ~UInt32(UF_IMMUTABLE))
            }
            return
        }

        if (st.st_flags & UInt32(UF_IMMUTABLE)) != 0 {
            _ = Darwin.lchflags(path, st.st_flags & ~UInt32(UF_IMMUTABLE))
        }

        if fileType == S_IFDIR {
            let desiredDirMode = (st.st_mode & 0o7777) | mode_t(0o700)
            if (st.st_mode & 0o700) != 0o700 {
                _ = Darwin.chmod(path, desiredDirMode)
            }
            if let dir = Darwin.opendir(path) {
                var childNames: [String] = []
                while let entry = Darwin.readdir(dir) {
                    let name = withUnsafePointer(to: &entry.pointee.d_name) { ptr in
                        ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { cStr in
                            String(cString: cStr)
                        }
                    }
                    if name != "." && name != ".." {
                        childNames.append(name)
                    }
                }
                Darwin.closedir(dir)
                for childName in childNames {
                    clearUserImmutableAndFixPermissionsRecursively(
                        at: root.appendingPathComponent(childName)
                    )
                }
            }
        } else if fileType == S_IFREG {
            let desiredFileMode = (st.st_mode & 0o7777) | mode_t(0o600)
            if (st.st_mode & 0o600) != 0o600 {
                _ = Darwin.chmod(path, desiredFileMode)
            }
        }
    }
}

public final class E2ESandbox: @unchecked Sendable {
    public let rawRootURL: URL
    public let rootURL: URL
    public let canonicalRootPath: String

    private let lock = NSLock()
    private var cleanedUp = false

    public init(prefix: String = "macsweep-e2e") throws {
        let baseTmp = FileManager.default.temporaryDirectory
        let folderName = "\(prefix)-\(UUID().uuidString.lowercased())"
        let raw = baseTmp.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)

        self.rawRootURL = raw.standardizedFileURL
        let canonical = SandboxBuilder.canonicalPath(for: raw)
        self.canonicalRootPath = canonical
        self.rootURL = URL(fileURLWithPath: canonical, isDirectory: true)
    }

    deinit {
        cleanup()
    }

    public func url(_ relativePath: String) -> URL {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty {
            return rootURL
        }
        if let comps = try? normalizedRelativeComponents(trimmed) {
            var u = rootURL
            for comp in comps {
                u.appendPathComponent(comp)
            }
            return u
        }
        return rootURL.appendingPathComponent(trimmed)
    }

    public func canonicalPath(for url: URL) -> String {
        SandboxBuilder.canonicalPath(for: url)
    }

    public func canonicalParentPath(for url: URL) -> String {
        SandboxBuilder.canonicalParentPath(for: url)
    }

    @discardableResult
    public func createDirectory(_ relativePath: String, permissions: Int? = nil) throws -> URL {
        let dirURL = try validatedTargetURL(relativePath)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true, attributes: nil)
        if let permissions {
            if Darwin.chmod(dirURL.path, mode_t(permissions)) != 0 {
                throw SandboxBuilderError.posixFailure(operation: "chmod", path: dirURL.path, errno: errno)
            }
        }
        return dirURL
    }

    @discardableResult
    public func createFile(_ relativePath: String, data: Data, permissions: Int? = nil) throws -> URL {
        let fileURL = try validatedTargetURL(relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        if let permissions {
            _ = Darwin.chmod(fileURL.path, mode_t(permissions))
        }
        return fileURL
    }

    @discardableResult
    public func createFile(_ relativePath: String, utf8: String, permissions: Int? = nil) throws -> URL {
        try createFile(relativePath, data: Data(utf8.utf8), permissions: permissions)
    }

    @discardableResult
    public func createExactSizeFile(
        _ relativePath: String,
        byteCount: Int64,
        fillByte: UInt8 = 0x41,
        sparse: Bool = false,
        sparseDistinctTag: UInt8? = nil
    ) throws -> URL {
        precondition(byteCount >= 0, "byteCount must be >= 0")
        let fileURL = try validatedTargetURL(relativePath)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let fd = Darwin.open(fileURL.path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o644))
        guard fd >= 0 else {
            throw SandboxBuilderError.posixFailure(operation: "open", path: fileURL.path, errno: errno)
        }
        defer { _ = Darwin.close(fd) }

        if sparse {
            if let tag = sparseDistinctTag, byteCount > 0 {
                var byte = tag
                let wrote = Darwin.write(fd, &byte, 1)
                if wrote < 0 {
                    throw SandboxBuilderError.posixFailure(operation: "write", path: fileURL.path, errno: errno)
                }
            }
            if Darwin.ftruncate(fd, off_t(byteCount)) != 0 {
                throw SandboxBuilderError.posixFailure(operation: "ftruncate", path: fileURL.path, errno: errno)
            }
            return fileURL
        }

        let chunkSize = 65_536
        let chunk = [UInt8](repeating: fillByte, count: chunkSize)
        var remaining = byteCount
        while remaining > 0 {
            let toWrite = Int(min(remaining, Int64(chunkSize)))
            let rc: Int = chunk.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return 0 }
                var offset = 0
                while offset < toWrite {
                    let n = Darwin.write(fd, base.advanced(by: offset), toWrite - offset)
                    if n > 0 {
                        offset += n
                    } else if n < 0 && errno == EINTR {
                        continue
                    } else {
                        return -1
                    }
                }
                return offset
            }
            if rc < 0 {
                throw SandboxBuilderError.posixFailure(operation: "write", path: fileURL.path, errno: errno)
            }
            remaining -= Int64(toWrite)
        }
        return fileURL
    }

    @discardableResult
    public func createSymlink(atRelativePath relativePath: String, targetURL: URL) throws -> URL {
        try createSymlink(atRelativePath: relativePath, targetPath: targetURL.path)
    }

    @discardableResult
    public func createSymlink(atRelativePath relativePath: String, targetPath: String) throws -> URL {
        let linkURL = try validatedTargetURL(relativePath)
        try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: targetPath)
        return linkURL
    }

    @discardableResult
    public func createHardlink(atRelativePath relativePath: String, to existingURL: URL) throws -> URL {
        let linkURL = try validatedTargetURL(relativePath)
        try FileManager.default.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if Darwin.link(existingURL.path, linkURL.path) != 0 {
            throw SandboxBuilderError.posixFailure(operation: "link", path: linkURL.path, errno: errno)
        }
        return linkURL
    }

    @discardableResult
    public func createFIFO(atRelativePath relativePath: String, mode: mode_t = 0o600) throws -> URL {
        let fifoURL = try validatedTargetURL(relativePath)
        try FileManager.default.createDirectory(at: fifoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if Darwin.mkfifo(fifoURL.path, mode) != 0 {
            throw SandboxBuilderError.posixFailure(operation: "mkfifo", path: fifoURL.path, errno: errno)
        }
        return fifoURL
    }

    public func setUserImmutable(_ targetURL: URL, locked: Bool = true) throws {
        var st = stat()
        guard Darwin.lstat(targetURL.path, &st) == 0 else {
            throw SandboxBuilderError.posixFailure(operation: "lstat", path: targetURL.path, errno: errno)
        }
        let newFlags: UInt32 = locked
            ? (st.st_flags | UInt32(UF_IMMUTABLE))
            : (st.st_flags & ~UInt32(UF_IMMUTABLE))
        if Darwin.lchflags(targetURL.path, newFlags) != 0 {
            throw SandboxBuilderError.posixFailure(operation: "lchflags", path: targetURL.path, errno: errno)
        }
    }

    public func isUserImmutable(_ targetURL: URL) -> Bool {
        var st = stat()
        guard Darwin.lstat(targetURL.path, &st) == 0 else { return false }
        return (st.st_flags & UInt32(UF_IMMUTABLE)) != 0
    }

    @discardableResult
    public func createCorruptJSON(atRelativePath relativePath: String, variant: CorruptJSONVariant = .truncated) throws -> URL {
        let data: Data
        switch variant {
        case .truncated:
            data = Data("{\"corrupt\":".utf8)
        case .invalidUTF8:
            data = Data([0x7B, 0xFF, 0xFE, 0x7D])
        case .wrongRootType:
            data = Data("[1, 2, 3]".utf8)
        case .empty:
            data = Data()
        }
        return try createFile(relativePath, data: data)
    }

    @discardableResult
    public func createOversizedJSON(atRelativePath relativePath: String, exceedingBytes: Int = 2 * 1024 * 1024) throws -> URL {
        let prefix = Data("{\"padding\":\"".utf8)
        let suffix = Data("\"}".utf8)
        let padCount = max(1, exceedingBytes - prefix.count - suffix.count + 16)
        var data = Data()
        data.reserveCapacity(prefix.count + padCount + suffix.count)
        data.append(prefix)
        data.append(contentsOf: repeatElement(UInt8(ascii: "x"), count: padCount))
        data.append(suffix)
        return try createFile(relativePath, data: data)
    }

    @discardableResult
    public func createMockAppBundle(
        atRelativePath relativePath: String,
        bundleID: String,
        name: String
    ) throws -> URL {
        let appURL = try createDirectory(relativePath)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundleExecutable": name,
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
            "CFBundlePackageType": "APPL",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"), options: .atomic)
        return appURL
    }

    public func cleanup() {
        let shouldClean = lock.withLock { () -> Bool in
            if cleanedUp { return false }
            cleanedUp = true
            return true
        }
        guard shouldClean else { return }

        SandboxBuilder.clearUserImmutableAndFixPermissionsRecursively(at: rootURL)
        try? FileManager.default.removeItem(at: rootURL)
    }

    private func normalizedRelativeComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.contains("\0") else {
            throw SandboxBuilderError.invalidRelativePath(relativePath)
        }
        var stack: [String] = []
        for rawComp in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
            let comp = String(rawComp)
            if comp == "." {
                continue
            } else if comp == ".." {
                if stack.isEmpty {
                    throw SandboxBuilderError.invalidRelativePath(relativePath)
                }
                stack.removeLast()
            } else {
                stack.append(comp)
            }
        }
        guard !stack.isEmpty else {
            throw SandboxBuilderError.invalidRelativePath(relativePath)
        }
        return stack
    }

    private func validatedTargetURL(_ relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let comps = try normalizedRelativeComponents(trimmed)
        var candidate = rootURL
        for comp in comps {
            candidate.appendPathComponent(comp)
        }
        let rootPrefix = canonicalRootPath + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            throw SandboxBuilderError.invalidRelativePath(relativePath)
        }
        return candidate
    }
}

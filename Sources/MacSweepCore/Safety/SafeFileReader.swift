import Darwin
import Foundation

public enum SafeFileReadResult: Sendable, Equatable {
    case success(Data)
    case notFound
    case oversized(actualSize: Int64?, maxBytes: Int)
    case notRegularFile
    case readError(errno: Int32)
}

public struct BoundedPrefixRead: Sendable, Equatable {
    public let data: Data
    public let isTruncated: Bool
    public let totalSize: Int64?

    public init(data: Data, isTruncated: Bool, totalSize: Int64?) {
        self.data = data
        self.isTruncated = isTruncated
        self.totalSize = totalSize
    }
}

/// Bounded, non-blocking, symlink-safe regular file reader.
///
/// Defends all scanners and preview helpers against:
/// - Symlink escapes (`O_NOFOLLOW`)
/// - Blocking forever on FIFOs / named pipes / device nodes (`O_NONBLOCK` + `fstat` `S_IFREG`)
/// - Memory exhaustion (OOM) from huge files (`maxBytes`)
public enum SafeFileReader {
    public static let defaultMaxBytes: Int = 2 * 1024 * 1024

    public static func readBoundedRegularFileDetailed(
        at url: URL,
        maxBytes: Int = defaultMaxBytes
    ) -> SafeFileReadResult {
        guard url.isFileURL, maxBytes >= 0 else { return .readError(errno: EINVAL) }
        let path = url.path
        guard !path.isEmpty, !path.contains("\0") else { return .readError(errno: EINVAL) }

        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            let err = errno
            if err == ENOENT { return .notFound }
            if err == ELOOP { return .notRegularFile }
            return .readError(errno: err)
        }
        defer { Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else {
            return .readError(errno: errno)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            return .notRegularFile
        }

        if st.st_size > Int64(maxBytes) {
            return .oversized(actualSize: st.st_size, maxBytes: maxBytes)
        }

        var data = Data()
        let initialCap = max(0, min(Int(st.st_size), maxBytes))
        data.reserveCapacity(initialCap)

        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                if data.count + n > maxBytes {
                    return .oversized(actualSize: nil, maxBytes: maxBytes)
                }
                data.append(contentsOf: buffer[..<n])
            } else if n == 0 {
                break
            } else {
                if errno == EINTR {
                    continue
                }
                return .readError(errno: errno)
            }
        }
        return .success(data)
    }

    public static func readBoundedRegularFile(
        at url: URL,
        maxBytes: Int = defaultMaxBytes
    ) -> Data? {
        if case let .success(data) = readBoundedRegularFileDetailed(at: url, maxBytes: maxBytes) {
            return data
        }
        return nil
    }

    /// Reads up to `maxBytes` from a non-symlink regular file without blocking on FIFOs/devices,
    /// returning `isTruncated = true` when the file contains additional unread bytes.
    public static func readBoundedPrefix(
        at url: URL,
        maxBytes: Int = 65_536
    ) -> BoundedPrefixRead? {
        guard url.isFileURL, maxBytes >= 0 else { return nil }
        let path = url.path
        guard !path.isEmpty, !path.contains("\0") else { return nil }

        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var st = stat()
        guard Darwin.fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }

        var data = Data()
        data.reserveCapacity(max(0, min(Int(st.st_size), maxBytes)))
        var isTruncated = st.st_size > Int64(maxBytes)

        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.count < maxBytes {
            let remaining = maxBytes - data.count
            let toRead = min(buffer.count, remaining)
            let n = Darwin.read(fd, &buffer, toRead)
            if n > 0 {
                data.append(contentsOf: buffer[..<n])
            } else if n == 0 {
                break
            } else {
                if errno == EINTR { continue }
                return nil
            }
        }

        if !isTruncated {
            var probe: UInt8 = 0
            while true {
                let n = Darwin.read(fd, &probe, 1)
                if n > 0 {
                    isTruncated = true
                    break
                } else if n == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }

        return BoundedPrefixRead(data: data, isTruncated: isTruncated, totalSize: st.st_size)
    }

    public static func readBoundedUTF8String(
        at url: URL,
        maxBytes: Int = defaultMaxBytes
    ) -> String? {
        guard let data = readBoundedRegularFile(at: url, maxBytes: maxBytes) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Atomically writes `data` to `url` with `0600` permissions (and `0700` parent directory),
    /// eliminating any transient `0644` window and refusing symlink parent directories or targets.
    @discardableResult
    public static func writePrivateAtomically(_ data: Data, to url: URL) -> Bool {
        guard url.isFileURL, !url.path.isEmpty, !url.path.contains("\0") else { return false }
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()

        var dirStat = stat()
        if lstat(dir.path, &dirStat) == 0 {
            guard (dirStat.st_mode & S_IFMT) == S_IFDIR, dirStat.st_uid == geteuid() else {
                return false
            }
            _ = chmod(dir.path, 0o700)
        } else {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                return false
            }
            guard lstat(dir.path, &dirStat) == 0,
                  (dirStat.st_mode & S_IFMT) == S_IFDIR,
                  dirStat.st_uid == geteuid() else {
                return false
            }
            _ = chmod(dir.path, 0o700)
        }

        // Refuse to overwrite through a symlink at the target path.
        var dstStat = stat()
        if lstat(url.path, &dstStat) == 0, (dstStat.st_mode & S_IFMT) == S_IFLNK {
            return false
        }

        let tmpName = ".\(url.lastPathComponent).tmp.\(UUID().uuidString.lowercased())"
        let tmpPath = dir.appendingPathComponent(tmpName).path
        let fd = Darwin.open(tmpPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { return false }

        var succeeded = false
        defer {
            if !succeeded {
                _ = Darwin.unlink(tmpPath)
            }
        }

        _ = Darwin.fchmod(fd, mode_t(0o600))
        let wroteAll: Bool = data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return true }
            var offset = 0
            while offset < rawBuf.count {
                let n = Darwin.write(fd, base.advanced(by: offset), rawBuf.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        let closeRC = Darwin.close(fd)
        guard wroteAll && closeRC == 0 else { return false }

        guard Darwin.rename(tmpPath, url.path) == 0 else { return false }
        succeeded = true
        return true
    }

    /// Replaces ASCII/C1 control characters and Unicode bidirectional/line-separator control
    /// characters with visible escaped tokens (`\n`, `\r`, `\t`, `\0`, `\u{XXXX}`) so untrusted
    /// filenames/paths cannot visually masquerade as a different path (e.g. `"Evil\n.app"` renders
    /// as `"Evil\n.app"` rather than `"Evil.app"`).
    public static func sanitizeForDisplay(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x00:
                result.append("\\0")
            case 0x09:
                result.append("\\t")
            case 0x0A:
                result.append("\\n")
            case 0x0D:
                result.append("\\r")
            default:
                if v <= 0x1F || (v >= 0x7F && v <= 0x9F)
                    || v == 0x061C
                    || (v >= 0x200E && v <= 0x200F)
                    || (v >= 0x2028 && v <= 0x202E)
                    || (v >= 0x2066 && v <= 0x2069) {
                    result.append(String(format: "\\u{%04X}", v))
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}

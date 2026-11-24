import Darwin
import Foundation

public struct DirectorySizeMeasurement: Sendable, Equatable {
    public let bytes: Int64
    public let isTruncated: Bool

    public init(bytes: Int64, isTruncated: Bool) {
        self.bytes = bytes
        self.isTruncated = isTruncated
    }
}

/// Concurrent, bounded, cached disk-size calculator that skips symbolic links to avoid loops.
public actor DirectorySizer {
    public static let defaultMaxEntriesPerDirectory: Int = 250_000
    private var cache: [String: Int64] = [:]

    public init() {}

    public func invalidate(path: String) {
        cache.removeValue(forKey: path)
    }

    public func invalidateAll() {
        cache.removeAll()
    }

    public func isCached(path: String) -> Bool {
        cache[URL(fileURLWithPath: path).standardizedFileURL.path] != nil
    }

    public func size(
        of url: URL,
        useCache: Bool = true,
        maxEntries: Int = defaultMaxEntriesPerDirectory
    ) -> Int64 {
        let key = url.standardizedFileURL.path
        if useCache, let cached = cache[key] {
            return cached
        }
        let measurement = Self.measureSizeSync(of: url, maxEntries: maxEntries)
        if useCache && !measurement.isTruncated {
            cache[key] = measurement.bytes
        }
        return measurement.bytes
    }

    /// Computes sizes for multiple URLs concurrently with a fixed concurrency bound.
    /// Truncated measurements (hitting `maxEntries` or cancellation) are returned for display
    /// without being permanently cached as authoritative sizes.
    public func sizes(
        of urls: [URL],
        maxConcurrency: Int = 6,
        useCache: Bool = true,
        maxEntries: Int = defaultMaxEntriesPerDirectory
    ) async -> [String: Int64] {
        var results: [String: Int64] = [:]
        var toCompute: [URL] = []

        for url in urls {
            let key = url.standardizedFileURL.path
            if useCache, let cached = cache[key] {
                results[key] = cached
            } else {
                toCompute.append(url)
            }
        }

        if toCompute.isEmpty {
            return results
        }

        let limit = max(1, maxConcurrency)
        await withTaskGroup(of: (String, DirectorySizeMeasurement).self) { group in
            var index = 0
            for _ in 0..<min(limit, toCompute.count) {
                let target = toCompute[index]
                index += 1
                group.addTask {
                    (target.standardizedFileURL.path, Self.measureSizeSync(of: target, maxEntries: maxEntries))
                }
            }

            while let (key, measurement) = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                results[key] = measurement.bytes
                if useCache && !measurement.isTruncated {
                    cache[key] = measurement.bytes
                }
                if index < toCompute.count {
                    let target = toCompute[index]
                    index += 1
                    group.addTask {
                        (target.standardizedFileURL.path, Self.measureSizeSync(of: target, maxEntries: maxEntries))
                    }
                }
            }
        }

        return results
    }

    public nonisolated static func computeSizeSync(
        of url: URL,
        maxEntries: Int = defaultMaxEntriesPerDirectory
    ) -> Int64 {
        measureSizeSync(of: url, maxEntries: maxEntries).bytes
    }

    public nonisolated static func measureSizeSync(
        of url: URL,
        maxEntries: Int = defaultMaxEntriesPerDirectory
    ) -> DirectorySizeMeasurement {
        let path = url.path
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return DirectorySizeMeasurement(bytes: 0, isTruncated: false)
        }

        let fileType = st.st_mode & S_IFMT
        if fileType == S_IFLNK {
            // Symbolic link itself occupies negligible metadata blocks; never follow target.
            return DirectorySizeMeasurement(bytes: Int64(st.st_size), isTruncated: false)
        }
        if fileType != S_IFDIR {
            let bytes = st.st_blocks > 0 ? Int64(st.st_blocks) * 512 : Int64(st.st_size)
            return DirectorySizeMeasurement(bytes: bytes, isTruncated: false)
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return DirectorySizeMeasurement(bytes: 0, isTruncated: false)
        }

        let cap = max(0, maxEntries)
        var total: Int64 = 0
        var visited = 0
        var isTruncated = false
        for case let itemURL as URL in enumerator {
            visited += 1
            if visited > cap {
                isTruncated = true
                break
            }
            if (visited & 0xFF) == 0 && Task.isCancelled {
                isTruncated = true
                break
            }
            guard let values = try? itemURL.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true {
                continue
            }
            if values.isRegularFile == true {
                if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                    total += Int64(allocated)
                } else if let size = values.fileSize {
                    total += Int64(size)
                }
            }
        }
        return DirectorySizeMeasurement(bytes: total, isTruncated: isTruncated)
    }
}

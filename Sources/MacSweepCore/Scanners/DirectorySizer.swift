import Darwin
import Foundation

public struct DirectorySizeMeasurement: Sendable, Equatable {
    public let bytes: Int64
    public let fileCount: Int
    public let folderCount: Int
    public let isTruncated: Bool

    public init(bytes: Int64, fileCount: Int = 0, folderCount: Int = 0, isTruncated: Bool) {
        self.bytes = bytes
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.isTruncated = isTruncated
    }
}

/// Concurrent, bounded, cached disk-size calculator that skips symbolic links to avoid loops.
public actor DirectorySizer {
    public static let defaultMaxEntriesPerDirectory: Int = 250_000
    private var cache: [String: DirectorySizeMeasurement] = [:]

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

    public func measure(
        of url: URL,
        useCache: Bool = true,
        maxEntries: Int = defaultMaxEntriesPerDirectory
    ) -> DirectorySizeMeasurement {
        let key = url.standardizedFileURL.path
        if useCache, let cached = cache[key] {
            return cached
        }
        let measurement = Self.measureSizeSync(of: url, maxEntries: maxEntries)
        if useCache && !measurement.isTruncated {
            cache[key] = measurement
        }
        return measurement
    }

    public func size(
        of url: URL,
        useCache: Bool = true,
        maxEntries: Int = defaultMaxEntriesPerDirectory
    ) -> Int64 {
        measure(of: url, useCache: useCache, maxEntries: maxEntries).bytes
    }

    /// Computes full size + file/folder measurements for multiple URLs concurrently.
    public func measurements(
        of urls: [URL],
        maxConcurrency: Int = 6,
        useCache: Bool = true,
        maxEntries: Int = defaultMaxEntriesPerDirectory
    ) async -> [String: DirectorySizeMeasurement] {
        var results: [String: DirectorySizeMeasurement] = [:]
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
                results[key] = measurement
                if useCache && !measurement.isTruncated {
                    cache[key] = measurement
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

    /// Computes sizes for multiple URLs concurrently with a fixed concurrency bound.
    /// Truncated measurements (hitting `maxEntries` or cancellation) are returned for display
    /// without being permanently cached as authoritative sizes.
    public func sizes(
        of urls: [URL],
        maxConcurrency: Int = 6,
        useCache: Bool = true,
        maxEntries: Int = defaultMaxEntriesPerDirectory
    ) async -> [String: Int64] {
        let map = await measurements(
            of: urls,
            maxConcurrency: maxConcurrency,
            useCache: useCache,
            maxEntries: maxEntries
        )
        return map.mapValues(\.bytes)
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
            return DirectorySizeMeasurement(bytes: 0, fileCount: 0, folderCount: 0, isTruncated: false)
        }

        if (st.st_flags & UInt32(SF_DATALESS)) != 0 {
            return DirectorySizeMeasurement(bytes: 0, fileCount: 0, folderCount: 0, isTruncated: false)
        }

        let fileType = st.st_mode & S_IFMT
        if fileType == S_IFLNK {
            // Symbolic link itself occupies negligible metadata blocks; never follow target.
            return DirectorySizeMeasurement(bytes: Int64(st.st_size), fileCount: 1, folderCount: 0, isTruncated: false)
        }
        if fileType != S_IFDIR {
            let bytes = st.st_blocks > 0 ? Int64(st.st_blocks) * 512 : Int64(st.st_size)
            return DirectorySizeMeasurement(bytes: bytes, fileCount: 1, folderCount: 0, isTruncated: false)
        }

        let rootDev = st.st_dev
        let keys: Set<URLResourceKey> = [
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
            return DirectorySizeMeasurement(bytes: 0, fileCount: 0, folderCount: 0, isTruncated: false)
        }

        struct InodeKey: Hashable {
            let dev: dev_t
            let ino: ino_t
        }

        let cap = max(0, maxEntries)
        var total: Int64 = 0
        var fileCount = 0
        var folderCount = 0
        var visited = 0
        var isTruncated = false
        var seenHardlinks = Set<InodeKey>()
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
            var itemSt = stat()
            guard lstat(itemURL.path, &itemSt) == 0 else { continue }
            let mode = itemSt.st_mode & S_IFMT
            if (itemSt.st_flags & UInt32(SF_DATALESS)) != 0 {
                if mode == S_IFDIR {
                    enumerator.skipDescendants()
                }
                continue
            }
            if itemSt.st_dev != rootDev {
                if mode == S_IFDIR {
                    enumerator.skipDescendants()
                }
                continue
            }
            if mode == S_IFLNK {
                fileCount += 1
                enumerator.skipDescendants()
                continue
            }
            if mode == S_IFDIR {
                folderCount += 1
                continue
            }
            if mode == S_IFREG {
                fileCount += 1
                if itemSt.st_nlink > 1 && itemSt.st_ino != 0 {
                    let key = InodeKey(dev: itemSt.st_dev, ino: itemSt.st_ino)
                    if !seenHardlinks.insert(key).inserted {
                        continue
                    }
                }
                if let values = try? itemURL.resourceValues(forKeys: keys) {
                    if let allocated = values.totalFileAllocatedSize ?? values.fileAllocatedSize {
                        total += Int64(allocated)
                    } else if let size = values.fileSize {
                        total += Int64(size)
                    }
                } else {
                    total += itemSt.st_blocks > 0 ? Int64(itemSt.st_blocks) * 512 : Int64(itemSt.st_size)
                }
            }
        }
        return DirectorySizeMeasurement(
            bytes: total,
            fileCount: fileCount,
            folderCount: folderCount,
            isTruncated: isTruncated
        )
    }
}

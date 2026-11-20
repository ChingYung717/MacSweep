import Darwin
import Foundation

/// Concurrent, bounded, cached disk-size calculator that skips symbolic links to avoid loops.
public actor DirectorySizer {
    private var cache: [String: Int64] = [:]

    public init() {}

    public func invalidate(path: String) {
        cache.removeValue(forKey: path)
    }

    public func invalidateAll() {
        cache.removeAll()
    }

    public func size(of url: URL, useCache: Bool = true) -> Int64 {
        let key = url.standardizedFileURL.path
        if useCache, let cached = cache[key] {
            return cached
        }
        let computed = Self.computeSizeSync(of: url)
        if useCache {
            cache[key] = computed
        }
        return computed
    }

    /// Computes sizes for multiple URLs concurrently with a fixed concurrency bound.
    public func sizes(
        of urls: [URL],
        maxConcurrency: Int = 6,
        useCache: Bool = true
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
        await withTaskGroup(of: (String, Int64).self) { group in
            var index = 0
            for _ in 0..<min(limit, toCompute.count) {
                let target = toCompute[index]
                index += 1
                group.addTask {
                    (target.standardizedFileURL.path, Self.computeSizeSync(of: target))
                }
            }

            while let (key, bytes) = await group.next() {
                results[key] = bytes
                if useCache {
                    cache[key] = bytes
                }
                if index < toCompute.count {
                    let target = toCompute[index]
                    index += 1
                    group.addTask {
                        (target.standardizedFileURL.path, Self.computeSizeSync(of: target))
                    }
                }
            }
        }

        return results
    }

    public nonisolated static func computeSizeSync(of url: URL) -> Int64 {
        let path = url.path
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }

        let fileType = st.st_mode & S_IFMT
        if fileType == S_IFLNK {
            // Symbolic link itself occupies negligible metadata blocks; never follow target.
            return Int64(st.st_size)
        }
        if fileType != S_IFDIR {
            if st.st_blocks > 0 {
                return Int64(st.st_blocks) * 512
            }
            return Int64(st.st_size)
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
            return 0
        }

        var total: Int64 = 0
        for case let itemURL as URL in enumerator {
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
        return total
    }
}

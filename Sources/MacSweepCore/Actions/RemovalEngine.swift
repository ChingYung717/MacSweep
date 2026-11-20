import AppKit
import Darwin
import Foundation

public struct RemovalTarget: Sendable, Hashable {
    public let url: URL
    public let estimatedSize: Int64
    public let requiresAdmin: Bool

    public init(url: URL, estimatedSize: Int64 = 0, requiresAdmin: Bool = false) {
        self.url = url
        self.estimatedSize = estimatedSize
        self.requiresAdmin = requiresAdmin
    }
}

public struct RemovalFailure: Sendable, Equatable {
    public let url: URL
    public let reason: String
    public let isPermissionDenied: Bool

    public init(url: URL, reason: String, isPermissionDenied: Bool = false) {
        self.url = url
        self.reason = reason
        self.isPermissionDenied = isPermissionDenied
    }
}

public struct RemovalReport: Sendable {
    public let succeededURLs: [URL]
    public let failures: [RemovalFailure]
    public let freedBytes: Int64
    public let needsAppManagementPermission: Bool
    public let usedFinderFallbackToAdmin: Bool
    public let cancelledByUser: Bool

    public init(
        succeededURLs: [URL],
        failures: [RemovalFailure],
        freedBytes: Int64,
        needsAppManagementPermission: Bool = false,
        usedFinderFallbackToAdmin: Bool = false,
        cancelledByUser: Bool = false
    ) {
        self.succeededURLs = succeededURLs
        self.failures = failures
        self.freedBytes = freedBytes
        self.needsAppManagementPermission = needsAppManagementPermission
        self.usedFinderFallbackToAdmin = usedFinderFallbackToAdmin
        self.cancelledByUser = cancelledByUser
    }

    public var isFullSuccess: Bool {
        failures.isEmpty && !cancelledByUser
    }
}

public struct RemovalEngine: Sendable {
    public let safetyGuard: SafetyGuard
    public let privilegedExecutor: PrivilegedExecutor
    public let historyStore: CleanupHistoryStore?

    public init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        privilegedExecutor: PrivilegedExecutor? = nil,
        historyStore: CleanupHistoryStore? = nil
    ) {
        self.safetyGuard = safetyGuard
        self.privilegedExecutor = privilegedExecutor ?? PrivilegedExecutor(safetyGuard: safetyGuard)
        self.historyStore = historyStore
    }

    /// Gracefully terminates running apps matching the given bundle IDs; optionally force-terminates after timeout.
    public static func terminateRunningApps(
        bundleIDs: [String],
        forceAfterTimeout: Bool = false,
        timeoutSeconds: TimeInterval = 3.0
    ) async -> [String] {
        let lowerTargets = Set(bundleIDs.map { $0.lowercased() })
        guard !lowerTargets.isEmpty else { return [] }

        let matching = NSWorkspace.shared.runningApplications.filter { app in
            guard let bid = app.bundleIdentifier?.lowercased() else { return false }
            return lowerTargets.contains(bid)
        }
        guard !matching.isEmpty else { return [] }

        for app in matching {
            app.terminate()
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if matching.allSatisfy(\.isTerminated) {
                return []
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        var stillRunning: [String] = []
        for app in matching where !app.isTerminated {
            if forceAfterTimeout {
                app.forceTerminate()
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            if !app.isTerminated, let bid = app.bundleIdentifier {
                stillRunning.append(bid)
            }
        }
        return stillRunning
    }

    /// Removes target items using Trash (default) or Permanent Delete.
    /// - Always validates via `SafetyGuard` (raw + resolved paths) and removes raw URLs (never following symlinks).
    /// - For root/EPERM items in `.trash` mode: delegates to Finder `delete` first (preserves Put Back),
    ///   falling back to single-prompt privileged `mv` if Finder automation is declined (Decision A1).
    public func remove(
        targets: [RemovalTarget],
        mode: RemovalMode,
        actionTitle: String = "Cleanup",
        packageIDsToForget: [String] = [],
        allowElevation: Bool = true
    ) -> RemovalReport {
        let fm = FileManager.default
        var succeeded: [URL] = []
        var failures: [RemovalFailure] = []
        var privilegedQueue: [RemovalTarget] = []
        var freedBytes: Int64 = 0
        var needsAppMgmt = false
        var usedFallback = false
        var cancelled = false

        // Deduplicate by raw standardized path while preserving order.
        var seen = Set<String>()
        let uniqueTargets = targets.filter { target in
            let p = target.url.standardizedFileURL.path
            return seen.insert(p).inserted
        }

        for target in uniqueTargets {
            let rawURL = target.url.standardizedFileURL
            switch safetyGuard.validateForRemoval(rawURL) {
            case .allowed:
                break
            case let .blocked(reason):
                failures.append(RemovalFailure(url: rawURL, reason: reason))
                continue
            }

            // Use `lstat` so broken symlinks are still recognized as existing entries.
            var st = stat()
            guard lstat(rawURL.path, &st) == 0 else {
                continue
            }

            if target.requiresAdmin || safetyGuard.requiresAdmin(for: rawURL) {
                privilegedQueue.append(target)
                continue
            }

            do {
                switch mode {
                case .trash:
                    try fm.trashItem(at: rawURL, resultingItemURL: nil)
                case .permanent:
                    try fm.removeItem(at: rawURL)
                }
                succeeded.append(rawURL)
                freedBytes += target.estimatedSize
            } catch {
                let nsErr = error as NSError
                let isPermError = Self.isPermissionDenied(nsErr)
                if isPermError && rawURL.pathExtension.lowercased() == "app" {
                    needsAppMgmt = true
                }
                if isPermError && allowElevation {
                    // Retry via Finder / elevated batch below.
                    privilegedQueue.append(target)
                } else {
                    failures.append(RemovalFailure(
                        url: rawURL,
                        reason: error.localizedDescription,
                        isPermissionDenied: isPermError
                    ))
                }
            }
        }

        // Process privileged batch + pkgutil receipts
        if !privilegedQueue.isEmpty || (!packageIDsToForget.isEmpty && allowElevation) {
            let privURLs = privilegedQueue.map { $0.url.standardizedFileURL }
            let privBytes = privilegedQueue.reduce(Int64(0)) { $0 + $1.estimatedSize }

            if !allowElevation {
                for item in privilegedQueue {
                    failures.append(RemovalFailure(
                        url: item.url,
                        reason: "Administrator permission required",
                        isPermissionDenied: true
                    ))
                }
            } else {
                do {
                    switch mode {
                    case .trash:
                        if !privURLs.isEmpty {
                            do {
                                try privilegedExecutor.moveToTrashViaFinder(urls: privURLs)
                            } catch PrivilegedError.finderAutomationDenied {
                                usedFallback = true
                                try privilegedExecutor.moveToTrashPrivileged(urls: privURLs)
                            }
                        }
                        if !packageIDsToForget.isEmpty {
                            try privilegedExecutor.removePermanentlyPrivileged(
                                urls: [],
                                packageIDsToForget: packageIDsToForget
                            )
                        }
                    case .permanent:
                        try privilegedExecutor.removePermanentlyPrivileged(
                            urls: privURLs,
                            packageIDsToForget: packageIDsToForget
                        )
                    }

                    succeeded.append(contentsOf: privURLs)
                    freedBytes += privBytes
                    // If Finder succeeded on an .app that previously returned EPERM, clear appMgmt warning.
                    if privURLs.allSatisfy({ !fm.fileExists(atPath: $0.path) }) {
                        needsAppMgmt = false
                    }
                } catch PrivilegedError.userCancelled {
                    cancelled = true
                } catch {
                    for item in privilegedQueue {
                        if item.url.pathExtension.lowercased() == "app" {
                            needsAppMgmt = true
                        }
                        failures.append(RemovalFailure(
                            url: item.url,
                            reason: error.localizedDescription,
                            isPermissionDenied: true
                        ))
                    }
                }
            }
        }

        if !succeeded.isEmpty, let historyStore {
            let record = CleanupRecord(
                actionTitle: actionTitle,
                mode: mode,
                itemCount: succeeded.count,
                freedBytes: freedBytes,
                removedPaths: succeeded.map(\.path)
            )
            historyStore.append(record)
        }

        return RemovalReport(
            succeededURLs: succeeded,
            failures: failures,
            freedBytes: freedBytes,
            needsAppManagementPermission: needsAppMgmt,
            usedFinderFallbackToAdmin: usedFallback,
            cancelledByUser: cancelled
        )
    }

    private static func isPermissionDenied(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError {
            return true
        }
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(EPERM) || error.code == Int(EACCES)) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isPermissionDenied(underlying)
        }
        return false
    }
}

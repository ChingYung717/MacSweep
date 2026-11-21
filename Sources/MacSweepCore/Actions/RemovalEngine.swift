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
    public let warnings: [String]
    public let freedBytes: Int64
    public let needsAppManagementPermission: Bool
    public let usedFinderFallbackToAdmin: Bool
    public let cancelledByUser: Bool

    public init(
        succeededURLs: [URL],
        failures: [RemovalFailure],
        warnings: [String] = [],
        freedBytes: Int64,
        needsAppManagementPermission: Bool = false,
        usedFinderFallbackToAdmin: Bool = false,
        cancelledByUser: Bool = false
    ) {
        self.succeededURLs = succeededURLs
        self.failures = failures
        self.warnings = warnings
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
    public typealias LocalTrashHandler = @Sendable (URL) throws -> Void

    public let safetyGuard: SafetyGuard
    public let privilegedExecutor: PrivilegedExecutor
    public let historyStore: CleanupHistoryStore?
    private let localTrashHandler: LocalTrashHandler?

    public init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        privilegedExecutor: PrivilegedExecutor? = nil,
        historyStore: CleanupHistoryStore? = nil,
        localTrashHandler: LocalTrashHandler? = nil
    ) {
        self.safetyGuard = safetyGuard
        self.privilegedExecutor = privilegedExecutor ?? PrivilegedExecutor(safetyGuard: safetyGuard)
        self.historyStore = historyStore
        self.localTrashHandler = localTrashHandler
    }

    /// Gracefully terminates running apps matching the given bundle IDs OR running from inside `bundleURLs`
    /// (catches embedded MenuBar / Helper processes whose bundle ID differs from the main app).
    public static func terminateRunningApps(
        bundleIDs: [String],
        bundleURLs: [URL] = [],
        forceAfterTimeout: Bool = false,
        timeoutSeconds: TimeInterval = 3.0
    ) async -> [String] {
        let lowerTargets = Set(bundleIDs.map { $0.lowercased() }.filter { !$0.isEmpty && !$0.hasPrefix("unknown.") })
        let appPaths = bundleURLs.map { $0.standardizedFileURL.path }
        guard !lowerTargets.isEmpty || !appPaths.isEmpty else { return [] }

        let matching = NSWorkspace.shared.runningApplications.filter { app in
            if let bid = app.bundleIdentifier?.lowercased(), lowerTargets.contains(bid) {
                return true
            }
            if let appURL = app.bundleURL?.standardizedFileURL.path {
                for base in appPaths where appURL == base || appURL.hasPrefix(base + "/") {
                    return true
                }
            }
            return false
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
            if !app.isTerminated {
                let id = app.bundleIdentifier ?? app.localizedName ?? "pid:\(app.processIdentifier)"
                if !stillRunning.contains(id) {
                    stillRunning.append(id)
                }
            }
        }
        return stillRunning
    }

    /// Removes target items using Trash (default) or Permanent Delete.
    ///
    /// Order & safety guarantees:
    /// 1. Validates every target via `SafetyGuard` (raw + resolved paths); deletes ONLY raw URLs (never follows symlinks).
    /// 2. Runs known `privilegedQueue` items BEFORE `normalQueue` items so cancelling an admin/Finder prompt
    ///    leaves zero normal files half-deleted.
    /// 3. In `.trash` mode, delegates privileged items to Finder `delete` first (preserves Put Back), falling back
    ///    to `moveToTrashPrivileged` if Finder automation is denied or Finder cannot handle an entry (e.g. dangling link).
    /// 4. Reconciles EVERY privileged item via `lstat` after execution so only truly gone entries are counted.
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
        var warnings: [String] = []
        var normalQueue: [RemovalTarget] = []
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

        // Phase 1: Validate & partition into normal vs privileged
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
            guard Self.entryExists(rawURL) else {
                continue
            }

            if target.requiresAdmin || safetyGuard.requiresAdmin(for: rawURL) {
                privilegedQueue.append(target)
            } else {
                normalQueue.append(target)
            }
        }

        // Phase 2: Execute known privileged batch FIRST so cancelling authorization leaves normal files untouched.
        // Note: In `.permanent` mode, defer `pkgutil --forget` until normalQueue also succeeds unless normalQueue is empty.
        let deferPkgForget = (mode == .permanent && !normalQueue.isEmpty && !packageIDsToForget.isEmpty)
        let initialPkgIDs = (mode == .permanent && failures.isEmpty && !deferPkgForget) ? packageIDsToForget : []

        if !privilegedQueue.isEmpty || (!initialPkgIDs.isEmpty && allowElevation) {
            runPrivilegedBatch(
                queue: privilegedQueue,
                mode: mode,
                packageIDs: initialPkgIDs,
                allowElevation: allowElevation,
                succeeded: &succeeded,
                failures: &failures,
                warnings: &warnings,
                freedBytes: &freedBytes,
                needsAppMgmt: &needsAppMgmt,
                usedFallback: &usedFallback,
                cancelled: &cancelled
            )
        }

        // Phase 3: Execute normal-permission items (only if user did not cancel elevation).
        var unexpectedElevatedQueue: [RemovalTarget] = []
        if !cancelled {
            for target in normalQueue {
                let rawURL = target.url.standardizedFileURL
                guard Self.entryExists(rawURL) else { continue }
                do {
                    switch mode {
                    case .trash:
                        if let localTrashHandler {
                            try localTrashHandler(rawURL)
                        } else {
                            try fm.trashItem(at: rawURL, resultingItemURL: nil)
                        }
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
                        unexpectedElevatedQueue.append(target)
                    } else {
                        failures.append(RemovalFailure(
                            url: rawURL,
                            reason: error.localizedDescription,
                            isPermissionDenied: isPermError
                        ))
                    }
                }
            }

            // Phase 3b: Handle any normal items that unexpectedly returned EPERM (plus deferred pkgutil --forget).
            let finalPkgIDs = (mode == .permanent && deferPkgForget && failures.isEmpty) ? packageIDsToForget : []
            if !unexpectedElevatedQueue.isEmpty || (!finalPkgIDs.isEmpty && allowElevation) {
                runPrivilegedBatch(
                    queue: unexpectedElevatedQueue,
                    mode: mode,
                    packageIDs: finalPkgIDs,
                    allowElevation: allowElevation,
                    succeeded: &succeeded,
                    failures: &failures,
                    warnings: &warnings,
                    freedBytes: &freedBytes,
                    needsAppMgmt: &needsAppMgmt,
                    usedFallback: &usedFallback,
                    cancelled: &cancelled
                )
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
            warnings: warnings,
            freedBytes: freedBytes,
            needsAppManagementPermission: needsAppMgmt,
            usedFinderFallbackToAdmin: usedFallback,
            cancelledByUser: cancelled
        )
    }

    private func runPrivilegedBatch(
        queue: [RemovalTarget],
        mode: RemovalMode,
        packageIDs: [String],
        allowElevation: Bool,
        succeeded: inout [URL],
        failures: inout [RemovalFailure],
        warnings: inout [String],
        freedBytes: inout Int64,
        needsAppMgmt: inout Bool,
        usedFallback: inout Bool,
        cancelled: inout Bool
    ) {
        let privURLs = queue.map { $0.url.standardizedFileURL }

        if !allowElevation {
            for item in queue {
                failures.append(RemovalFailure(
                    url: item.url,
                    reason: "Administrator permission required",
                    isPermissionDenied: true
                ))
            }
            return
        }

        var batchError: Error?
        do {
            switch mode {
            case .trash:
                if !privURLs.isEmpty {
                    do {
                        try privilegedExecutor.moveToTrashViaFinder(urls: privURLs)
                    } catch PrivilegedError.finderAutomationDenied, PrivilegedError.finderOperationFailed {
                        usedFallback = true
                        // Only pass items that still exist (Finder may have partially moved some).
                        let remaining = privURLs.filter { Self.entryExists($0) }
                        if !remaining.isEmpty {
                            try privilegedExecutor.moveToTrashPrivileged(urls: remaining)
                        }
                    }
                }
            case .permanent:
                try privilegedExecutor.removePermanentlyPrivileged(
                    urls: privURLs,
                    packageIDsToForget: packageIDs
                )
            }
        } catch PrivilegedError.userCancelled {
            cancelled = true
        } catch {
            batchError = error
        }

        // Reconcile per item against the filesystem via `lstat` (even if cancelled after a partial Finder move).
        for item in queue {
            let url = item.url.standardizedFileURL
            if Self.entryExists(url) {
                if !cancelled {
                    let errMsg = batchError?.localizedDescription ?? "Item still exists after privileged removal"
                    let permRelated = Self.isLikelyPermissionMessage(errMsg)
                    if permRelated && url.pathExtension.lowercased() == "app" {
                        needsAppMgmt = true
                    }
                    failures.append(RemovalFailure(
                        url: url,
                        reason: errMsg,
                        isPermissionDenied: permRelated
                    ))
                }
            } else {
                succeeded.append(url)
                freedBytes += item.estimatedSize
            }
        }

        if let errDesc = batchError?.localizedDescription, errDesc.contains("chown-failed:") {
            warnings.append("Some items moved to Trash kept root ownership; emptying Trash may ask for your password.")
        }

        if !privURLs.isEmpty && privURLs.allSatisfy({ !Self.entryExists($0) }) {
            needsAppMgmt = false
        }
    }

    /// `lstat`-based existence check (treats dangling symlinks as existing, never follows links).
    public static func entryExists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
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

    private static func isLikelyPermissionMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("permission") || lower.contains("operation not permitted")
            || lower.contains("not authorized") || lower.contains("(-1743)") || lower.contains("eperm")
    }
}

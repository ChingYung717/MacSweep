import AppKit
import Darwin
import Foundation

public struct RemovalTarget: Sendable, Hashable {
    public let url: URL
    public let estimatedSize: Int64
    public let requiresAdmin: Bool
    /// Canonical POSIX parent directory captured at scan / confirmation construction time
    /// so parent-directory swaps between scan, confirmation, and execution are blocked.
    public let expectedCanonicalParent: String

    public init(
        url: URL,
        estimatedSize: Int64 = 0,
        requiresAdmin: Bool = false,
        expectedCanonicalParent: String? = nil
    ) {
        self.url = url
        self.estimatedSize = estimatedSize
        self.requiresAdmin = requiresAdmin
        self.expectedCanonicalParent = expectedCanonicalParent
            ?? PrivilegedExecutor.canonicalParentPath(forTargetURL: url)
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

    /// Gracefully terminates running apps belonging to `bundleURLs`:
    /// - Always authorizes processes whose `bundleURL` or `executableURL` resides inside `bundleURLs`
    ///   (catches embedded MenuBar / Helper processes and legitimate unsigned apps launched from the bundle).
    /// - For processes matched solely by `bundleID`, verifies via `SecCodeCopyGuestWithAttributes`
    ///   (`kSecGuestAttributePid`) that the running PID's verified TeamID / signing identity matches
    ///   an uninstalling `.app` in `bundleURLs`. Refuses to terminate unrelated processes even when
    ///   a spoofed `.app` resides in `/Applications` or `~/Applications`.
    /// - When `bundleURLs` is empty, refuses to terminate by `bundleID` alone unless
    ///   `allowBundleIDOnlyWithoutAppURL` is explicitly set (e.g. quitting a known browser before
    ///   browser-extension removal).
    public static func terminateRunningApps(
        bundleIDs: [String],
        bundleURLs: [URL] = [],
        allowBundleIDOnlyWithoutAppURL: Bool = false,
        forceAfterTimeout: Bool = false,
        timeoutSeconds: TimeInterval = 3.0
    ) async -> [String] {
        let lowerTargets = Set(bundleIDs.map { $0.lowercased() }.filter {
            !$0.isEmpty && !$0.hasPrefix("unknown.") && $0 != "com.apple"
        })
        guard !lowerTargets.isEmpty || !bundleURLs.isEmpty else { return [] }
        if bundleURLs.isEmpty && !allowBundleIDOnlyWithoutAppURL {
            return []
        }

        let cachedAppIdentities: [CodeSigningIdentity]? = bundleURLs.isEmpty
            ? nil
            : bundleURLs.compactMap { AppScanner.extractAppSigningIdentity(at: $0) }

        let matching = NSWorkspace.shared.runningApplications.filter { app in
            if bundleURLs.isEmpty {
                guard allowBundleIDOnlyWithoutAppURL,
                      let bid = app.bundleIdentifier?.lowercased() else {
                    return false
                }
                return lowerTargets.contains(bid)
            }
            return AppScanner.isProcessAuthorizedForAppMatch(
                pid: app.processIdentifier,
                processBundleID: app.bundleIdentifier,
                processBundleURL: app.bundleURL,
                processExecutableURL: app.executableURL,
                targetBundleIDs: lowerTargets,
                targetAppURLs: bundleURLs,
                cachedAppIdentities: cachedAppIdentities
            )
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
        var normalQueue: [(target: RemovalTarget, expectedParent: String?)] = []
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

        // Phase 1: Validate & partition into normal vs privileged using scan-time expectedCanonicalParent.
        for target in uniqueTargets {
            let rawURL = target.url.standardizedFileURL
            switch safetyGuard.validateForRemoval(rawURL) {
            case .allowed:
                break
            case let .blocked(reason):
                failures.append(RemovalFailure(url: rawURL, reason: reason))
                continue
            }

            let liveParent = PrivilegedExecutor.canonicalParentPath(forTargetURL: rawURL)
            if liveParent != target.expectedCanonicalParent {
                failures.append(RemovalFailure(
                    url: rawURL,
                    reason: "Parent directory changed since scan (TOCTOU blocked)"
                ))
                continue
            }

            // Use `lstat` so broken symlinks are still recognized as existing entries.
            guard Self.entryExists(rawURL) else {
                continue
            }

            if target.requiresAdmin || safetyGuard.requiresAdmin(for: rawURL) {
                privilegedQueue.append(target)
            } else {
                normalQueue.append((target, target.expectedCanonicalParent))
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
            for entry in normalQueue {
                let target = entry.target
                let rawURL = target.url.standardizedFileURL

                // Re-validate immediately before local deletion to close the Phase 2 -> Phase 3
                // cross-authentication TOCTOU window (e.g. parent swapped to symlink pointing into TCC).
                switch safetyGuard.validateForRemoval(rawURL) {
                case .allowed:
                    break
                case let .blocked(reason):
                    failures.append(RemovalFailure(url: rawURL, reason: reason))
                    continue
                }
                guard Self.entryExists(rawURL) else { continue }

                if let expectedParent = entry.expectedParent {
                    let currentParent = PrivilegedExecutor.canonicalParentPath(
                        for: rawURL.deletingLastPathComponent().path
                    )
                    if currentParent != expectedParent {
                        failures.append(RemovalFailure(
                            url: rawURL,
                            reason: "Parent directory changed during removal (TOCTOU blocked)"
                        ))
                        continue
                    }
                }

                do {
                    switch mode {
                    case .trash:
                        try Self.verifyParentAndUnlockUserImmutable(
                            at: rawURL,
                            expectedCanonicalParent: entry.expectedParent,
                            safetyGuard: safetyGuard
                        )
                        if let localTrashHandler {
                            try localTrashHandler(rawURL)
                        } else {
                            try fm.trashItem(at: rawURL, resultingItemURL: nil)
                        }
                    case .permanent:
                        try Self.removeEntryConfined(
                            at: rawURL,
                            expectedCanonicalParent: entry.expectedParent,
                            safetyGuard: safetyGuard
                        )
                    }
                    succeeded.append(rawURL)
                    freedBytes += target.estimatedSize
                } catch let privErr as PrivilegedError {
                    failures.append(RemovalFailure(
                        url: rawURL,
                        reason: privErr.localizedDescription,
                        isPermissionDenied: false
                    ))
                } catch {
                    let nsErr = error as NSError
                    let isPermError = Self.isPermissionDenied(nsErr)
                    if isPermError && rawURL.pathExtension.lowercased() == "app" {
                        needsAppMgmt = true
                    }
                    // Do not blindly escalate to root `rm` when an `EACCES` occurred on an item owned
                    // by the current user inside a parent writable by the current user (e.g. inaccessible
                    // user-owned subtree that could not be unlocked locally).
                    let isUnwritableUserOwnedAccess = (nsErr.domain == NSPOSIXErrorDomain
                        && nsErr.code == Int(EACCES)
                        && Self.isOwnedByCurrentUser(rawURL)
                        && !safetyGuard.requiresAdmin(for: rawURL))
                    if isPermError && allowElevation && !isUnwritableUserOwnedAccess {
                        unexpectedElevatedQueue.append(target)
                    } else {
                        let reason: String
                        if isPermError && safetyGuard.isUserImmutable(rawURL) {
                            reason = "Item is locked (uchg) and could not be unlocked: \(error.localizedDescription)"
                        } else {
                            reason = error.localizedDescription
                        }
                        failures.append(RemovalFailure(
                            url: rawURL,
                            reason: reason,
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
        // Re-verify scan-time expectedCanonicalParent immediately before running privileged batch.
        var validQueue: [RemovalTarget] = []
        validQueue.reserveCapacity(queue.count)
        for item in queue {
            let stdURL = item.url.standardizedFileURL
            let liveParent = PrivilegedExecutor.canonicalParentPath(forTargetURL: stdURL)
            if liveParent != item.expectedCanonicalParent {
                failures.append(RemovalFailure(
                    url: stdURL,
                    reason: "Parent directory changed since scan (TOCTOU blocked)"
                ))
                continue
            }
            validQueue.append(item)
        }
        guard !validQueue.isEmpty || (!packageIDs.isEmpty && allowElevation) else {
            return
        }

        let privURLs = validQueue.map { $0.url.standardizedFileURL }
        let expectedParents = Dictionary(
            uniqueKeysWithValues: validQueue.map { ($0.url.standardizedFileURL.path, $0.expectedCanonicalParent) }
        )

        if !allowElevation {
            for item in validQueue {
                failures.append(RemovalFailure(
                    url: item.url,
                    reason: "Administrator permission required",
                    isPermissionDenied: true
                ))
            }
            return
        }

        var batchError: Error?
        var batchOutput = ""
        var trashMoveTargets: [URL] = []
        do {
            switch mode {
            case .trash:
                if !privURLs.isEmpty {
                    do {
                        try privilegedExecutor.moveToTrashViaFinder(
                            urls: privURLs,
                            expectedCanonicalParents: expectedParents
                        )
                    } catch PrivilegedError.finderAutomationDenied, PrivilegedError.finderOperationFailed {
                        usedFallback = true
                        // Only pass items that still exist (Finder may have partially moved some).
                        let remaining = privURLs.filter { Self.entryExists($0) }
                        if !remaining.isEmpty {
                            trashMoveTargets = remaining
                            let res = try privilegedExecutor.moveToTrashPrivilegedWithOutput(
                                urls: remaining,
                                expectedCanonicalParents: expectedParents
                            )
                            batchOutput = res.stdout + "\n" + res.stderr
                        }
                    }
                }
            case .permanent:
                try privilegedExecutor.removePermanentlyPrivileged(
                    urls: privURLs,
                    packageIDsToForget: packageIDs,
                    expectedCanonicalParents: expectedParents
                )
            }
        } catch PrivilegedError.userCancelled {
            cancelled = true
        } catch let PrivilegedError.commandFailed(detail) {
            batchError = PrivilegedError.commandFailed(detail: detail)
            batchOutput += "\n" + detail
        } catch {
            batchError = error
        }

        let failedTrashPaths = Self.parseTrashMoveFailures(from: batchOutput, targets: trashMoveTargets)
        let strandedTrashPaths = Self.parseStrandedTrashPaths(from: batchOutput, targets: trashMoveTargets)

        // Reconcile per item against the filesystem via `lstat` (even if cancelled after a partial Finder move),
        // AND treat any item marked `trash-move-failed:` / `trash-stranded-idx:` as failed even if it no longer
        // exists at its original path.
        for item in validQueue {
            let url = item.url.standardizedFileURL
            let strandedPath = strandedTrashPaths[url.path]
            let failedTrashMove = failedTrashPaths.contains(url.path) || (strandedPath != nil)
            if failedTrashMove || Self.entryExists(url) {
                if !cancelled {
                    let errMsg: String
                    if let strandedPath {
                        errMsg = "Failed to place item into Trash; item remains at temporary staging path: \(strandedPath)"
                        warnings.append("Item left at staging path: \(strandedPath)")
                    } else if failedTrashMove {
                        errMsg = batchError?.localizedDescription
                            ?? "Failed to place staged item into Trash"
                    } else {
                        errMsg = batchError?.localizedDescription ?? "Item still exists after privileged removal"
                    }
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

        if batchOutput.contains("chown-failed:") || batchOutput.contains("root-owned-trash:") {
            warnings.append("Some items moved to Trash kept root ownership; emptying Trash may ask for your password.")
        }

        if !privURLs.isEmpty && failedTrashPaths.isEmpty && strandedTrashPaths.isEmpty && privURLs.allSatisfy({ !Self.entryExists($0) }) {
            needsAppMgmt = false
        }
    }

    /// Parses `trash-move-failed-idx:<idx>` and `trash-move-failed:<path>` markers from script output
    /// or osascript error strings so stranded staged items are never misreported as succeeded.
    internal static func parseTrashMoveFailures(from output: String, targets: [URL]) -> Set<String> {
        var failed = Set<String>()
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if let range = line.range(of: "trash-move-failed-idx:") {
                var token = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if let paren = token.range(of: #" \(\d+\)$"#, options: .regularExpression) {
                    token = String(token[..<paren.lowerBound])
                }
                if let idx = Int(token), idx >= 0, idx < targets.count {
                    failed.insert(targets[idx].standardizedFileURL.path)
                }
            } else if let range = line.range(of: "trash-move-failed:") {
                var path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if let paren = path.range(of: #" \(\d+\)$"#, options: .regularExpression) {
                    path = String(path[..<paren.lowerBound])
                }
                if !path.isEmpty {
                    failed.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
                }
            }
        }
        return failed
    }

    /// Parses `trash-stranded-idx:<idx>:<stagedPath>` markers emitted when rollback fails or is skipped,
    /// returning `[targetStandardizedPath: strandedStagingPath]`.
    internal static func parseStrandedTrashPaths(from output: String, targets: [URL]) -> [String: String] {
        var stranded: [String: String] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            guard let range = line.range(of: "trash-stranded-idx:") else { continue }
            var rest = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let paren = rest.range(of: #" \(\d+\)$"#, options: .regularExpression) {
                rest = String(rest[..<paren.lowerBound])
            }
            guard let colon = rest.firstIndex(of: ":") else { continue }
            let idxStr = String(rest[..<colon])
            let stagedPath = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let idx = Int(idxStr), idx >= 0, idx < targets.count, !stagedPath.isEmpty {
                stranded[targets[idx].standardizedFileURL.path] = stagedPath
            }
        }
        return stranded
    }

    // MARK: - Confined FD-Based Local Removal & Iterative Tree Traversal

    private static let maxDirectoryTraversalDepth = 512
    private static let maxCachedOpenFDs = 48
    private static let kernelSIPFlagMask: UInt32 = UInt32(SF_RESTRICTED) | UInt32(SF_IMMUTABLE) | UInt32(SF_NOUNLINK)

    private static func isOwnedByCurrentUser(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return st.st_uid == geteuid()
    }

    private static func verifyCanonicalParent(
        parentFD: Int32,
        rawURL: URL,
        expectedCanonicalParent: String?,
        safetyGuard: SafetyGuard
    ) throws {
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(parentFD, F_GETPATH, &pathBuf) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let nulIndex = pathBuf.firstIndex(of: 0) ?? pathBuf.count
        let canonicalParent = String(
            decoding: pathBuf[..<nulIndex].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        if let expectedCanonicalParent, canonicalParent != expectedCanonicalParent {
            throw PrivilegedError.blockedBySafetyGuard(
                path: rawURL.path,
                reason: "Parent directory changed during removal (TOCTOU blocked)"
            )
        }
        let canonicalTarget = URL(fileURLWithPath: canonicalParent).appendingPathComponent(rawURL.lastPathComponent)
        if case let .blocked(reason) = safetyGuard.validateForRemoval(canonicalTarget) {
            throw PrivilegedError.blockedBySafetyGuard(path: rawURL.path, reason: reason)
        }
    }

    /// Confirms the open parent directory FD matches `expectedCanonicalParent` and unlocks user-owned
    /// `UF_IMMUTABLE` (`uchg`) via `O_EVTONLY | O_NOFOLLOW` + `fchflags` before trashing.
    private static func verifyParentAndUnlockUserImmutable(
        at rawURL: URL,
        expectedCanonicalParent: String?,
        safetyGuard: SafetyGuard
    ) throws {
        let parentURL = rawURL.deletingLastPathComponent()
        let baseName = rawURL.lastPathComponent
        guard !baseName.isEmpty, baseName != ".", baseName != "..", !baseName.contains("/") else {
            throw PrivilegedError.blockedBySafetyGuard(path: rawURL.path, reason: "Invalid target basename")
        }
        let parentFD = open(parentURL.path, O_SEARCH | O_DIRECTORY)
        if parentFD < 0 {
            let err = errno
            if err == ENOENT { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        defer { close(parentFD) }

        try verifyCanonicalParent(
            parentFD: parentFD,
            rawURL: rawURL,
            expectedCanonicalParent: expectedCanonicalParent,
            safetyGuard: safetyGuard
        )
        clearUserImmutableIfOwned(parentFD: parentFD, name: baseName)
    }

    /// Clears `UF_IMMUTABLE` (`uchg`) on a non-symlink, non-SIP entry owned by the current user
    /// relative to `parentFD` without following symlinks. Returns `true` if `UF_IMMUTABLE` was cleared.
    @discardableResult
    private static func clearUserImmutableIfOwned(parentFD: Int32, name: String) -> Bool {
        var st = stat()
        guard fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
              (st.st_mode & S_IFMT) != S_IFLNK,
              st.st_uid == geteuid(),
              (st.st_flags & kernelSIPFlagMask) == 0,
              (st.st_flags & UInt32(UF_IMMUTABLE)) != 0 else {
            return false
        }
        let fd = openat(parentFD, name, O_EVTONLY | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var fdStat = stat()
        guard fstat(fd, &fdStat) == 0,
              fdStat.st_uid == geteuid(),
              (fdStat.st_flags & kernelSIPFlagMask) == 0,
              (fdStat.st_flags & UInt32(UF_IMMUTABLE)) != 0 else {
            return false
        }
        return fchflags(fd, fdStat.st_flags & ~UInt32(UF_IMMUTABLE)) == 0
    }

    @discardableResult
    private static func ensureUserOwnedDirectoryAccessible(parentFD: Int32, name: String) -> Bool {
        var st = stat()
        guard fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == geteuid(),
              (st.st_flags & kernelSIPFlagMask) == 0 else {
            return false
        }
        if (st.st_flags & UInt32(UF_IMMUTABLE)) != 0 {
            clearUserImmutableIfOwned(parentFD: parentFD, name: name)
        }
        return fchmodat(parentFD, name, (st.st_mode & 0o7777) | 0o700, AT_SYMLINK_NOFOLLOW) == 0
    }

    @discardableResult
    private static func ensureUserOwnedOpenDirWritable(fd: Int32) -> Bool {
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == geteuid(),
              (st.st_flags & kernelSIPFlagMask) == 0 else {
            return false
        }
        if (st.st_flags & UInt32(UF_IMMUTABLE)) != 0 {
            _ = fchflags(fd, st.st_flags & ~UInt32(UF_IMMUTABLE))
        }
        return fchmod(fd, (st.st_mode & 0o7777) | 0o700) == 0
    }

    private static func openSubdirectoryNoFollow(parentFD: Int32, name: String) -> (fd: Int32, err: Int32) {
        var fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd >= 0 {
            return (fd, 0)
        }
        var err = errno
        if err == EACCES && ensureUserOwnedDirectoryAccessible(parentFD: parentFD, name: name) {
            fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if fd >= 0 {
                return (fd, 0)
            }
            err = errno
        }
        return (-1, err)
    }

    private static func openRelativeDirectoryNoFollow(rootFD: Int32, components: [String]) throws -> Int32 {
        if components.isEmpty {
            let duplicated = dup(rootFD)
            if duplicated < 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return duplicated
        }
        var currentFD: Int32 = -1
        for (idx, comp) in components.enumerated() {
            let base = (idx == 0) ? rootFD : currentFD
            let (nextFD, err) = openSubdirectoryNoFollow(parentFD: base, name: comp)
            if currentFD >= 0 {
                close(currentFD)
            }
            if nextFD < 0 {
                if err == ENOENT { return -1 }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
            }
            currentFD = nextFD
        }
        return currentFD
    }

    private static func readDirectoryChildren(dirFD: Int32) throws -> [(name: String, isDir: Bool)] {
        let dupFD = dup(dirFD)
        guard dupFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard let dirp = fdopendir(dupFD) else {
            let err = errno
            close(dupFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        defer { closedir(dirp) }
        rewinddir(dirp)

        var children: [(name: String, isDir: Bool)] = []
        while true {
            errno = 0
            guard let ent = readdir(dirp) else {
                let err = errno
                if err != 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
                }
                break
            }
            let childName = withUnsafePointer(to: ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: ent.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if childName == "." || childName == ".." { continue }
            var childStat = stat()
            if fstatat(dirFD, childName, &childStat, AT_SYMLINK_NOFOLLOW) != 0 {
                let err = errno
                if err == ENOENT { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
            }
            children.append((childName, (childStat.st_mode & S_IFMT) == S_IFDIR))
        }
        return children
    }

    private static func readSubdirectoryNames(dirFD: Int32) throws -> [String] {
        let dupFD = dup(dirFD)
        guard dupFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard let dirp = fdopendir(dupFD) else {
            let err = errno
            close(dupFD)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        defer { closedir(dirp) }
        rewinddir(dirp)

        var subdirs: [String] = []
        while true {
            errno = 0
            guard let ent = readdir(dirp) else {
                let err = errno
                if err != 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
                }
                break
            }
            let dType = Int32(ent.pointee.d_type)
            if dType != DT_DIR && dType != DT_UNKNOWN {
                continue
            }
            let childName = withUnsafePointer(to: ent.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: ent.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            if childName == "." || childName == ".." { continue }
            if dType == DT_UNKNOWN {
                var childStat = stat()
                if fstatat(dirFD, childName, &childStat, AT_SYMLINK_NOFOLLOW) != 0 {
                    let err = errno
                    if err == ENOENT { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
                }
                if (childStat.st_mode & S_IFMT) != S_IFDIR { continue }
            }
            subdirs.append(childName)
        }
        return subdirs
    }

    private static func unlinkChild(in dirFD: Int32, name: String, isDir: Bool, allowMutateDir: Bool) throws {
        let flag: Int32 = isDir ? AT_REMOVEDIR : 0
        if unlinkat(dirFD, name, flag) == 0 {
            return
        }
        var err = errno
        if err == ENOENT { return }

        if err == EACCES || err == EPERM {
            // 1. Unlock UF_IMMUTABLE on the target entry itself and retry immediately without touching `dirFD`.
            if clearUserImmutableIfOwned(parentFD: dirFD, name: name) {
                if unlinkat(dirFD, name, flag) == 0 {
                    return
                }
                err = errno
                if err == ENOENT { return }
            }
            // 2. Mutate `dirFD` mode/flags ONLY for interior directories inside the tree being deleted,
            //    never widening permissions on an external `parentFD`.
            if allowMutateDir && (err == EACCES || err == EPERM) && ensureUserOwnedOpenDirWritable(fd: dirFD) {
                if unlinkat(dirFD, name, flag) == 0 {
                    return
                }
                err = errno
                if err == ENOENT { return }
            }
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
    }

    /// Permanently removes a local entry via an open parent directory FD (`O_SEARCH | O_DIRECTORY`,
    /// `F_GETPATH`, and `unlinkat` / iterative `openat(..., O_NOFOLLOW)`) so parent-symlink TOCTOU,
    /// symlink traversal, `-wx` parent errors, user-owned unreadable subdirs, and depth-64 partial
    /// deletion cliffs are all eliminated.
    private static func removeEntryConfined(
        at rawURL: URL,
        expectedCanonicalParent: String?,
        safetyGuard: SafetyGuard
    ) throws {
        let parentURL = rawURL.deletingLastPathComponent()
        let baseName = rawURL.lastPathComponent
        guard !baseName.isEmpty, baseName != ".", baseName != "..", !baseName.contains("/") else {
            throw PrivilegedError.blockedBySafetyGuard(path: rawURL.path, reason: "Invalid target basename")
        }

        let parentFD = open(parentURL.path, O_SEARCH | O_DIRECTORY)
        if parentFD < 0 {
            let err = errno
            if err == ENOENT { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        defer { close(parentFD) }

        try verifyCanonicalParent(
            parentFD: parentFD,
            rawURL: rawURL,
            expectedCanonicalParent: expectedCanonicalParent,
            safetyGuard: safetyGuard
        )

        var st = stat()
        if fstatat(parentFD, baseName, &st, AT_SYMLINK_NOFOLLOW) != 0 {
            let err = errno
            if err == ENOENT { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            try unlinkChild(in: parentFD, name: baseName, isDir: false, allowMutateDir: false)
            return
        }
        try removeDirectoryTreeAt(parentFD: parentFD, name: baseName)
    }

    private struct TraversalFrame {
        var relPath: [String]
        var pendingSubdirs: [String]
        var scanned: Bool
        var cachedFD: Int32
    }

    /// Read-only iterative pre-flight depth check so excessively deep trees (> `maxDirectoryTraversalDepth`)
    /// fail with `ELOOP` BEFORE any child entry is deleted (eliminating mid-deletion partial failures).
    private static func preflightValidateDirectoryDepth(rootFD: Int32, maxDepth: Int) throws {
        var stack: [TraversalFrame] = [
            TraversalFrame(relPath: [], pendingSubdirs: [], scanned: false, cachedFD: -1),
        ]
        defer {
            for frame in stack where frame.cachedFD >= 0 {
                close(frame.cachedFD)
            }
        }

        while !stack.isEmpty {
            let idx = stack.count - 1
            var tempFD: Int32 = -1
            defer {
                if tempFD >= 0 { close(tempFD) }
            }

            let dirFD: Int32
            if stack[idx].relPath.isEmpty {
                dirFD = rootFD
            } else if stack[idx].cachedFD >= 0 {
                dirFD = stack[idx].cachedFD
            } else {
                let opened = try openRelativeDirectoryNoFollow(rootFD: rootFD, components: stack[idx].relPath)
                if opened < 0 {
                    let frame = stack.removeLast()
                    if frame.cachedFD >= 0 { close(frame.cachedFD) }
                    continue
                }
                tempFD = opened
                dirFD = opened
            }

            if !stack[idx].scanned {
                let subdirs = try readSubdirectoryNames(dirFD: dirFD)
                if !subdirs.isEmpty && stack[idx].relPath.count >= maxDepth {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ELOOP))
                }
                stack[idx].pendingSubdirs = subdirs.reversed()
                stack[idx].scanned = true
            }

            if let nextSub = stack[idx].pendingSubdirs.popLast() {
                let (subFD, err) = openSubdirectoryNoFollow(parentFD: dirFD, name: nextSub)
                if subFD < 0 {
                    if err == ENOENT || err == ELOOP || err == ENOTDIR || err == EACCES {
                        continue
                    }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
                }
                let nextRel = stack[idx].relPath + [nextSub]
                if stack.count < maxCachedOpenFDs {
                    stack.append(TraversalFrame(relPath: nextRel, pendingSubdirs: [], scanned: false, cachedFD: subFD))
                } else {
                    close(subFD)
                    stack.append(TraversalFrame(relPath: nextRel, pendingSubdirs: [], scanned: false, cachedFD: -1))
                }
            } else {
                let frame = stack.removeLast()
                if frame.cachedFD >= 0 { close(frame.cachedFD) }
            }
        }
    }

    private static func removeDirectoryTreeAt(parentFD: Int32, name: String) throws {
        let (openedRoot, openErr) = openSubdirectoryNoFollow(parentFD: parentFD, name: name)
        if openedRoot < 0 {
            if openErr == ENOENT { return }
            if openErr == ELOOP || openErr == ENOTDIR {
                var st = stat()
                if fstatat(parentFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) != S_IFDIR {
                    try unlinkChild(in: parentFD, name: name, isDir: false, allowMutateDir: false)
                    return
                }
            }
            if openErr == EACCES {
                try unlinkChild(in: parentFD, name: name, isDir: true, allowMutateDir: false)
                return
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(openErr))
        }

        var targetRootFD = openedRoot
        defer {
            if targetRootFD >= 0 { close(targetRootFD) }
        }

        try preflightValidateDirectoryDepth(rootFD: targetRootFD, maxDepth: maxDirectoryTraversalDepth)

        var stack: [TraversalFrame] = [
            TraversalFrame(relPath: [], pendingSubdirs: [], scanned: false, cachedFD: -1),
        ]
        defer {
            for frame in stack where frame.cachedFD >= 0 {
                close(frame.cachedFD)
            }
        }

        while !stack.isEmpty {
            let idx = stack.count - 1
            var tempFD: Int32 = -1
            defer {
                if tempFD >= 0 { close(tempFD) }
            }

            let dirFD: Int32
            if stack[idx].relPath.isEmpty {
                dirFD = targetRootFD
            } else if stack[idx].cachedFD >= 0 {
                dirFD = stack[idx].cachedFD
            } else {
                let opened = try openRelativeDirectoryNoFollow(rootFD: targetRootFD, components: stack[idx].relPath)
                if opened < 0 {
                    let frame = stack.removeLast()
                    if frame.cachedFD >= 0 { close(frame.cachedFD) }
                    continue
                }
                tempFD = opened
                dirFD = opened
            }

            if !stack[idx].scanned {
                let children = try readDirectoryChildren(dirFD: dirFD)
                var subdirs: [String] = []
                for child in children {
                    if child.isDir {
                        subdirs.append(child.name)
                    } else {
                        try unlinkChild(in: dirFD, name: child.name, isDir: false, allowMutateDir: true)
                    }
                }
                stack[idx].pendingSubdirs = subdirs.reversed()
                stack[idx].scanned = true
            }

            if let nextSub = stack[idx].pendingSubdirs.popLast() {
                let (subFD, err) = openSubdirectoryNoFollow(parentFD: dirFD, name: nextSub)
                if subFD < 0 {
                    if err == ENOENT { continue }
                    if err == ELOOP || err == ENOTDIR {
                        try unlinkChild(in: dirFD, name: nextSub, isDir: false, allowMutateDir: true)
                        continue
                    }
                    if err == EACCES {
                        try unlinkChild(in: dirFD, name: nextSub, isDir: true, allowMutateDir: true)
                        continue
                    }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
                }
                let nextRel = stack[idx].relPath + [nextSub]
                if stack.count < maxCachedOpenFDs {
                    stack.append(TraversalFrame(relPath: nextRel, pendingSubdirs: [], scanned: false, cachedFD: subFD))
                } else {
                    close(subFD)
                    stack.append(TraversalFrame(relPath: nextRel, pendingSubdirs: [], scanned: false, cachedFD: -1))
                }
            } else {
                if tempFD >= 0 {
                    close(tempFD)
                    tempFD = -1
                }
                let finished = stack.removeLast()
                if finished.cachedFD >= 0 { close(finished.cachedFD) }

                if let childName = finished.relPath.last, let parentFrame = stack.last {
                    var tempParentFD: Int32 = -1
                    defer {
                        if tempParentFD >= 0 { close(tempParentFD) }
                    }
                    let parentFrameFD: Int32
                    if parentFrame.relPath.isEmpty {
                        parentFrameFD = targetRootFD
                    } else if parentFrame.cachedFD >= 0 {
                        parentFrameFD = parentFrame.cachedFD
                    } else {
                        let opened = try openRelativeDirectoryNoFollow(rootFD: targetRootFD, components: parentFrame.relPath)
                        if opened < 0 { continue }
                        tempParentFD = opened
                        parentFrameFD = opened
                    }
                    try unlinkChild(in: parentFrameFD, name: childName, isDir: true, allowMutateDir: true)
                }
            }
        }

        close(targetRootFD)
        targetRootFD = -1
        try unlinkChild(in: parentFD, name: name, isDir: true, allowMutateDir: false)
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

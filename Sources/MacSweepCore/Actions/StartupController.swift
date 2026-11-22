import Darwin
import Foundation

public enum StartupControlError: Error, LocalizedError, Sendable {
    case notToggleable
    case invalidLabel
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notToggleable:
            return "App Login Items must be managed in macOS System Settings → Login Items"
        case .invalidLabel:
            return "Invalid launchd service label"
        case let .failed(msg):
            return msg
        }
    }
}

/// A launchd job that must be unloaded (`bootout`) before its plist is removed.
public struct LaunchServiceTarget: Sendable, Hashable {
    public let label: String
    /// Nil when the plist could not be read as non-root (e.g. `0600 root:wheel`), so the elevated
    /// script resolves `:Label` with `PlistBuddy` before calling `launchctl bootout`.
    public let labelFromPlist: String?
    public let domain: String
    public let plistURL: URL

    public init(label: String, domain: String, plistURL: URL, labelFromPlist: String? = nil) {
        self.label = label
        self.labelFromPlist = labelFromPlist
        self.domain = domain
        self.plistURL = plistURL
    }

    public var serviceTarget: String { "\(domain)/\(label)" }
    public var needsAdmin: Bool { domain == "system" }
}

public struct LaunchUnloadReport: Sendable {
    /// Plists whose service is confirmed NOT loaded anymore (safe to delete).
    public let unloadedPlists: Set<String>
    /// Plists whose service is still loaded after bootout (must NOT be deleted).
    public let stillLoadedPlists: Set<String>
    public let cancelledByUser: Bool
    public let errorMessage: String?
}

public struct StartupController: Sendable {
    public let privilegedExecutor: PrivilegedExecutor
    public let launchctlPath: String

    public init(
        privilegedExecutor: PrivilegedExecutor = PrivilegedExecutor(),
        launchctlPath: String = "/bin/launchctl"
    ) {
        self.privilegedExecutor = privilegedExecutor
        self.launchctlPath = launchctlPath
    }

    private static func validatedLabel(_ raw: String) throws -> String {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = label.lowercased()
        guard !label.isEmpty,
              !label.contains("\0"),
              lower != "com.apple",
              !lower.hasPrefix("com.apple."),
              !label.contains("/"),
              !label.contains("\n"),
              !label.contains("\r"),
              !label.contains(where: { $0.isWhitespace || $0.isASCII && ($0.asciiValue ?? 32) < 32 }) else {
            throw StartupControlError.invalidLabel
        }
        return label
    }

    private static func isSymlink(at path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    public static func domain(for scope: StartupScope, uid: uid_t = getuid()) -> String {
        scope == .systemDaemon ? "system" : "gui/\(uid)"
    }

    /// Builds the enable/disable script.
    ///
    /// - enable:  `enable` must succeed; `bootstrap` failure is tolerated ONLY if the service is
    ///            afterwards confirmed loaded via `launchctl print` (i.e. it was already loaded).
    /// - disable: `disable` must succeed; `bootout` failure is tolerated ONLY if the service is
    ///            afterwards confirmed NOT loaded via `launchctl print` (distinguishes "not loaded"
    ///            from "refused to unload").
    public static func buildToggleShellCommand(
        item: StartupItem,
        enable: Bool,
        uid: uid_t = getuid(),
        launchctl: String = "/bin/launchctl",
        allowedLaunchDirs: [URL]? = nil
    ) throws -> (domain: String, shellCommand: String) {
        guard item.canToggle else { throw StartupControlError.notToggleable }
        let label = try validatedLabel(item.label)
        let stdPlist = item.plistURL.standardizedFileURL
        let plistPath = stdPlist.path
        guard stdPlist.isFileURL,
              !plistPath.contains("\0"),
              stdPlist.pathExtension.lowercased() == "plist",
              !isSymlink(at: plistPath) else {
            throw StartupControlError.invalidLabel
        }
        if let allowedLaunchDirs {
            let allowedLower = Set(allowedLaunchDirs.map { $0.standardizedFileURL.path.lowercased() })
            let parentLower = stdPlist.deletingLastPathComponent().path.lowercased()
            let resolvedParentLower = stdPlist.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
            let allowedResolvedLower = Set(allowedLaunchDirs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path.lowercased() })
            guard allowedLower.contains(parentLower) || allowedResolvedLower.contains(resolvedParentLower) else {
                throw StartupControlError.invalidLabel
            }
        }
        let domain = domain(for: item.scope, uid: uid)
        let qL = ProcessRunner.posixQuote(launchctl)
        let qTarget = ProcessRunner.posixQuote("\(domain)/\(label)")
        let qDomain = ProcessRunner.posixQuote(domain)
        let qPlist = ProcessRunner.posixQuote(plistPath)

        if enable {
            let cmd = "\(qL) enable \(qTarget) && { \(qL) bootstrap \(qDomain) \(qPlist) || \(qL) print \(qTarget) >/dev/null 2>&1; }"
            return (domain, cmd)
        } else {
            let cmd = "\(qL) disable \(qTarget) && { \(qL) bootout \(qTarget) >/dev/null 2>&1 || ! \(qL) print \(qTarget) >/dev/null 2>&1; }"
            return (domain, cmd)
        }
    }

    /// Builds a script that boots out every target and then VERIFIES it is no longer loaded.
    /// For unreadable root plists (`labelFromPlist == nil`), resolves `:Label` via PlistBuddy while root
    /// and validates the resolved label (rejecting `com.apple.*`, `/`, and whitespace/control characters).
    /// Exits non-zero (and prints `still-loaded:<plist>` lines to stderr) if any service survived.
    public static func buildUnloadShellCommand(
        targets: [LaunchServiceTarget],
        launchctl: String = "/bin/launchctl"
    ) -> String {
        guard !targets.isEmpty else { return "" }
        let qL = ProcessRunner.posixQuote(launchctl)
        var statements = ["fail=0"]
        for t in targets {
            let plistPath = t.plistURL.standardizedFileURL.path
            let qPlist = ProcessRunner.posixQuote(plistPath)
            let qDomain = ProcessRunner.posixQuote(t.domain)
            let qFallbackLabel = ProcessRunner.posixQuote(t.label)
            let qMarker = ProcessRunner.posixQuote("still-loaded:\(plistPath)")

            if t.labelFromPlist != nil {
                let qTarget = ProcessRunner.posixQuote(t.serviceTarget)
                statements.append("tgt=\(qTarget)")
            } else {
                // Dynamically read Label as root when non-root could not open a 0600 plist,
                // then validate against com.apple.*, '/', and whitespace/control chars.
                statements.append(
                    "lbl=$(/usr/libexec/PlistBuddy -c 'Print :Label' \(qPlist) 2>/dev/null | /usr/bin/tr -d '\\r\\n' || true); "
                        + "lbl_lc=$(printf '%s' \"$lbl\" | /usr/bin/tr '[:upper:]' '[:lower:]'); "
                        + "case \"$lbl_lc\" in ''|'com.apple'|'com.apple.'*|*/*|*[[:space:]]*|*[[:cntrl:]]*) lbl=\(qFallbackLabel) ;; esac; "
                        + "tgt=\(qDomain)/\"$lbl\""
                )
            }

            statements.append("\(qL) bootout \"$tgt\" >/dev/null 2>&1")
            // A job that is mid-spawn (or KeepAlive-respawned) may survive a single bootout:
            // re-check and retry for up to ~2 s before declaring it still loaded.
            statements.append(
                "n=0; while \(qL) print \"$tgt\" >/dev/null 2>&1 && [ $n -lt 10 ]; do "
                    + "/bin/sleep 0.2; \(qL) bootout \"$tgt\" >/dev/null 2>&1; n=$((n+1)); done"
            )
            statements.append("if \(qL) print \"$tgt\" >/dev/null 2>&1; then echo \(qMarker) >&2; fail=1; fi")
        }
        statements.append("exit $fail")
        return statements.joined(separator: "; ")
    }

    /// Default macOS launchd plist directories.
    public static func defaultLaunchDirectories(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            homeDirectory.appendingPathComponent("Library/LaunchAgents").standardizedFileURL,
            URL(fileURLWithPath: "/Library/LaunchAgents").standardizedFileURL,
            URL(fileURLWithPath: "/Library/LaunchDaemons").standardizedFileURL,
        ]
    }

    /// Derives launchd targets ONLY from plists located directly inside `allowedLaunchDirs`
    /// (defaults to `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`).
    /// Deduplicates by plist path (NOT by `serviceTarget`) so duplicate-label plists across user &
    /// system LaunchAgents are BOTH tracked and protected.
    public static func launchTargets(
        for urls: [URL],
        uid: uid_t = getuid(),
        allowedLaunchDirs: [URL]? = nil
    ) -> [LaunchServiceTarget] {
        let dirs = allowedLaunchDirs ?? defaultLaunchDirectories()
        let allowedLower = Set(dirs.map { $0.standardizedFileURL.path.lowercased() })
        let allowedResolvedLower = Set(dirs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path.lowercased() })
        var result: [LaunchServiceTarget] = []
        var seenPlistPaths = Set<String>()

        for url in urls {
            let std = url.standardizedFileURL
            guard std.isFileURL,
                  !std.path.contains("\0"),
                  std.pathExtension.lowercased() == "plist",
                  !isSymlink(at: std.path) else { continue }
            let parentPath = std.deletingLastPathComponent().path.lowercased()
            let resolvedParent = std.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
            guard allowedLower.contains(parentPath) || allowedResolvedLower.contains(resolvedParent) else { continue }
            guard seenPlistPaths.insert(std.path.lowercased()).inserted else { continue }

            let parentName = std.deletingLastPathComponent().lastPathComponent.lowercased()
            let domain = (parentName == "launchdaemons") ? "system" : "gui/\(uid)"
            let parsed = LibraryIndex.parseLaunchPlistMetadata(at: std)
            let rawLabel = parsed.label ?? std.deletingPathExtension().lastPathComponent
            guard let label = try? validatedLabel(rawLabel) else { continue }

            result.append(LaunchServiceTarget(
                label: label,
                domain: domain,
                plistURL: std,
                labelFromPlist: parsed.label
            ))
        }
        return result
    }

    /// Extracts `still-loaded:<plist>` markers from raw stderr OR from an osascript error message
    /// such as `0:42: execution error: still-loaded:/Library/LaunchDaemons/x.plist (1)`.
    public static func parseStillLoadedPlists(from stderr: String) -> Set<String> {
        var result = Set<String>()
        for line in stderr.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: "still-loaded:") else { continue }
            var path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let paren = path.range(of: #" \(\d+\)$"#, options: .regularExpression) {
                path = String(path[..<paren.lowerBound])
            }
            if !path.isEmpty {
                result.insert(path)
            }
        }
        return result
    }

    public func setEnabled(_ enable: Bool, for item: StartupItem) throws {
        let (_, shellCmd) = try Self.buildToggleShellCommand(
            item: item,
            enable: enable,
            uid: getuid(),
            launchctl: launchctlPath,
            allowedLaunchDirs: Self.defaultLaunchDirectories()
        )

        // Only the `system` domain needs root. Agents (incl. /Library/LaunchAgents) live in the user's
        // gui domain, whose enable/disable overrides are per-user and do not require admin.
        if item.scope == .systemDaemon {
            try privilegedExecutor.runWithAdministratorPrivileges(shellCommand: shellCmd)
        } else {
            let res = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", shellCmd])
            if !res.succeeded {
                let msg = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw StartupControlError.failed(msg.isEmpty ? "launchctl exited with status \(res.exitCode)" : msg)
            }
        }
    }

    /// Unloads launchd services BEFORE their plists are removed.
    /// Runs `system` targets FIRST so cancelling the administrator dialog never prematurely boots out user agents.
    public func unloadBeforeRemoval(_ targets: [LaunchServiceTarget]) -> LaunchUnloadReport {
        var unloaded = Set<String>()
        var stillLoaded = Set<String>()
        var errors: [String] = []

        let systemTargets = targets.filter(\.needsAdmin)
        let userTargets = targets.filter { !$0.needsAdmin }

        func record(_ batch: [LaunchServiceTarget], stderr: String, succeeded: Bool) {
            let survivors = Self.parseStillLoadedPlists(from: stderr)
            for t in batch {
                let p = t.plistURL.standardizedFileURL.path
                if survivors.contains(p) || (!succeeded && survivors.isEmpty) {
                    stillLoaded.insert(p)
                } else {
                    unloaded.insert(p)
                }
            }
        }

        if !systemTargets.isEmpty {
            let cmd = Self.buildUnloadShellCommand(targets: systemTargets, launchctl: launchctlPath)
            do {
                try privilegedExecutor.runWithAdministratorPrivileges(shellCommand: cmd)
                record(systemTargets, stderr: "", succeeded: true)
            } catch PrivilegedError.userCancelled {
                return LaunchUnloadReport(
                    unloadedPlists: [],
                    stillLoadedPlists: Set(targets.map { $0.plistURL.standardizedFileURL.path }),
                    cancelledByUser: true,
                    errorMessage: nil
                )
            } catch let PrivilegedError.commandFailed(detail) {
                record(systemTargets, stderr: detail, succeeded: false)
                errors.append(detail)
            } catch {
                record(systemTargets, stderr: "", succeeded: false)
                errors.append(error.localizedDescription)
            }
        }

        if !userTargets.isEmpty {
            let cmd = Self.buildUnloadShellCommand(targets: userTargets, launchctl: launchctlPath)
            let res = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", cmd])
            record(userTargets, stderr: res.stderr, succeeded: res.succeeded)
            if !res.succeeded { errors.append(res.stderr) }
        }

        let message = errors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return LaunchUnloadReport(
            unloadedPlists: unloaded,
            stillLoadedPlists: stillLoaded,
            cancelledByUser: false,
            errorMessage: message.isEmpty ? nil : message
        )
    }
}

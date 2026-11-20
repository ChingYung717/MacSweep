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
    public let domain: String
    public let plistURL: URL

    public init(label: String, domain: String, plistURL: URL) {
        self.label = label
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
        guard !label.isEmpty,
              !label.lowercased().hasPrefix("com.apple."),
              !label.contains("/"),
              !label.contains("\n") else {
            throw StartupControlError.invalidLabel
        }
        return label
    }

    public static func domain(for scope: StartupScope, uid: uid_t = getuid()) -> String {
        scope == .systemDaemon ? "system" : "gui/\(uid)"
    }

    /// Builds the enable/disable script.
    ///
    /// - enable:  `enable` must succeed; `bootstrap` failure is tolerated ONLY if the service is
    ///            afterwards confirmed loaded via `launchctl print` (i.e. it was already loaded).
    /// - disable: `disable` must succeed; `bootout` is best-effort (the job may simply not be loaded)
    ///            and is isolated in its own `{ ...; }` group so it cannot mask the `disable` status.
    public static func buildToggleShellCommand(
        item: StartupItem,
        enable: Bool,
        uid: uid_t = getuid(),
        launchctl: String = "/bin/launchctl"
    ) throws -> (domain: String, shellCommand: String) {
        guard item.canToggle else { throw StartupControlError.notToggleable }
        let label = try validatedLabel(item.label)
        let domain = domain(for: item.scope, uid: uid)
        let qL = ProcessRunner.posixQuote(launchctl)
        let qTarget = ProcessRunner.posixQuote("\(domain)/\(label)")
        let qDomain = ProcessRunner.posixQuote(domain)
        let qPlist = ProcessRunner.posixQuote(item.plistURL.standardizedFileURL.path)

        if enable {
            let cmd = "\(qL) enable \(qTarget) && { \(qL) bootstrap \(qDomain) \(qPlist) || \(qL) print \(qTarget) >/dev/null 2>&1; }"
            return (domain, cmd)
        } else {
            let cmd = "\(qL) disable \(qTarget) && { \(qL) bootout \(qTarget) >/dev/null 2>&1 || true; }"
            return (domain, cmd)
        }
    }

    /// Builds a script that boots out every target and then VERIFIES it is no longer loaded.
    /// Exits non-zero (and prints `still-loaded:<plist>` lines to stderr) if any service survived.
    public static func buildUnloadShellCommand(
        targets: [LaunchServiceTarget],
        launchctl: String = "/bin/launchctl"
    ) -> String {
        guard !targets.isEmpty else { return "" }
        let qL = ProcessRunner.posixQuote(launchctl)
        var statements = ["fail=0"]
        for t in targets {
            let qTarget = ProcessRunner.posixQuote(t.serviceTarget)
            let qMarker = ProcessRunner.posixQuote("still-loaded:\(t.plistURL.standardizedFileURL.path)")
            statements.append("\(qL) bootout \(qTarget) >/dev/null 2>&1")
            // A job that is mid-spawn (or KeepAlive-respawned) may survive a single bootout: re-check and
            // retry for up to ~2 s before declaring it still loaded.
            statements.append(
                "n=0; while \(qL) print \(qTarget) >/dev/null 2>&1 && [ $n -lt 10 ]; do "
                    + "/bin/sleep 0.2; \(qL) bootout \(qTarget) >/dev/null 2>&1; n=$((n+1)); done"
            )
            statements.append("if \(qL) print \(qTarget) >/dev/null 2>&1; then echo \(qMarker) >&2; fail=1; fi")
        }
        statements.append("exit $fail")
        return statements.joined(separator: "; ")
    }

    /// Derives launchd targets from plists located in LaunchAgents / LaunchDaemons directories.
    public static func launchTargets(for urls: [URL], uid: uid_t = getuid()) -> [LaunchServiceTarget] {
        var result: [LaunchServiceTarget] = []
        var seen = Set<String>()
        for url in urls {
            let std = url.standardizedFileURL
            guard std.pathExtension.lowercased() == "plist" else { continue }
            let parent = std.deletingLastPathComponent().lastPathComponent
            let domain: String
            switch parent {
            case "LaunchDaemons":
                domain = "system"
            case "LaunchAgents":
                domain = "gui/\(uid)"
            default:
                continue
            }
            let parsed = LibraryIndex.parseLaunchPlistMetadata(at: std)
            let rawLabel = parsed.label ?? std.deletingPathExtension().lastPathComponent
            guard let label = try? validatedLabel(rawLabel) else { continue }
            let target = LaunchServiceTarget(label: label, domain: domain, plistURL: std)
            if seen.insert(target.serviceTarget).inserted {
                result.append(target)
            }
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
            launchctl: launchctlPath
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

    /// Unloads launchd services BEFORE their plists are removed (user domain without prompt,
    /// system domain in a single administrator prompt). Returns which plists are confirmed safe to delete.
    public func unloadBeforeRemoval(_ targets: [LaunchServiceTarget]) -> LaunchUnloadReport {
        var unloaded = Set<String>()
        var stillLoaded = Set<String>()
        var errors: [String] = []

        let userTargets = targets.filter { !$0.needsAdmin }
        let systemTargets = targets.filter(\.needsAdmin)

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

        if !userTargets.isEmpty {
            let cmd = Self.buildUnloadShellCommand(targets: userTargets, launchctl: launchctlPath)
            let res = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", cmd])
            record(userTargets, stderr: res.stderr, succeeded: res.succeeded)
            if !res.succeeded { errors.append(res.stderr) }
        }

        if !systemTargets.isEmpty {
            let cmd = Self.buildUnloadShellCommand(targets: systemTargets, launchctl: launchctlPath)
            do {
                try privilegedExecutor.runWithAdministratorPrivileges(shellCommand: cmd)
                record(systemTargets, stderr: "", succeeded: true)
            } catch PrivilegedError.userCancelled {
                return LaunchUnloadReport(
                    unloadedPlists: unloaded,
                    stillLoadedPlists: stillLoaded.union(systemTargets.map { $0.plistURL.standardizedFileURL.path }),
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

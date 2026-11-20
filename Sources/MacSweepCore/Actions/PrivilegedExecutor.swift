import Darwin
import Foundation

public enum PrivilegedError: Error, LocalizedError, Sendable, Equatable {
    case blockedBySafetyGuard(path: String, reason: String)
    case userCancelled
    case finderAutomationDenied(detail: String)
    case commandFailed(detail: String)

    public var errorDescription: String? {
        switch self {
        case let .blockedBySafetyGuard(path, reason):
            return "Blocked unsafe path \(path): \(reason)"
        case .userCancelled:
            return "Administrator authentication was cancelled"
        case let .finderAutomationDenied(detail):
            return "Finder automation permission denied: \(detail)"
        case let .commandFailed(detail):
            return detail
        }
    }
}

/// Safe elevated command builder and executor using AppleScript (`Finder` or `with administrator privileges`).
public struct PrivilegedExecutor: Sendable {
    /// Executes a script and returns its result. Production uses `/usr/bin/osascript`; tests inject a
    /// non-privileged `/bin/sh` runner so the real admin / Finder code paths can be exercised without prompts.
    public typealias ScriptRunner = @Sendable (_ script: String) -> ProcessResult

    public let safetyGuard: SafetyGuard
    public let trashDirectory: URL
    private let adminShellRunner: ScriptRunner?
    private let finderAppleScriptRunner: ScriptRunner?

    public init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        trashDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"),
        adminShellRunner: ScriptRunner? = nil,
        finderAppleScriptRunner: ScriptRunner? = nil
    ) {
        self.safetyGuard = safetyGuard
        self.trashDirectory = trashDirectory
        self.adminShellRunner = adminShellRunner
        self.finderAppleScriptRunner = finderAppleScriptRunner
    }

    // MARK: - Command Builders (Pure & Unit-Testable)

    /// Builds an injection-safe AppleScript delegating Trash move to Finder (preserves Put Back metadata).
    public func buildFinderTrashAppleScript(urls: [URL]) throws -> String {
        let validated = try validatePaths(urls)
        let posixItems = validated.map { path in
            "(POSIX file \"\(ProcessRunner.appleScriptEscape(path))\")"
        }.joined(separator: ", ")

        return """
        tell application "Finder"
            delete {\(posixItems)}
        end tell
        """
    }

    /// Builds a POSIX-quoted shell script moving privileged items to the user's `~/.Trash` with unique names.
    ///
    /// Error-propagation contract:
    /// - Each item is processed independently inside its own `{ ...; } || fail=1` group, so one failure never
    ///   skips later items and is never masked: the script exits non-zero if ANY item failed.
    /// - `chown -R -P` recursively hands ownership of moved directories back to the user without following
    ///   symlinks (so the user can later empty the Trash without another admin prompt).
    public func buildPrivilegedTrashShellCommand(
        urls: [URL],
        trashDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"),
        uid: uid_t = getuid(),
        gid: gid_t = getgid(),
        timestamp: String? = nil
    ) throws -> String {
        let validated = try validatePaths(urls)
        let stamp = timestamp ?? String(Int(Date().timeIntervalSince1970))
        let trashPath = trashDirectory.standardizedFileURL.path
        let quotedTrash = ProcessRunner.posixQuote(trashPath)

        var statements: [String] = [
            "fail=0",
            "/bin/mkdir -p -- \(quotedTrash) || exit 1",
        ]
        for (idx, path) in validated.enumerated() {
            let base = URL(fileURLWithPath: path).lastPathComponent
            let qSrc = ProcessRunner.posixQuote(path)
            let qDest = ProcessRunner.posixQuote("\(trashPath)/\(base)")
            let qFallback = ProcessRunner.posixQuote("\(trashPath)/\(base)_\(stamp)_\(idx)")
            let owner = "\(uid):\(gid)"

            // `mv` renames the entry itself (never follows a symlink operand).
            statements.append(
                "{ if [ -e \(qDest) ] || [ -L \(qDest) ]; then "
                    + "/bin/mv -- \(qSrc) \(qFallback) && /usr/sbin/chown -R -P \(owner) -- \(qFallback); "
                    + "else /bin/mv -- \(qSrc) \(qDest) && /usr/sbin/chown -R -P \(owner) -- \(qDest); fi; } || fail=1"
            )
        }
        statements.append("exit $fail")
        return statements.joined(separator: "; ")
    }

    /// Builds a POSIX-quoted permanent delete script plus optional `pkgutil --forget`.
    ///
    /// Error-propagation contract (fixes `a && b || true` masking `rm` failures):
    /// - The exit status of `rm` is captured into `ec` and is the exit status of the whole script.
    /// - Receipt forgetting is best-effort, runs ONLY when `rm` succeeded, and lives in its own group so its
    ///   `|| true` can never swallow the `rm` status.
    public func buildPermanentDeleteShellCommand(
        urls: [URL],
        packageIDsToForget: [String] = []
    ) throws -> String {
        let validated = try validatePaths(urls)
        let safePkgIDs = Self.sanitizedPackageIDs(packageIDsToForget)
        guard !validated.isEmpty || !safePkgIDs.isEmpty else { return "" }

        var statements: [String] = ["ec=0"]
        if !validated.isEmpty {
            let quotedPaths = validated.map(ProcessRunner.posixQuote).joined(separator: " ")
            statements.append("/bin/rm -rf -- \(quotedPaths) || ec=$?")
        }
        if !safePkgIDs.isEmpty {
            let forgets = safePkgIDs
                .map { "/usr/sbin/pkgutil --forget \(ProcessRunner.posixQuote($0)) >/dev/null 2>&1 || true" }
                .joined(separator: "; ")
            statements.append("if [ \"$ec\" -eq 0 ]; then \(forgets); fi")
        }
        statements.append("exit $ec")
        return statements.joined(separator: "; ")
    }

    public static func sanitizedPackageIDs(_ ids: [String]) -> [String] {
        var result: [String] = []
        for pkgID in ids {
            let trimmed = pkgID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.lowercased().hasPrefix("com.apple.pkg."),
                  trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }),
                  !result.contains(trimmed) else {
                continue
            }
            result.append(trimmed)
        }
        return result
    }

    // MARK: - Live Execution

    /// Option A1: Delegates Trash move to Finder so macOS preserves "Put Back" ("放回原处")
    /// and prompts Touch ID / password natively when needed.
    public func moveToTrashViaFinder(urls: [URL]) throws {
        guard !urls.isEmpty else { return }
        let script = try buildFinderTrashAppleScript(urls: urls)
        let res = finderAppleScriptRunner?(script)
            ?? ProcessRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", script])
        if res.succeeded { return }

        let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if err.contains("(-128)") || err.localizedCaseInsensitiveContains("User canceled") {
            throw PrivilegedError.userCancelled
        }
        if err.contains("(-1743)") || err.localizedCaseInsensitiveContains("Not authorized to send Apple events") {
            throw PrivilegedError.finderAutomationDenied(detail: err)
        }
        throw PrivilegedError.commandFailed(detail: err.isEmpty ? "Finder delete failed" : err)
    }

    /// Fallback for Option A1 if Finder automation is denied: elevated single-prompt `mv` to `~/.Trash` + `chown`.
    public func moveToTrashPrivileged(urls: [URL]) throws {
        guard !urls.isEmpty else { return }
        let shellCmd = try buildPrivilegedTrashShellCommand(urls: urls, trashDirectory: trashDirectory)
        try runWithAdministratorPrivileges(shellCommand: shellCmd)
    }

    /// Permanent removal + optional `pkgutil --forget` in one administrator prompt.
    public func removePermanentlyPrivileged(urls: [URL], packageIDsToForget: [String] = []) throws {
        guard !urls.isEmpty || !packageIDsToForget.isEmpty else { return }
        let shellCmd = try buildPermanentDeleteShellCommand(urls: urls, packageIDsToForget: packageIDsToForget)
        guard !shellCmd.isEmpty else { return }
        try runWithAdministratorPrivileges(shellCommand: shellCmd)
    }

    /// Executes an arbitrary validated shell command with macOS administrator prompt.
    public func runWithAdministratorPrivileges(shellCommand: String) throws {
        let res: ProcessResult
        if let adminShellRunner {
            res = adminShellRunner(shellCommand)
        } else {
            let escaped = ProcessRunner.appleScriptEscape(shellCommand)
            let script = "do shell script \"\(escaped)\" with administrator privileges"
            res = ProcessRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", script])
        }
        if res.succeeded { return }

        let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if err.contains("(-128)") || err.localizedCaseInsensitiveContains("User canceled") {
            throw PrivilegedError.userCancelled
        }
        throw PrivilegedError.commandFailed(detail: err.isEmpty ? "Administrator command failed" : err)
    }

    private func validatePaths(_ urls: [URL]) throws -> [String] {
        var validated: [String] = []
        validated.reserveCapacity(urls.count)
        for url in urls {
            // Never resolve symlinks before deleting; validate raw + resolved inside SafetyGuard.
            let result = safetyGuard.validateForRemoval(url)
            switch result {
            case .allowed:
                validated.append(url.standardizedFileURL.path)
            case let .blocked(reason):
                throw PrivilegedError.blockedBySafetyGuard(path: url.path, reason: reason)
            }
        }
        return validated
    }
}

import Darwin
import Foundation

public enum PrivilegedError: Error, LocalizedError, Sendable, Equatable {
    case blockedBySafetyGuard(path: String, reason: String)
    case userCancelled
    case finderAutomationDenied(detail: String)
    case finderOperationFailed(detail: String)
    case commandFailed(detail: String)

    public var errorDescription: String? {
        switch self {
        case let .blockedBySafetyGuard(path, reason):
            return "Blocked unsafe path \(path): \(reason)"
        case .userCancelled:
            return "Administrator authentication was cancelled"
        case let .finderAutomationDenied(detail):
            return "Finder automation permission denied: \(detail)"
        case let .finderOperationFailed(detail):
            return "Finder delete failed: \(detail)"
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
    /// Uses `appleScriptExpression` so paths containing CR/LF (e.g. `Icon\r`) are preserved accurately.
    public func buildFinderTrashAppleScript(urls: [URL]) throws -> String {
        let validated = try validatePaths(urls)
        let posixItems = validated.map { path in
            "(POSIX file (\(ProcessRunner.appleScriptExpression(path))))"
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
    /// Builds an atomic, symlink- and hardlink-safe shell script that moves elevated targets into the
    /// user's Trash via a root-exclusive `0700` staging directory, verifies no hardlinked inodes are
    /// chowned, and moves into Trash without following target symlinks (`mv -h -n`).
    public func buildPrivilegedTrashShellCommand(
        urls: [URL],
        trashDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"),
        uid: uid_t = getuid(),
        gid: gid_t = getgid(),
        timestamp: String? = nil
    ) throws -> String {
        let validated = try validatePaths(urls)
        let suffix = timestamp ?? String(UUID().uuidString.prefix(8).lowercased())
        let trashPath = trashDirectory.standardizedFileURL.path
        if trashPath.isEmpty || trashPath == "/" || trashPath.contains("\0") {
            throw PrivilegedError.blockedBySafetyGuard(path: trashPath, reason: "Invalid Trash directory")
        }
        let quotedTrash = ProcessRunner.posixQuote(trashPath)
        let qSuffix = ProcessRunner.posixQuote(suffix)

        var statements: [String] = [
            "fail=0",
            "[ ! -L \(quotedTrash) ] || exit 1",
            "[ -d \(quotedTrash) ] || /bin/mkdir -p -- \(quotedTrash) || exit 1",
            "stage=$(/usr/bin/mktemp -d \"${TMPDIR:-/tmp}/.macsweep-trash.XXXXXXXXXX\") || exit 1",
            "/bin/chmod 0700 \"$stage\" || { /bin/rmdir \"$stage\" >/dev/null 2>&1 || true; exit 1; }",
            "trap '/bin/rmdir \"$stage\" >/dev/null 2>&1 || true' EXIT",
        ]
        for (idx, path) in validated.enumerated() {
            let url = URL(fileURLWithPath: path)
            let base = url.lastPathComponent
            let parentPath = url.deletingLastPathComponent().path
            let expectedParent = Self.canonicalParentPath(for: parentPath)
            let qSrc = ProcessRunner.posixQuote(path)
            let qParent = ProcessRunner.posixQuote(parentPath)
            let qExpectedParent = ProcessRunner.posixQuote(expectedParent)
            let qBase = ProcessRunner.posixQuote(base)
            let qDest = ProcessRunner.posixQuote("\(trashPath)/\(base)")
            let qFallback = ProcessRunner.posixQuote("\(trashPath)/\(base)_\(suffix)_\(idx)")
            let qOwner = ProcessRunner.posixQuote("\(uid):\(gid)")

            // 1. Verify parent canonical path matches pre-validated parent (blocks parent-symlink TOCTOU).
            // 2. Move into root-exclusive 0700 `$stage` before any ownership change.
            // 3. Refuse `chown -R -P` if any non-directory hardlink (`nlink > 1`) exists inside `$staged`
            //    to prevent deterministic hardlink-to-root LPE; only chown dirs and `nlink == 1` entries.
            // 4. Move from `$stage` into Trash using `mv -h -n` (never follows symlinked target dir,
            //    never overwrites existing entry, and never runs `chown` inside user-writable `~/.Trash`).
            statements.append(
                "{ cur_p=$(cd -P -- \(qParent) 2>/dev/null && pwd -P); "
                    + "[ \"$cur_p\" = \(qExpectedParent) ] && "
                    + "staged=\"$stage/item_\(idx)\" && "
                    + "/bin/mv -h -n -- \(qSrc) \"$staged\" && "
                    + "[ ! -e \(qSrc) ] && [ ! -L \(qSrc) ] && "
                    + "{ if [ -z \"$(/usr/bin/find -P \"$staged\" ! -type d -links +1 -print -quit 2>/dev/null)\" ]; then "
                    + "/usr/sbin/chown -R -P -- \(qOwner) \"$staged\" || { echo \"chown-failed:$staged\" >&2; fail=1; }; "
                    + "else "
                    + "/usr/bin/find -P \"$staged\" \\( -type d -o -links 1 \\) -exec /usr/sbin/chown -h -- \(qOwner) {} + 2>/dev/null || true; "
                    + "echo \"chown-failed:$staged (hardlink)\" >&2; fail=1; "
                    + "fi; } && "
                    + "{ target=\(qDest); "
                    + "if [ -e \(qDest) ] || [ -L \(qDest) ]; then target=\(qFallback); fi; "
                    + "if [ -e \"$target\" ] || [ -L \"$target\" ]; then "
                    + "rnd=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/cut -c1-8); "
                    + "target=\(quotedTrash)/\(qBase)_\(qSuffix)_\(idx)_\"$rnd\"; fi; "
                    + "[ ! -e \"$target\" ] && [ ! -L \"$target\" ] && "
                    + "/bin/mv -h -n -- \"$staged\" \"$target\" && "
                    + "[ ! -e \"$staged\" ] && [ ! -L \"$staged\" ]; }; "
                    + "} || fail=1"
            )
        }
        statements.append("exit $fail")
        return statements.joined(separator: "; ")
    }

    /// Builds a POSIX-quoted permanent delete script plus optional `pkgutil --forget`.
    ///
    /// Error-propagation contract:
    /// - Re-verifies each item's canonical parent directory right before `rm -rf` to block parent-symlink TOCTOU.
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
        for path in validated {
            let url = URL(fileURLWithPath: path)
            let parentPath = url.deletingLastPathComponent().path
            let expectedParent = Self.canonicalParentPath(for: parentPath)
            let qPath = ProcessRunner.posixQuote(path)
            let qParent = ProcessRunner.posixQuote(parentPath)
            let qExpectedParent = ProcessRunner.posixQuote(expectedParent)
            statements.append(
                "{ { [ ! -e \(qPath) ] && [ ! -L \(qPath) ]; } || "
                    + "{ cur_p=$(cd -P -- \(qParent) 2>/dev/null && pwd -P); "
                    + "[ \"$cur_p\" = \(qExpectedParent) ] && /bin/rm -rf -- \(qPath); }; } || ec=1"
            )
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

    /// Excludes all `com.apple.*` packages (including bare `com.apple`), rejects leading `-` (option injection),
    /// and rejects shell metacharacters or NUL bytes.
    public static func sanitizedPackageIDs(_ ids: [String]) -> [String] {
        var result: [String] = []
        for pkgID in ids {
            let trimmed = pkgID.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("-"),
                  !trimmed.contains("\0"),
                  lower != "com.apple",
                  !lower.hasPrefix("com.apple."),
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
            ?? ProcessRunner.run(executable: "/usr/bin/osascript", arguments: ["-"], stdinData: Data(script.utf8))
        if res.succeeded { return }

        let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if err.contains("(-128)") || err.localizedCaseInsensitiveContains("User canceled") {
            throw PrivilegedError.userCancelled
        }
        if err.contains("(-1743)") || err.localizedCaseInsensitiveContains("Not authorized to send Apple events") {
            throw PrivilegedError.finderAutomationDenied(detail: err)
        }
        throw PrivilegedError.finderOperationFailed(detail: err.isEmpty ? "Finder delete failed" : err)
    }

    /// Fallback for Option A1 if Finder automation is denied or Finder cannot handle an entry:
    /// elevated single-prompt staged move to `~/.Trash` with hardlink-safe ownership handoff.
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
    /// Passes the AppleScript via stdin (`/usr/bin/osascript -`) so target paths never leak in `ps` `argv`.
    public func runWithAdministratorPrivileges(shellCommand: String) throws {
        let res: ProcessResult
        if let adminShellRunner {
            res = adminShellRunner(shellCommand)
        } else {
            let expr = ProcessRunner.appleScriptExpression(shellCommand)
            let script = "do shell script (\(expr)) with administrator privileges"
            res = ProcessRunner.run(executable: "/usr/bin/osascript", arguments: ["-"], stdinData: Data(script.utf8))
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

    /// Resolves `parentPath` using POSIX `realpath(3)` so it matches `/bin/sh`'s `cd -P && pwd -P`
    /// identically (unlike Foundation's `resolvingSymlinksInPath`, which strips `/private` on macOS).
    private static func canonicalParentPath(for parentPath: String) -> String {
        if let resolved = realpath(parentPath, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: parentPath).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

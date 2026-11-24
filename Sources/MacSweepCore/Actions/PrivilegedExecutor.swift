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
    public func buildFinderTrashAppleScript(
        urls: [URL],
        expectedCanonicalParents: [String: String] = [:]
    ) throws -> String {
        let validated = try validatePaths(urls, expectedCanonicalParents: expectedCanonicalParents)
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
    /// Security guarantees (Scheme A):
    /// - Sets `umask 077` and ignores `$TMPDIR`, staging inside root-only `/private/var/root` when `euid == 0`
    ///   (or sticky `/private/tmp` in non-root unit tests).
    /// - Pins each item's scan-time canonical parent directory inside a subshell (`cd -P` + `pwd -P` sentinel check)
    ///   and moves `./<base>`.
    /// - Never runs `chown -R` as root (eliminating open-dirfd `linkat(2)` / hardlink / ACL LPE classes).
    ///   Root-owned regular files and directories moved as root emit `root-owned-trash:<name>` so the UI warns the user.
    /// - Pins `~/.Trash` inside a subshell verifying BOTH canonical path AND ownership (`stat -f '%u'`), then moves
    ///   into relative `./<target>` with `mv -h -n`.
    /// - If placing into Trash fails, attempts rollback to the pinned original parent and emits
    ///   `trash-move-failed-idx:<idx>` / `trash-move-failed:<path>` (plus `trash-stranded-idx:<idx>:<staged>` whenever
    ///   rollback fails or is skipped) so `RemovalEngine` surfaces stranded staging paths and never misreports success.
    public func buildPrivilegedTrashShellCommand(
        urls: [URL],
        trashDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash"),
        uid: uid_t = getuid(),
        gid: gid_t = getgid(),
        timestamp: String? = nil,
        expectedCanonicalParents: [String: String] = [:]
    ) throws -> String {
        _ = gid // Retained in signature for source compatibility; Scheme A intentionally avoids root chown.
        let validated = try validatePaths(urls, expectedCanonicalParents: expectedCanonicalParents)
        let suffix = timestamp ?? String(UUID().uuidString.prefix(8).lowercased())
        let trashURL = trashDirectory.standardizedFileURL
        let trashPath = trashURL.path
        let trashBase = trashURL.lastPathComponent
        if trashPath.isEmpty || trashPath == "/" || trashPath.contains("\0")
            || trashBase.isEmpty || trashBase == "." || trashBase == ".." || trashBase.contains("/") {
            throw PrivilegedError.blockedBySafetyGuard(path: trashPath, reason: "Invalid Trash directory")
        }
        let trashParentPath = trashURL.deletingLastPathComponent().path
        let expectedTrashParent = Self.canonicalParentPath(for: trashParentPath)
        let expectedTrash = Self.canonicalParentPath(for: trashPath)

        let quotedTrash = ProcessRunner.posixQuote(trashPath)
        let qTrashParent = ProcessRunner.posixQuote(trashParentPath)
        let qExpectedTrashParentX = ProcessRunner.posixQuote("\(expectedTrashParent)\nx")
        let qRelTrashBase = ProcessRunner.posixQuote("./\(trashBase)")
        let qExpectedTrashX = ProcessRunner.posixQuote("\(expectedTrash)\nx")
        let qSuffix = ProcessRunner.posixQuote(suffix)
        let targetUID = String(uid)

        var statements: [String] = [
            "umask 077",
            "fail=0",
            "target_uid=\(targetUID)",
            "[ ! -L \(quotedTrash) ] || exit 1",
            "if [ ! -d \(quotedTrash) ]; then "
                + "[ \"$(/usr/bin/id -u)\" = \"$target_uid\" ] || exit 1; "
                + "( cd -P -- \(qTrashParent) 2>/dev/null "
                + "&& cur_tp=$(pwd -P; printf x) "
                + "&& [ \"$cur_tp\" = \(qExpectedTrashParentX) ] "
                + "&& [ \"$(/usr/bin/stat -f '%u' . 2>/dev/null)\" = \"$target_uid\" ] "
                + "&& /bin/mkdir -- \(qRelTrashBase) ) || exit 1; "
                + "fi",
            "if [ \"$(/usr/bin/id -u)\" -eq 0 ]; then stage_base='/private/var/root'; else stage_base='/private/tmp'; fi",
            "stage=$(/usr/bin/mktemp -d \"$stage_base/.macsweep-trash.XXXXXXXXXX\") || exit 1",
            "/bin/chmod 0700 \"$stage\" || { /bin/rmdir \"$stage\" >/dev/null 2>&1 || true; exit 1; }",
            "trap '/bin/rmdir \"$stage\" >/dev/null 2>&1 || true' EXIT",
        ]
        for (idx, path) in validated.enumerated() {
            let url = URL(fileURLWithPath: path)
            let base = url.lastPathComponent
            let parentPath = url.deletingLastPathComponent().path
            let expectedParent = expectedCanonicalParents[path] ?? Self.canonicalParentPath(for: parentPath)
            let qSrc = ProcessRunner.posixQuote(path)
            let qParent = ProcessRunner.posixQuote(parentPath)
            let qExpectedParentX = ProcessRunner.posixQuote("\(expectedParent)\nx")
            let qRelBase = ProcessRunner.posixQuote("./\(base)")
            let qBase = ProcessRunner.posixQuote(base)
            let qFallbackRel = ProcessRunner.posixQuote("\(base)_\(suffix)_\(idx)")
            let unlockStep = safetyGuard.isUserImmutable(url)
                ? "{ [ -L \(qRelBase) ] || { [ ! -d \(qRelBase) ] && [ \"$(/usr/bin/stat -f '%l' \(qRelBase) 2>/dev/null)\" != \"1\" ]; } || /usr/bin/chflags -h nouchg -- \(qRelBase) 2>/dev/null || true; } && "
                : ""

            statements.append(
                "{ staged=\"$stage/item_\(idx)\"; "
                    + "if ( cd -P -- \(qParent) 2>/dev/null "
                    + "&& cur_p=$(pwd -P; printf x) "
                    + "&& [ \"$cur_p\" = \(qExpectedParentX) ] "
                    + "&& { [ -e \(qRelBase) ] || [ -L \(qRelBase) ]; } "
                    + "&& \(unlockStep)/bin/mv -h -n -- \(qRelBase) \"$staged\" "
                    + "&& [ ! -e \(qRelBase) ] && [ ! -L \(qRelBase) ] ); then "
                    + "was_root_item=0; "
                    + "if [ \"$(/usr/bin/id -u)\" -eq 0 ] && [ \"$target_uid\" != \"0\" ] "
                    + "&& [ ! -L \"$staged\" ] && { [ -d \"$staged\" ] || [ -f \"$staged\" ]; } "
                    + "&& [ \"$(/usr/bin/stat -f '%u' \"$staged\" 2>/dev/null)\" = \"0\" ]; then "
                    + "was_root_item=1; fi; "
                    + "if ! ( cd -P -- \(quotedTrash) 2>/dev/null "
                    + "&& cur_t=$(pwd -P; printf x) "
                    + "&& [ \"$cur_t\" = \(qExpectedTrashX) ] "
                    + "&& [ \"$(/usr/bin/stat -f '%u' . 2>/dev/null)\" = \"$target_uid\" ] "
                    + "&& rel_target=\(qBase) "
                    + "&& { if [ -e \"./$rel_target\" ] || [ -L \"./$rel_target\" ]; then rel_target=\(qFallbackRel); fi; } "
                    + "&& { if [ -e \"./$rel_target\" ] || [ -L \"./$rel_target\" ]; then "
                    + "rnd=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/cut -c1-8); "
                    + "rel_target=\(qBase)_\(qSuffix)_\(idx)_\"$rnd\"; fi; } "
                    + "&& [ ! -e \"./$rel_target\" ] && [ ! -L \"./$rel_target\" ] "
                    + "&& /bin/mv -h -n -- \"$staged\" \"./$rel_target\" "
                    + "&& [ ! -e \"$staged\" ] && [ ! -L \"$staged\" ] "
                    + "&& { [ \"$was_root_item\" -eq 0 ] || { printf 'root-owned-trash:%s\\n' \"$rel_target\" || true; printf 'root-owned-trash:%s\\n' \"$rel_target\" >&2 || true; }; } ); then "
                    + "( cd -P -- \(qParent) 2>/dev/null "
                    + "&& cur_p=$(pwd -P; printf x) "
                    + "&& [ \"$cur_p\" = \(qExpectedParentX) ] "
                    + "&& [ ! -e \(qRelBase) ] && [ ! -L \(qRelBase) ] "
                    + "&& /bin/mv -h -n -- \"$staged\" \(qRelBase) >/dev/null 2>&1 ) || true; "
                    + "if [ -e \"$staged\" ] || [ -L \"$staged\" ]; then "
                    + "printf 'trash-stranded-idx:%s:%s\\n' '\(idx)' \"$staged\" >&2; fi; "
                    + "printf 'trash-move-failed-idx:%s\\ntrash-move-failed:%s\\n' '\(idx)' \(qSrc) >&2; "
                    + "fail=1; fi; "
                    + "else "
                    + "if [ -e \"$staged\" ] || [ -L \"$staged\" ]; then "
                    + "printf 'trash-stranded-idx:%s:%s\\n' '\(idx)' \"$staged\" >&2; "
                    + "printf 'trash-move-failed-idx:%s\\ntrash-move-failed:%s\\n' '\(idx)' \(qSrc) >&2; fi; "
                    + "fail=1; fi; }"
            )
        }
        statements.append("exit $fail")
        return statements.joined(separator: "; ")
    }

    /// Builds a POSIX-quoted permanent delete script plus optional `pkgutil --forget`.
    ///
    /// Error-propagation contract:
    /// - Pins each item's scan-time canonical parent directory inside a subshell (`cd -P` + `pwd -P` sentinel check)
    ///   and operates strictly on relative `./<base>` to block parent-symlink TOCTOU.
    /// - The exit status of `rm` is captured into `ec` and is the exit status of the whole script.
    /// - Receipt forgetting is best-effort, runs ONLY when `rm` succeeded, and lives in its own group so its
    ///   `|| true` can never swallow the `rm` status.
    public func buildPermanentDeleteShellCommand(
        urls: [URL],
        packageIDsToForget: [String] = [],
        expectedCanonicalParents: [String: String] = [:]
    ) throws -> String {
        let validated = try validatePaths(urls, expectedCanonicalParents: expectedCanonicalParents)
        let safePkgIDs = Self.sanitizedPackageIDs(packageIDsToForget)
        guard !validated.isEmpty || !safePkgIDs.isEmpty else { return "" }

        var statements: [String] = ["ec=0"]
        for path in validated {
            let url = URL(fileURLWithPath: path)
            let base = url.lastPathComponent
            let parentPath = url.deletingLastPathComponent().path
            let expectedParent = expectedCanonicalParents[path] ?? Self.canonicalParentPath(for: parentPath)
            let qParent = ProcessRunner.posixQuote(parentPath)
            let qExpectedParentX = ProcessRunner.posixQuote("\(expectedParent)\nx")
            let qRelBase = ProcessRunner.posixQuote("./\(base)")
            let unlockStep = safetyGuard.isUserImmutable(url)
                ? "{ [ -L \(qRelBase) ] || { [ ! -d \(qRelBase) ] && [ \"$(/usr/bin/stat -f '%l' \(qRelBase) 2>/dev/null)\" != \"1\" ]; } || /usr/bin/chflags -h nouchg -- \(qRelBase) 2>/dev/null || true; } && "
                : ""
            statements.append(
                "{ { [ ! -e \(qParent) ] && [ ! -L \(qParent) ]; } || "
                    + "( cd -P -- \(qParent) 2>/dev/null "
                    + "&& cur_p=$(pwd -P; printf x) "
                    + "&& [ \"$cur_p\" = \(qExpectedParentX) ] "
                    + "&& { { [ ! -e \(qRelBase) ] && [ ! -L \(qRelBase) ]; } || { \(unlockStep)/bin/rm -rf -- \(qRelBase); }; } ); } || ec=1"
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
    public func moveToTrashViaFinder(
        urls: [URL],
        expectedCanonicalParents: [String: String] = [:]
    ) throws {
        guard !urls.isEmpty else { return }
        let script = try buildFinderTrashAppleScript(urls: urls, expectedCanonicalParents: expectedCanonicalParents)
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
    /// elevated single-prompt staged move to `~/.Trash` without running `chown -R` as root.
    public func moveToTrashPrivileged(
        urls: [URL],
        expectedCanonicalParents: [String: String] = [:]
    ) throws {
        _ = try moveToTrashPrivilegedWithOutput(urls: urls, expectedCanonicalParents: expectedCanonicalParents)
    }

    internal func moveToTrashPrivilegedWithOutput(
        urls: [URL],
        expectedCanonicalParents: [String: String] = [:]
    ) throws -> ProcessResult {
        guard !urls.isEmpty else { return ProcessResult(exitCode: 0, stdout: "", stderr: "") }
        if adminShellRunner == nil,
           !safetyGuard.isSymbolicLink(trashDirectory),
           !RemovalEngine.entryExists(trashDirectory) {
            try? FileManager.default.createDirectory(
                at: trashDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let shellCmd = try buildPrivilegedTrashShellCommand(
            urls: urls,
            trashDirectory: trashDirectory,
            expectedCanonicalParents: expectedCanonicalParents
        )
        return try runWithAdministratorPrivileges(shellCommand: shellCmd)
    }

    /// Permanent removal + optional `pkgutil --forget` in one administrator prompt.
    public func removePermanentlyPrivileged(
        urls: [URL],
        packageIDsToForget: [String] = [],
        expectedCanonicalParents: [String: String] = [:]
    ) throws {
        guard !urls.isEmpty || !packageIDsToForget.isEmpty else { return }
        let shellCmd = try buildPermanentDeleteShellCommand(
            urls: urls,
            packageIDsToForget: packageIDsToForget,
            expectedCanonicalParents: expectedCanonicalParents
        )
        guard !shellCmd.isEmpty else { return }
        _ = try runWithAdministratorPrivileges(shellCommand: shellCmd)
    }

    /// Executes an arbitrary validated shell command with macOS administrator prompt.
    /// Restricted to `internal` so external callers cannot pass arbitrary shell commands.
    /// Passes the AppleScript via stdin (`/usr/bin/osascript -`) so target paths never leak in `ps` `argv`.
    @discardableResult
    internal func runWithAdministratorPrivileges(shellCommand: String) throws -> ProcessResult {
        let res: ProcessResult
        if let adminShellRunner {
            res = adminShellRunner(shellCommand)
        } else {
            let expr = ProcessRunner.appleScriptExpression(shellCommand)
            let script = "do shell script (\(expr)) with administrator privileges"
            res = ProcessRunner.run(executable: "/usr/bin/osascript", arguments: ["-"], stdinData: Data(script.utf8))
        }
        if res.succeeded { return res }

        let err = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if err.contains("(-128)") || err.localizedCaseInsensitiveContains("User canceled") {
            throw PrivilegedError.userCancelled
        }
        throw PrivilegedError.commandFailed(detail: err.isEmpty ? "Administrator command failed" : err)
    }

    private func validatePaths(
        _ urls: [URL],
        expectedCanonicalParents: [String: String] = [:]
    ) throws -> [String] {
        var validated: [String] = []
        validated.reserveCapacity(urls.count)
        for url in urls {
            // Never resolve symlinks before deleting; validate raw + resolved inside SafetyGuard.
            let result = safetyGuard.validateForRemoval(url)
            switch result {
            case .allowed:
                let std = url.standardizedFileURL
                let base = std.lastPathComponent
                guard !base.isEmpty, base != ".", base != "..", !base.contains("/") else {
                    throw PrivilegedError.blockedBySafetyGuard(path: url.path, reason: "Invalid target basename")
                }
                if let expectedParent = expectedCanonicalParents[std.path] {
                    let parentURL = std.deletingLastPathComponent()
                    let liveParent = Self.canonicalParentPath(for: parentURL.path)
                    if liveParent != expectedParent {
                        throw PrivilegedError.blockedBySafetyGuard(
                            path: std.path,
                            reason: "Parent directory changed since scan (TOCTOU blocked)"
                        )
                    }
                }
                validated.append(std.path)
            case let .blocked(reason):
                throw PrivilegedError.blockedBySafetyGuard(path: url.path, reason: reason)
            }
        }
        return validated
    }

    /// Resolves the canonical parent directory of a target file/bundle URL at scan/discovery time.
    public static func canonicalParentPath(forTargetURL url: URL) -> String {
        canonicalParentPath(for: url.standardizedFileURL.deletingLastPathComponent().path)
    }

    /// Resolves `parentPath` using POSIX `realpath(3)` so it matches `/bin/sh`'s `cd -P && pwd -P`
    /// identically (unlike Foundation's `resolvingSymlinksInPath`, which strips `/private` on macOS).
    /// On failure (e.g. `EACCES` or `ENOENT`), resolves the deepest existing ancestor and normalizes
    /// macOS `/var`, `/tmp`, `/etc` roots to `/private/...`.
    public static func canonicalParentPath(for parentPath: String) -> String {
        if let resolved = realpath(parentPath, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        var current = URL(fileURLWithPath: parentPath).standardizedFileURL
        var trailing: [String] = []
        while current.path != "/" {
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            trailing.append(current.lastPathComponent)
            current = parent
            if let resolved = realpath(current.path, nil) {
                defer { free(resolved) }
                var base = URL(fileURLWithPath: String(cString: resolved))
                for comp in trailing.reversed() {
                    base.appendPathComponent(comp)
                }
                return applyMacOSPrivatePrefix(base.standardizedFileURL.path)
            }
        }
        let fallback = URL(fileURLWithPath: parentPath).resolvingSymlinksInPath().standardizedFileURL.path
        return applyMacOSPrivatePrefix(fallback)
    }

    private static func applyMacOSPrivatePrefix(_ path: String) -> String {
        for prefix in ["/var", "/tmp", "/etc"] {
            if path == prefix || path.hasPrefix(prefix + "/") {
                return "/private" + path
            }
        }
        return path
    }
}

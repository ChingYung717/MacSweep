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
    public let safetyGuard: SafetyGuard

    public init(safetyGuard: SafetyGuard = SafetyGuard()) {
        self.safetyGuard = safetyGuard
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

    /// Builds a single POSIX-quoted shell command moving privileged items to user's `~/.Trash` with unique names and `chown`.
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

        var statements: [String] = ["mkdir -p -- \(quotedTrash)"]
        for (idx, path) in validated.enumerated() {
            let base = URL(fileURLWithPath: path).lastPathComponent
            let destPath = "\(trashPath)/\(base)"
            let fallbackPath = "\(trashPath)/\(base)_\(stamp)_\(idx)"
            let qSrc = ProcessRunner.posixQuote(path)
            let qDest = ProcessRunner.posixQuote(destPath)
            let qFallback = ProcessRunner.posixQuote(fallbackPath)

            // Never follow symlink: `mv` renames the symlink itself; `chown -h` adjusts symlink/entry owner safely.
            let stmt = """
            if [ -e \(qDest) ] || [ -L \(qDest) ]; then \
            /bin/mv -- \(qSrc) \(qFallback) && /usr/sbin/chown -h \(uid):\(gid) -- \(qFallback); \
            else \
            /bin/mv -- \(qSrc) \(qDest) && /usr/sbin/chown -h \(uid):\(gid) -- \(qDest); \
            fi
            """
            statements.append(stmt)
        }
        return statements.joined(separator: " && ")
    }

    /// Builds a single POSIX-quoted `rm -rf -- ...` shell command plus optional `pkgutil --forget`.
    public func buildPermanentDeleteShellCommand(
        urls: [URL],
        packageIDsToForget: [String] = []
    ) throws -> String {
        let validated = try validatePaths(urls)
        var statements: [String] = []

        if !validated.isEmpty {
            let quotedPaths = validated.map(ProcessRunner.posixQuote).joined(separator: " ")
            statements.append("/bin/rm -rf -- \(quotedPaths)")
        }

        for pkgID in packageIDsToForget {
            let trimmed = pkgID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.lowercased().hasPrefix("com.apple.pkg."),
                  trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") }) else {
                continue
            }
            statements.append("/usr/sbin/pkgutil --forget \(ProcessRunner.posixQuote(trimmed)) || true")
        }

        return statements.joined(separator: " && ")
    }

    // MARK: - Live Execution

    /// Option A1: Delegates Trash move to Finder so macOS preserves "Put Back" ("放回原处")
    /// and prompts Touch ID / password natively when needed.
    public func moveToTrashViaFinder(urls: [URL]) throws {
        guard !urls.isEmpty else { return }
        let script = try buildFinderTrashAppleScript(urls: urls)
        let res = ProcessRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", script])
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
        let shellCmd = try buildPrivilegedTrashShellCommand(urls: urls)
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
        let escaped = ProcessRunner.appleScriptEscape(shellCommand)
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let res = ProcessRunner.run(executable: "/usr/bin/osascript", arguments: ["-e", script])
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

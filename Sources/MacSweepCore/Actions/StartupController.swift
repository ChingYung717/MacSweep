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

public struct StartupController: Sendable {
    public let privilegedExecutor: PrivilegedExecutor

    public init(privilegedExecutor: PrivilegedExecutor = PrivilegedExecutor()) {
        self.privilegedExecutor = privilegedExecutor
    }

    /// Builds shell command for enabling/disabling a launchd service (unit-testable).
    public static func buildToggleShellCommand(
        item: StartupItem,
        enable: Bool,
        uid: uid_t = getuid()
    ) throws -> (domain: String, shellCommand: String) {
        guard item.canToggle else { throw StartupControlError.notToggleable }
        let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty,
              !label.lowercased().hasPrefix("com.apple."),
              !label.contains("/"),
              !label.contains("\n") else {
            throw StartupControlError.invalidLabel
        }

        let domain = (item.scope == .systemDaemon) ? "system" : "gui/\(uid)"
        let target = "\(domain)/\(label)"
        let qTarget = ProcessRunner.posixQuote(target)
        let qDomain = ProcessRunner.posixQuote(domain)
        let qPlist = ProcessRunner.posixQuote(item.plistURL.standardizedFileURL.path)

        if enable {
            let cmd = "/bin/launchctl enable \(qTarget) && (/bin/launchctl bootstrap \(qDomain) \(qPlist) || true)"
            return (domain, cmd)
        } else {
            let cmd = "/bin/launchctl disable \(qTarget) && (/bin/launchctl bootout \(qTarget) || true)"
            return (domain, cmd)
        }
    }

    public func setEnabled(_ enable: Bool, for item: StartupItem) throws {
        let uid = getuid()
        let (_, shellCmd) = try Self.buildToggleShellCommand(item: item, enable: enable, uid: uid)

        if item.scope == .userAgent && !item.requiresAdmin {
            let res = ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", shellCmd])
            if !res.succeeded {
                throw StartupControlError.failed(res.stderr.isEmpty ? "launchctl failed" : res.stderr)
            }
        } else {
            try privilegedExecutor.runWithAdministratorPrivileges(shellCommand: shellCmd)
        }
    }
}

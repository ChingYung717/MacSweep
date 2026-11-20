import Darwin
import Foundation

public struct StartupScanner: Sendable {
    public let userLaunchAgentsURL: URL
    public let systemLaunchAgentsURL: URL
    public let systemLaunchDaemonsURL: URL
    public let appSearchRoots: [URL]
    public let safetyGuard: SafetyGuard

    public init(
        userLaunchAgentsURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"),
        systemLaunchAgentsURL: URL = URL(fileURLWithPath: "/Library/LaunchAgents"),
        systemLaunchDaemonsURL: URL = URL(fileURLWithPath: "/Library/LaunchDaemons"),
        appSearchRoots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ],
        safetyGuard: SafetyGuard = SafetyGuard()
    ) {
        self.userLaunchAgentsURL = userLaunchAgentsURL
        self.systemLaunchAgentsURL = systemLaunchAgentsURL
        self.systemLaunchDaemonsURL = systemLaunchDaemonsURL
        self.appSearchRoots = appSearchRoots
        self.safetyGuard = safetyGuard
    }

    public func scanAll(
        userDisabledMap: [String: Bool]? = nil,
        systemDisabledMap: [String: Bool]? = nil
    ) -> [StartupItem] {
        let uid = getuid()
        let userOverrides = userDisabledMap ?? Self.queryLaunchctlDisabled(domain: "gui/\(uid)")
        let sysOverrides = systemDisabledMap ?? Self.queryLaunchctlDisabled(domain: "system")

        var results: [StartupItem] = []
        results.append(contentsOf: scanLaunchDirectory(userLaunchAgentsURL, scope: .userAgent, disabledOverrides: userOverrides))
        results.append(contentsOf: scanLaunchDirectory(systemLaunchAgentsURL, scope: .systemAgent, disabledOverrides: userOverrides))
        results.append(contentsOf: scanLaunchDirectory(systemLaunchDaemonsURL, scope: .systemDaemon, disabledOverrides: sysOverrides))
        results.append(contentsOf: scanAppEmbeddedLoginItems())

        return results.sorted { lhs, rhs in
            if lhs.scope != rhs.scope {
                return scopeOrder(lhs.scope) < scopeOrder(rhs.scope)
            }
            return (lhs.associatedAppName ?? lhs.label)
                .localizedCaseInsensitiveCompare(rhs.associatedAppName ?? rhs.label) == .orderedAscending
        }
    }

    public func scanLaunchDirectory(
        _ dirURL: URL,
        scope: StartupScope,
        disabledOverrides: [String: Bool]
    ) -> [StartupItem] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [StartupItem] = []
        for url in children where url.pathExtension.lowercased() == "plist" {
            guard let item = parseLaunchPlist(at: url, scope: scope, disabledOverrides: disabledOverrides) else {
                continue
            }
            if item.label.lowercased().hasPrefix("com.apple.") {
                continue
            }
            items.append(item)
        }
        return items
    }

    public func parseLaunchPlist(
        at url: URL,
        scope: StartupScope,
        disabledOverrides: [String: Bool]
    ) -> StartupItem? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = raw as? [String: Any] else {
            return nil
        }

        let fallbackLabel = url.deletingPathExtension().lastPathComponent
        let label = (dict["Label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalLabel = (label?.isEmpty == false) ? label! : fallbackLabel

        let program = dict["Program"] as? String
        let programArgs = dict["ProgramArguments"] as? [String] ?? []
        let primaryExecutable = program ?? programArgs.first

        let plistDisabled = dict["Disabled"] as? Bool ?? false
        let isDisabled = disabledOverrides[finalLabel] ?? plistDisabled
        let runAtLoad = dict["RunAtLoad"] as? Bool ?? false
        let keepAlive: Bool
        if let kaBool = dict["KeepAlive"] as? Bool {
            keepAlive = kaBool
        } else if dict["KeepAlive"] is [String: Any] {
            keepAlive = true
        } else {
            keepAlive = false
        }

        let fm = FileManager.default
        var isOrphaned = false
        if let exe = primaryExecutable, exe.hasPrefix("/") {
            isOrphaned = !fm.fileExists(atPath: exe)
        }

        // Attempt to identify enclosing .app from program or arguments
        let allCandidates = ([program].compactMap { $0 }) + programArgs
        let associated = Self.extractEnclosingApp(from: allCandidates)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? Int64(data.count)
        let requiresAdmin = (scope != .userAgent) || safetyGuard.requiresAdmin(for: url)

        return StartupItem(
            label: finalLabel,
            plistURL: url,
            programPath: primaryExecutable,
            programArguments: programArgs,
            scope: scope,
            isEnabled: !isDisabled,
            runAtLoad: runAtLoad,
            keepAlive: keepAlive,
            isOrphanedBinary: isOrphaned,
            associatedAppPath: associated?.path,
            associatedAppName: associated?.name,
            requiresAdmin: requiresAdmin,
            canToggle: true,
            canRemove: true,
            fileSize: fileSize
        )
    }

    private func scanAppEmbeddedLoginItems() -> [StartupItem] {
        let fm = FileManager.default
        var items: [StartupItem] = []

        for root in appSearchRoots {
            guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for appURL in children where appURL.pathExtension.lowercased() == "app" {
                if safetyGuard.isSystemProtectedApp(at: appURL) { continue }
                let appName = appURL.deletingPathExtension().lastPathComponent

                // Contents/Library/LoginItems/*.app
                let loginItemsDir = appURL.appendingPathComponent("Contents/Library/LoginItems")
                if let helpers = try? fm.contentsOfDirectory(at: loginItemsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for helper in helpers where helper.pathExtension.lowercased() == "app" {
                        let helperBundle = Bundle(url: helper)
                        let helperID = helperBundle?.bundleIdentifier ?? helper.deletingPathExtension().lastPathComponent
                        items.append(StartupItem(
                            label: helperID,
                            plistURL: helper,
                            programPath: helper.path,
                            programArguments: [helper.path],
                            scope: .appLoginItem,
                            isEnabled: true,
                            runAtLoad: true,
                            keepAlive: false,
                            isOrphanedBinary: false,
                            associatedAppPath: appURL.path,
                            associatedAppName: appName,
                            requiresAdmin: false,
                            canToggle: false,
                            canRemove: false,
                            fileSize: 0
                        ))
                    }
                }
            }
        }
        return items
    }

    /// Queries `launchctl print-disabled <domain>` and returns `[label: isDisabled]`.
    public static func queryLaunchctlDisabled(domain: String) -> [String: Bool] {
        let res = ProcessRunner.run(executable: "/bin/launchctl", arguments: ["print-disabled", domain])
        guard res.succeeded else { return [:] }
        return parseLaunchctlDisabledOutput(res.stdout)
    }

    /// Pure parser for `launchctl print-disabled` output lines such as:
    /// `"com.brother.LOGINserver" => disabled` or `"com.foo.bar" => true`
    public static func parseLaunchctlDisabledOutput(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let arrowRange = line.range(of: "=>") else { continue }
            let left = line[..<arrowRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let right = line[arrowRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !left.isEmpty else { continue }
            if right == "disabled" || right == "true" {
                result[left] = true
            } else if right == "enabled" || right == "false" {
                result[left] = false
            }
        }
        return result
    }

    public static func extractEnclosingApp(from paths: [String]) -> (path: String, name: String)? {
        for raw in paths {
            guard let range = raw.range(of: ".app", options: .caseInsensitive) else { continue }
            let appPath = String(raw[..<range.upperBound])
            let appURL = URL(fileURLWithPath: appPath)
            let name = appURL.deletingPathExtension().lastPathComponent
            if !name.isEmpty {
                return (appPath, name)
            }
        }
        return nil
    }

    private func scopeOrder(_ scope: StartupScope) -> Int {
        switch scope {
        case .userAgent: return 0
        case .systemAgent: return 1
        case .systemDaemon: return 2
        case .appLoginItem: return 3
        }
    }
}

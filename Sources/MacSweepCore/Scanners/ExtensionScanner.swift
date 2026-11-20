import Foundation

public struct ExtensionScanResult: Sendable {
    public let items: [ExtensionItem]
    public let needsFullDiskAccessForBrowsers: Bool
    public let blockedBrowserNames: [String]

    public init(
        items: [ExtensionItem],
        needsFullDiskAccessForBrowsers: Bool,
        blockedBrowserNames: [String]
    ) {
        self.items = items
        self.needsFullDiskAccessForBrowsers = needsFullDiskAccessForBrowsers
        self.blockedBrowserNames = blockedBrowserNames
    }
}

public enum ExtensionControlError: Error, LocalizedError, Sendable {
    case notToggleable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notToggleable:
            return "This extension does not support direct enable/disable toggling"
        case let .failed(msg):
            return msg
        }
    }
}

public enum ExtensionController {
    /// Toggles a macOS `.appex` (Safari / App Extension) using `/usr/bin/pluginkit`.
    public static func setPluginEnabled(_ enabled: Bool, identifier: String) throws {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.lowercased().hasPrefix("com.apple.") else {
            throw ExtensionControlError.notToggleable
        }
        let mode = enabled ? "use" : "ignore"
        let res = ProcessRunner.run(executable: "/usr/bin/pluginkit", arguments: ["-e", mode, "-i", trimmed])
        if !res.succeeded {
            throw ExtensionControlError.failed(res.stderr.isEmpty ? "pluginkit failed" : res.stderr)
        }
    }
}

public struct ExtensionScanner: Sendable {
    public let homeDirectory: URL
    public let systemLibraryURL: URL
    public let safetyGuard: SafetyGuard

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemLibraryURL: URL = URL(fileURLWithPath: "/Library"),
        safetyGuard: SafetyGuard = SafetyGuard()
    ) {
        self.homeDirectory = homeDirectory
        self.systemLibraryURL = systemLibraryURL
        self.safetyGuard = safetyGuard
    }

    public func scanAll(
        includePluginkit: Bool = true
    ) -> ExtensionScanResult {
        var items: [ExtensionItem] = []
        var blockedBrowsers: [String] = []
        var needsFDA = false

        // 1. Chromium-based browsers
        let chromiumBrowsers: [(name: String, relPath: String, category: ExtensionCategory, bundleID: String)] = [
            ("Google Chrome", "Library/Application Support/Google/Chrome", .browserChrome, "com.google.Chrome"),
            ("Microsoft Edge", "Library/Application Support/Microsoft Edge", .browserEdge, "com.microsoft.edgemac"),
            ("Brave", "Library/Application Support/BraveSoftware/Brave-Browser", .browserBrave, "com.brave.Browser"),
            ("Arc", "Library/Application Support/Arc/User Data", .browserArc, "company.thebrowser.Browser"),
        ]

        let fm = FileManager.default
        for browser in chromiumBrowsers {
            let rootURL = homeDirectory.appendingPathComponent(browser.relPath)
            guard fm.fileExists(atPath: rootURL.path) else { continue }
            if !PermissionChecker.canReadDirectory(rootURL) {
                needsFDA = true
                blockedBrowsers.append(browser.name)
                continue
            }
            items.append(contentsOf: scanChromiumUserData(
                at: rootURL,
                category: browser.category,
                browserBundleID: browser.bundleID
            ))
        }

        // 2. Firefox
        let firefoxProfilesURL = homeDirectory.appendingPathComponent("Library/Application Support/Firefox/Profiles")
        if fm.fileExists(atPath: firefoxProfilesURL.path) {
            if !PermissionChecker.canReadDirectory(firefoxProfilesURL) {
                needsFDA = true
                blockedBrowsers.append("Firefox")
            } else {
                items.append(contentsOf: scanFirefoxProfiles(at: firefoxProfilesURL))
            }
        }

        // 3. Safari & macOS App Extensions via pluginkit (always works without FDA; .appex canRemove = false)
        if includePluginkit {
            items.append(contentsOf: scanPluginkitExtensions())
        }

        // 4. macOS System Plugin Directories (~/Library and /Library)
        items.append(contentsOf: scanSystemPluginDirectories())

        let sorted = items.sorted { lhs, rhs in
            if lhs.category != rhs.category {
                return categoryOrder(lhs.category) < categoryOrder(rhs.category)
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return ExtensionScanResult(
            items: sorted,
            needsFullDiskAccessForBrowsers: needsFDA,
            blockedBrowserNames: blockedBrowsers
        )
    }

    // MARK: - Chromium Scanner

    public func scanChromiumUserData(
        at userDataURL: URL,
        category: ExtensionCategory,
        browserBundleID: String
    ) -> [ExtensionItem] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: userDataURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [ExtensionItem] = []
        for profileDir in children {
            let extRoot = profileDir.appendingPathComponent("Extensions")
            guard fm.fileExists(atPath: extRoot.path),
                  let extDirs = try? fm.contentsOfDirectory(
                    at: extRoot,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            let profileName = profileDir.lastPathComponent
            for extDir in extDirs {
                let extID = extDir.lastPathComponent
                // Skip Chromium built-in temp folder
                if extID == "Temp" { continue }
                guard let parsed = Self.parseChromiumExtensionDirectory(
                    extDir,
                    extID: extID,
                    profileName: profileName,
                    category: category,
                    browserBundleID: browserBundleID
                ) else {
                    continue
                }
                results.append(parsed)
            }
        }
        return results
    }

    public static func parseChromiumExtensionDirectory(
        _ extDir: URL,
        extID: String,
        profileName: String,
        category: ExtensionCategory,
        browserBundleID: String
    ) -> ExtensionItem? {
        let fm = FileManager.default
        guard let versionDirs = try? fm.contentsOfDirectory(
            at: extDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        // Pick latest version directory containing manifest.json
        let sortedVersions = versionDirs
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }

        guard let latestDir = sortedVersions.first else { return nil }
        let manifestURL = latestDir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let rawName = (json["name"] as? String) ?? extID
        let version = (json["version"] as? String) ?? latestDir.lastPathComponent
        let defaultLocale = json["default_locale"] as? String
        let resolvedName = resolveChromiumLocalizedMessage(
            rawName,
            versionDir: latestDir,
            defaultLocale: defaultLocale
        )

        return ExtensionItem(
            name: resolvedName,
            identifier: extID,
            version: version,
            category: category,
            path: extDir,
            profileName: profileName,
            hostAppPath: nil,
            browserBundleID: browserBundleID,
            size: DirectorySizer.computeSizeSync(of: extDir),
            isEnabled: true,
            canToggle: false,
            canRemove: true,
            requiresAdmin: false,
            requiresReboot: false
        )
    }

    public static func resolveChromiumLocalizedMessage(
        _ raw: String,
        versionDir: URL,
        defaultLocale: String?
    ) -> String {
        guard raw.hasPrefix("__MSG_"), raw.hasSuffix("__"), raw.count > 8 else {
            return raw
        }
        let key = String(raw.dropFirst(6).dropLast(2))
        let localesDir = versionDir.appendingPathComponent("_locales")

        var candidates: [String] = []
        if let preferred = Locale.preferredLanguages.first?.lowercased() {
            if preferred.hasPrefix("zh") {
                candidates.append(contentsOf: ["zh_CN", "zh-CN", "zh"])
            }
        }
        if let def = defaultLocale, !def.isEmpty {
            candidates.append(def)
        }
        candidates.append(contentsOf: ["en", "en_US", "en_GB"])

        for locale in candidates {
            let msgURL = localesDir.appendingPathComponent(locale).appendingPathComponent("messages.json")
            guard let data = try? Data(contentsOf: msgURL),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            // Chromium message keys are case-insensitive
            if let entry = dict[key] as? [String: Any], let msg = entry["message"] as? String, !msg.isEmpty {
                return msg
            }
            let lowerKey = key.lowercased()
            for (k, v) in dict where k.lowercased() == lowerKey {
                if let entry = v as? [String: Any], let msg = entry["message"] as? String, !msg.isEmpty {
                    return msg
                }
            }
        }
        return raw
    }

    // MARK: - Firefox Scanner

    public func scanFirefoxProfiles(at profilesRoot: URL) -> [ExtensionItem] {
        let fm = FileManager.default
        guard let profiles = try? fm.contentsOfDirectory(
            at: profilesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [ExtensionItem] = []
        for profile in profiles {
            let extJSON = profile.appendingPathComponent("extensions.json")
            guard let data = try? Data(contentsOf: extJSON) else { continue }
            results.append(contentsOf: Self.parseFirefoxExtensionsJSON(
                data,
                profileName: profile.lastPathComponent
            ))
        }
        return results
    }

    public static func parseFirefoxExtensionsJSON(_ data: Data, profileName: String) -> [ExtensionItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let addons = root["addons"] as? [[String: Any]] else {
            return []
        }

        let fm = FileManager.default
        var items: [ExtensionItem] = []

        for addon in addons {
            let location = addon["location"] as? String ?? ""
            guard location == "app-profile" else { continue }
            let type = addon["type"] as? String ?? "extension"
            guard type == "extension" || type == "theme" else { continue }

            guard let id = addon["id"] as? String,
                  let pathStr = addon["path"] as? String,
                  !pathStr.isEmpty else {
                continue
            }

            let url = URL(fileURLWithPath: pathStr)
            let defaultLocale = addon["defaultLocale"] as? [String: Any]
            let name = (defaultLocale?["name"] as? String) ?? id
            let version = (addon["version"] as? String) ?? ""
            let active = (addon["active"] as? Bool) ?? true
            let exists = fm.fileExists(atPath: url.path)

            items.append(ExtensionItem(
                name: name,
                identifier: id,
                version: version,
                category: .browserFirefox,
                path: url,
                profileName: profileName,
                hostAppPath: nil,
                browserBundleID: "org.mozilla.firefox",
                size: exists ? DirectorySizer.computeSizeSync(of: url) : 0,
                isEnabled: active,
                canToggle: false,
                canRemove: exists,
                requiresAdmin: false,
                requiresReboot: false
            ))
        }
        return items
    }

    // MARK: - Safari & macOS App Extensions (pluginkit)

    private func scanPluginkitExtensions() -> [ExtensionItem] {
        let safariWebRes = ProcessRunner.run(executable: "/usr/bin/pluginkit", arguments: ["-m", "-v", "-p", "com.apple.Safari.web-extension"])
        let safariLegacyRes = ProcessRunner.run(executable: "/usr/bin/pluginkit", arguments: ["-m", "-v", "-p", "com.apple.Safari.extension"])
        let allRes = ProcessRunner.run(executable: "/usr/bin/pluginkit", arguments: ["-m", "-v"])

        var safariIDs = Set<String>()
        for entry in Self.parsePluginkitOutput(safariWebRes.stdout) + Self.parsePluginkitOutput(safariLegacyRes.stdout) {
            safariIDs.insert(entry.identifier)
        }

        let allEntries = Self.parsePluginkitOutput(allRes.stdout)
        var results: [ExtensionItem] = []
        var seen = Set<String>()

        for entry in allEntries {
            guard !seen.contains(entry.path) else { continue }
            seen.insert(entry.path)

            let url = URL(fileURLWithPath: entry.path)
            let isSafari = safariIDs.contains(entry.identifier)
            let hostApp = StartupScanner.extractEnclosingApp(from: [entry.path]).map { URL(fileURLWithPath: $0.path) }

            let bundle = Bundle(url: url)
            let displayName = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
                ?? url.deletingPathExtension().lastPathComponent

            results.append(ExtensionItem(
                name: displayName,
                identifier: entry.identifier,
                version: entry.version,
                category: isSafari ? .browserSafari : .appExtension,
                path: url,
                profileName: hostApp?.deletingPathExtension().lastPathComponent,
                hostAppPath: hostApp,
                browserBundleID: isSafari ? "com.apple.Safari" : nil,
                size: DirectorySizer.computeSizeSync(of: url),
                isEnabled: entry.isEnabled,
                canToggle: true,
                canRemove: false, // Embedded .appex MUST NOT be individually deleted (breaks host app signature)
                requiresAdmin: false,
                requiresReboot: false
            ))
        }
        return results
    }

    public struct PluginkitEntry: Sendable, Equatable {
        public let identifier: String
        public let version: String
        public let path: String
        public let isEnabled: Bool
    }

    /// Parses `pluginkit -m -v` lines, excluding `/System/` Apple system extensions.
    public static func parsePluginkitOutput(_ output: String) -> [PluginkitEntry] {
        var entries: [PluginkitEntry] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            // Lines with extensions have tab-separated columns: `<flags><id>(<ver>)\t<uuid>\t<date>\t<path>`
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 4 else { continue }

            let head = String(columns[0])
            let path = String(columns[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"),
                  !path.hasPrefix("/System/"),
                  !path.hasPrefix("/Library/Apple/") else {
                continue
            }

            let trimmedHead = head.trimmingCharacters(in: .whitespaces)
            var isEnabled = true
            var idAndVer = trimmedHead
            if trimmedHead.hasPrefix("+") {
                isEnabled = true
                idAndVer = String(trimmedHead.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if trimmedHead.hasPrefix("-") {
                isEnabled = false
                idAndVer = String(trimmedHead.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if trimmedHead.hasPrefix("!") {
                isEnabled = false
                idAndVer = String(trimmedHead.dropFirst()).trimmingCharacters(in: .whitespaces)
            }

            var identifier = idAndVer
            var version = ""
            if let openParen = idAndVer.lastIndex(of: "("), idAndVer.hasSuffix(")") {
                identifier = String(idAndVer[..<openParen])
                let rawVer = String(idAndVer[idAndVer.index(after: openParen)..<idAndVer.index(before: idAndVer.endIndex)])
                if rawVer != "(null)" && rawVer != "null" {
                    version = rawVer
                }
            }

            guard !identifier.isEmpty, !identifier.lowercased().hasPrefix("com.apple.") else { continue }
            entries.append(PluginkitEntry(
                identifier: identifier,
                version: version,
                path: path,
                isEnabled: isEnabled
            ))
        }
        return entries
    }

    // MARK: - System Plugin Directories

    public func scanSystemPluginDirectories() -> [ExtensionItem] {
        let userLib = homeDirectory.appendingPathComponent("Library")
        let specs: [(dir: URL, category: ExtensionCategory, isHAL: Bool)] = [
            (userLib.appendingPathComponent("PreferencePanes"), .preferencePane, false),
            (systemLibraryURL.appendingPathComponent("PreferencePanes"), .preferencePane, false),
            (userLib.appendingPathComponent("QuickLook"), .quickLook, false),
            (systemLibraryURL.appendingPathComponent("QuickLook"), .quickLook, false),
            (userLib.appendingPathComponent("Spotlight"), .spotlight, false),
            (systemLibraryURL.appendingPathComponent("Spotlight"), .spotlight, false),
            (userLib.appendingPathComponent("Screen Savers"), .screenSaver, false),
            (systemLibraryURL.appendingPathComponent("Screen Savers"), .screenSaver, false),
            (userLib.appendingPathComponent("Internet Plug-Ins"), .internetPlugin, false),
            (systemLibraryURL.appendingPathComponent("Internet Plug-Ins"), .internetPlugin, false),
            (userLib.appendingPathComponent("Audio/Plug-Ins/Components"), .audioPlugin, false),
            (systemLibraryURL.appendingPathComponent("Audio/Plug-Ins/Components"), .audioPlugin, false),
            (userLib.appendingPathComponent("Audio/Plug-Ins/VST"), .audioPlugin, false),
            (systemLibraryURL.appendingPathComponent("Audio/Plug-Ins/VST"), .audioPlugin, false),
            (userLib.appendingPathComponent("Audio/Plug-Ins/VST3"), .audioPlugin, false),
            (systemLibraryURL.appendingPathComponent("Audio/Plug-Ins/VST3"), .audioPlugin, false),
            (userLib.appendingPathComponent("Audio/Plug-Ins/HAL"), .audioPlugin, true),
            (systemLibraryURL.appendingPathComponent("Audio/Plug-Ins/HAL"), .audioPlugin, true),
        ]

        let fm = FileManager.default
        var results: [ExtensionItem] = []

        for spec in specs {
            guard let children = try? fm.contentsOfDirectory(
                at: spec.dir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for itemURL in children {
                guard safetyGuard.validateForRemoval(itemURL).isAllowed else { continue }
                let bundle = Bundle(url: itemURL)
                let bid = bundle?.bundleIdentifier ?? itemURL.deletingPathExtension().lastPathComponent
                if bid.lowercased().hasPrefix("com.apple.") { continue }

                let name = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                    ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
                    ?? itemURL.deletingPathExtension().lastPathComponent
                let version = (bundle?.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""

                results.append(ExtensionItem(
                    name: name,
                    identifier: bid,
                    version: version,
                    category: spec.category,
                    path: itemURL,
                    profileName: spec.isHAL ? "HAL Audio Driver" : nil,
                    hostAppPath: nil,
                    browserBundleID: nil,
                    size: DirectorySizer.computeSizeSync(of: itemURL),
                    isEnabled: true,
                    canToggle: false,
                    canRemove: true,
                    requiresAdmin: safetyGuard.requiresAdmin(for: itemURL),
                    requiresReboot: spec.isHAL
                ))
            }
        }
        return results
    }

    private func categoryOrder(_ cat: ExtensionCategory) -> Int {
        switch cat {
        case .browserSafari: return 0
        case .browserChrome: return 1
        case .browserEdge: return 2
        case .browserBrave: return 3
        case .browserArc: return 4
        case .browserFirefox: return 5
        case .appExtension: return 6
        case .preferencePane: return 7
        case .quickLook: return 8
        case .spotlight: return 9
        case .screenSaver: return 10
        case .internetPlugin: return 11
        case .audioPlugin: return 12
        }
    }
}

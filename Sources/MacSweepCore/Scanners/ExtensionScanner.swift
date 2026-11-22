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

    /// Scans all browser & macOS extensions, computing directory sizes concurrently via `sizer`.
    public func scanAllAsync(
        sizer: DirectorySizer = DirectorySizer(),
        includePluginkit: Bool = true
    ) async -> ExtensionScanResult {
        var result = scanMetadataOnly(includePluginkit: includePluginkit)
        let urls = result.items.filter(\.pathExists).map(\.path)
        let sizeMap = await sizer.sizes(of: urls, maxConcurrency: 6)
        var sizedItems = result.items
        for i in sizedItems.indices {
            if let sz = sizeMap[sizedItems[i].path.standardizedFileURL.path] {
                sizedItems[i].size = sz
            }
        }
        result = ExtensionScanResult(
            items: sizedItems,
            needsFullDiskAccessForBrowsers: result.needsFullDiskAccessForBrowsers,
            blockedBrowserNames: result.blockedBrowserNames
        )
        return result
    }

    /// Synchronous convenience entry point (computes sizes sequentially; used by CLI audits/tests).
    public func scanAll(includePluginkit: Bool = true) -> ExtensionScanResult {
        let meta = scanMetadataOnly(includePluginkit: includePluginkit)
        let sized = meta.items.map { item -> ExtensionItem in
            var copy = item
            copy.size = item.pathExists ? DirectorySizer.computeSizeSync(of: item.path) : 0
            return copy
        }
        return ExtensionScanResult(
            items: sized,
            needsFullDiskAccessForBrowsers: meta.needsFullDiskAccessForBrowsers,
            blockedBrowserNames: meta.blockedBrowserNames
        )
    }

    private func scanMetadataOnly(includePluginkit: Bool) -> ExtensionScanResult {
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
                browserBundleID: browser.bundleID,
                computeSize: false
            ))
        }

        // 2. Firefox (supports `profiles.ini` custom paths + fallback to `Profiles/`)
        let firefoxBaseURL = homeDirectory.appendingPathComponent("Library/Application Support/Firefox")
        if fm.fileExists(atPath: firefoxBaseURL.path) {
            if !PermissionChecker.canReadDirectory(firefoxBaseURL) {
                needsFDA = true
                blockedBrowsers.append("Firefox")
            } else {
                items.append(contentsOf: scanFirefoxBase(at: firefoxBaseURL, computeSize: false))
            }
        }

        // 3. Safari & macOS App Extensions via pluginkit
        if includePluginkit {
            items.append(contentsOf: scanPluginkitExtensions(computeSize: false))
        }

        // 4. macOS System Plugin Directories (~/Library and /Library)
        items.append(contentsOf: scanSystemPluginDirectories(computeSize: false))

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
        browserBundleID: String,
        computeSize: Bool = true
    ) -> [ExtensionItem] {
        let fm = FileManager.default
        let resolvedUserData = userDataURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard let children = try? fm.contentsOfDirectory(
            at: userDataURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [ExtensionItem] = []
        for profileDir in children {
            let profileVals = try? profileDir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard profileVals?.isDirectory == true, profileVals?.isSymbolicLink != true else { continue }

            let extRoot = profileDir.appendingPathComponent("Extensions")
            let extRootVals = try? extRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard extRootVals?.isDirectory == true, extRootVals?.isSymbolicLink != true,
                  let extDirs = try? fm.contentsOfDirectory(
                    at: extRoot,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }

            let profileName = profileDir.lastPathComponent
            for extDir in extDirs {
                let extVals = try? extDir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard extVals?.isDirectory == true, extVals?.isSymbolicLink != true else { continue }
                let resolvedExt = extDir.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolvedExt.hasPrefix(resolvedUserData + "/"),
                      safetyGuard.validateForRemoval(extDir).isAllowed else {
                    continue
                }
                let extID = extDir.lastPathComponent
                if extID == "Temp" { continue }
                guard let parsed = Self.parseChromiumExtensionDirectory(
                    extDir,
                    extID: extID,
                    profileName: profileName,
                    category: category,
                    browserBundleID: browserBundleID,
                    computeSize: computeSize
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
        browserBundleID: String,
        computeSize: Bool = true
    ) -> ExtensionItem? {
        let fm = FileManager.default
        guard let versionDirs = try? fm.contentsOfDirectory(
            at: extDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

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
            hostAppExists: false,
            pathExists: true,
            browserBundleID: browserBundleID,
            size: computeSize ? DirectorySizer.computeSizeSync(of: extDir) : 0,
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
        if let def = defaultLocale,
           !def.isEmpty,
           def.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) {
            candidates.append(def)
        }
        candidates.append(contentsOf: ["en", "en_US", "en_GB"])

        for locale in candidates {
            let msgURL = localesDir.appendingPathComponent(locale).appendingPathComponent("messages.json")
            guard let data = try? Data(contentsOf: msgURL),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
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

    // MARK: - Firefox Scanner (profiles.ini + Profiles/ fallback)

    public func scanFirefoxBase(at firefoxBaseURL: URL, computeSize: Bool = true) -> [ExtensionItem] {
        let fm = FileManager.default
        var profileDirs: [URL] = []
        var seenPaths = Set<String>()

        let iniURL = firefoxBaseURL.appendingPathComponent("profiles.ini")
        if let iniText = try? String(contentsOf: iniURL, encoding: .utf8) {
            for dir in Self.parseFirefoxProfilesINI(iniText, firefoxBaseURL: firefoxBaseURL) {
                let p = dir.standardizedFileURL.path
                if fm.fileExists(atPath: p), seenPaths.insert(p).inserted {
                    profileDirs.append(dir)
                }
            }
        }

        // Also include any folders inside `Profiles/` not listed in `profiles.ini`
        let profilesRoot = firefoxBaseURL.appendingPathComponent("Profiles")
        if let dirs = try? fm.contentsOfDirectory(
            at: profilesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for dir in dirs {
                let p = dir.standardizedFileURL.path
                if seenPaths.insert(p).inserted {
                    profileDirs.append(dir)
                }
            }
        }

        var results: [ExtensionItem] = []
        for profile in profileDirs {
            let profVals = try? profile.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard profVals?.isDirectory == true, profVals?.isSymbolicLink != true else { continue }
            let extJSON = profile.appendingPathComponent("extensions.json")
            guard let data = try? Data(contentsOf: extJSON) else { continue }
            results.append(contentsOf: Self.parseFirefoxExtensionsJSON(
                data,
                profileName: profile.lastPathComponent,
                computeSize: computeSize,
                profileDirectory: profile,
                safetyGuard: safetyGuard
            ))
        }
        return results
    }

    /// Parses Mozilla `profiles.ini` sections (`[Profile*]`) into resolved profile directory URLs.
    /// Relative profile paths (`IsRelative=1`) must stay contained within `firefoxBaseURL`.
    public static func parseFirefoxProfilesINI(_ content: String, firefoxBaseURL: URL) -> [URL] {
        var results: [URL] = []
        var inProfileSection = false
        var currentPath: String?
        var currentIsRelative = true
        let basePath = firefoxBaseURL.standardizedFileURL.path

        func flushSection() {
            guard inProfileSection, let path = currentPath, !path.isEmpty, !path.contains("\0") else { return }
            if currentIsRelative {
                let candidate = firefoxBaseURL.appendingPathComponent(path).standardizedFileURL
                guard candidate.path.hasPrefix(basePath + "/") else { return }
                results.append(candidate)
            } else {
                guard path.hasPrefix("/") else { return }
                results.append(URL(fileURLWithPath: path).standardizedFileURL)
            }
        }

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                flushSection()
                let header = String(line.dropFirst().dropLast()).lowercased()
                inProfileSection = header.hasPrefix("profile")
                currentPath = nil
                currentIsRelative = true
                continue
            }
            guard inProfileSection, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "path": currentPath = val
            case "isrelative": currentIsRelative = (val != "0")
            default: break
            }
        }
        flushSection()
        return results
    }

    public static func parseFirefoxExtensionsJSON(
        _ data: Data,
        profileName: String,
        computeSize: Bool = true,
        profileDirectory: URL? = nil,
        safetyGuard: SafetyGuard = SafetyGuard()
    ) -> [ExtensionItem] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let addons = root["addons"] as? [[String: Any]] else {
            return []
        }

        let fm = FileManager.default
        let expectedExtensionsRaw = profileDirectory?.appendingPathComponent("extensions").standardizedFileURL.path
        let expectedExtensionsResolved = profileDirectory?.appendingPathComponent("extensions").resolvingSymlinksInPath().standardizedFileURL.path
        var items: [ExtensionItem] = []

        for addon in addons {
            let location = addon["location"] as? String ?? ""
            guard location == "app-profile" else { continue }
            let type = addon["type"] as? String ?? "extension"
            guard type == "extension" || type == "theme" else { continue }

            guard let id = addon["id"] as? String,
                  let pathStr = addon["path"] as? String,
                  !pathStr.isEmpty,
                  !pathStr.contains("\0"),
                  pathStr.hasPrefix("/") else {
                continue
            }

            let url = URL(fileURLWithPath: pathStr).standardizedFileURL
            if let expRaw = expectedExtensionsRaw, let expRes = expectedExtensionsResolved {
                let rawPath = url.path
                let resPath = url.resolvingSymlinksInPath().standardizedFileURL.path
                let rawInside = rawPath.hasPrefix(expRaw + "/") || rawPath.hasPrefix(expRes + "/")
                let resInside = resPath.hasPrefix(expRaw + "/") || resPath.hasPrefix(expRes + "/")
                guard rawInside && resInside else {
                    continue
                }
            }
            guard safetyGuard.validateForRemoval(url).isAllowed else {
                continue
            }

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
                hostAppExists: false,
                pathExists: exists,
                browserBundleID: "org.mozilla.firefox",
                size: (computeSize && exists) ? DirectorySizer.computeSizeSync(of: url) : 0,
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

    private func scanPluginkitExtensions(computeSize: Bool) -> [ExtensionItem] {
        let safariWebRes = ProcessRunner.run(executable: "/usr/bin/pluginkit", arguments: ["-m", "-v", "-p", "com.apple.Safari.web-extension"])
        let safariLegacyRes = ProcessRunner.run(executable: "/usr/bin/pluginkit", arguments: ["-m", "-v", "-p", "com.apple.Safari.extension"])
        let allRes = ProcessRunner.run(executable: "/usr/bin/pluginkit", arguments: ["-m", "-v"])

        var safariIDs = Set<String>()
        for entry in Self.parsePluginkitOutput(safariWebRes.stdout) + Self.parsePluginkitOutput(safariLegacyRes.stdout) {
            safariIDs.insert(entry.identifier)
        }

        let allEntries = Self.parsePluginkitOutput(allRes.stdout)
        let fm = FileManager.default
        var results: [ExtensionItem] = []
        var seen = Set<String>()

        for entry in allEntries {
            guard !seen.contains(entry.path) else { continue }
            seen.insert(entry.path)

            let url = URL(fileURLWithPath: entry.path)
            let isSafari = safariIDs.contains(entry.identifier)
            let hostApp = StartupScanner.extractEnclosingApp(from: [entry.path]).map { URL(fileURLWithPath: $0.path) }
            let hostExists = hostApp.map { fm.fileExists(atPath: $0.path) } ?? false
            let pathExists = fm.fileExists(atPath: url.path)

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
                hostAppExists: hostExists,
                pathExists: pathExists,
                browserBundleID: isSafari ? "com.apple.Safari" : nil,
                size: (computeSize && pathExists) ? DirectorySizer.computeSizeSync(of: url) : 0,
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
    ///
    /// Documented `pluginkit` status flags (`man pluginkit`):
    /// - `+` : explicitly enabled (`isEnabled = true`)
    /// - `-` : explicitly disabled (`isEnabled = false`)
    /// - `!` : has sole-decision / error state (`isEnabled = false`)
    /// - `=` : superseded by newer version (`isEnabled = false`)
    /// - `?` : unknown election state (`isEnabled = false`)
    /// - blank: default (not opted-in by user -> `isEnabled = false`)
    public static func parsePluginkitOutput(_ output: String) -> [PluginkitEntry] {
        let statusChars: Set<Character> = ["+", "-", "!", "=", "?"]
        var entries: [PluginkitEntry] = []

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 4 else { continue }

            let head = String(columns[0])
            let path = String(columns[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"),
                  !path.hasPrefix("/System/"),
                  !path.hasPrefix("/Library/Apple/") else {
                continue
            }

            var idAndVer = head.trimmingCharacters(in: .whitespaces)
            var isEnabled = false

            // Strip any leading documented status markers (`+`, `-`, `!`, `=`, `?`)
            while let first = idAndVer.first, statusChars.contains(first) {
                if first == "+" {
                    isEnabled = true
                }
                idAndVer = String(idAndVer.dropFirst()).trimmingCharacters(in: .whitespaces)
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

    public func scanSystemPluginDirectories(computeSize: Bool = true) -> [ExtensionItem] {
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
                    hostAppExists: false,
                    pathExists: true,
                    browserBundleID: nil,
                    size: computeSize ? DirectorySizer.computeSizeSync(of: itemURL) : 0,
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

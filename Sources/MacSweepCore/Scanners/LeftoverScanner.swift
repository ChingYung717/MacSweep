import Darwin
import Foundation

public struct InstalledAppInventory: Sendable {
    public let bundleIDs: Set<String>
    public let baseBundlePrefixes: Set<String>
    public let appNames: Set<String>
    public let compactAppNames: Set<String>
    /// 2-part reverse-DNS vendor prefixes (e.g. `com.baidu`, `com.tencent`) of installed apps / live services.
    public let vendorPrefixes: Set<String>
    /// Tightened compact names from top-level third-party apps (excluding generic OS/UI words & plugins)
    /// used for containment checks such as `com.baidu.baidunetdisk-mac` ⊃ `baidunetdisk`.
    public let containmentNames: Set<String>

    public init(
        bundleIDs: Set<String>,
        baseBundlePrefixes: Set<String>,
        appNames: Set<String>,
        compactAppNames: Set<String>,
        vendorPrefixes: Set<String> = [],
        containmentNames: Set<String> = []
    ) {
        self.bundleIDs = bundleIDs
        self.baseBundlePrefixes = baseBundlePrefixes
        self.appNames = appNames
        self.compactAppNames = compactAppNames
        self.vendorPrefixes = vendorPrefixes
        self.containmentNames = containmentNames
    }

    public static func compact(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    /// Strips a trailing `_<UUID>`, `-<UUID>`, or `.<UUID>` suffix
    /// (e.g. `SampleApp_11111111-2222-3333-4444-555555555555`, ByHost `com.foo.bar.<UUID>`, or bare 37-char `_<UUID>`).
    public static func stripUUIDSuffix(_ name: String) -> String {
        guard name.count >= 37 else { return name }
        let suffix = String(name.suffix(36))
        let sep = name[name.index(name.endIndex, offsetBy: -37)]
        if (sep == "_" || sep == "-" || sep == "."), UUID(uuidString: suffix) != nil {
            return String(name.dropLast(37))
        }
        return name
    }

    /// Reads localized `CFBundleDisplayName` / `CFBundleName` from `*.lproj/InfoPlist.strings`
    /// (e.g. aDrive.app → 阿里云盘 lives only in `zh_CN.lproj`).
    public static func localizedBundleNames(at appURL: URL) -> [String] {
        let fm = FileManager.default
        let resources = appURL.appendingPathComponent("Contents/Resources")
        guard let lprojs = try? fm.contentsOfDirectory(atPath: resources.path) else { return [] }
        var names: [String] = []
        for lproj in lprojs where lproj.hasSuffix(".lproj") {
            let lower = lproj.lowercased()
            guard lower.hasPrefix("zh") || lower.hasPrefix("en") || lower == "base.lproj" else { continue }
            let stringsURL = resources.appendingPathComponent(lproj).appendingPathComponent("InfoPlist.strings")
            guard let data = try? Data(contentsOf: stringsURL),
                  let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
                continue
            }
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = (dict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    names.append(value)
                }
            }
        }
        return names
    }

    public static func build(
        searchRoots: [URL]? = nil,
        libraryIndex: LibraryIndex? = nil
    ) -> InstalledAppInventory {
        let roots = searchRoots ?? [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
        ]

        var bundleIDs = Set<String>()
        var basePrefixes = Set<String>()
        var vendors = Set<String>()
        var names = Set<String>()
        var compactNames = Set<String>()
        var containment = Set<String>()
        let fm = FileManager.default

        func recordBundleID(_ bid: String) {
            let lower = bid.lowercased()
            guard !lower.isEmpty else { return }
            bundleIDs.insert(lower)
            let parts = lower.split(separator: ".")
            if parts.count >= 3 {
                basePrefixes.insert(parts.prefix(3).joined(separator: "."))
            }
            if parts.count >= 2 {
                let p2 = parts.prefix(2).joined(separator: ".")
                basePrefixes.insert(p2)
                vendors.insert(p2)
            }
        }

        func recordName(_ raw: String, allowContainment: Bool) {
            let val = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !val.isEmpty,
                  !ServiceFileMatcher.genericExecutableNames.contains(val) else { return }
            names.insert(val)
            compactNames.insert(val.replacingOccurrences(of: " ", with: ""))
            guard allowContainment else { return }
            let c = compact(val)
            let hasNonASCII = c.unicodeScalars.contains { !$0.isASCII }
            let minLen = hasNonASCII ? 4 : 6
            if c.count >= minLen,
               !ServiceFileMatcher.genericStopWords.contains(val),
               !ServiceFileMatcher.genericStopWords.contains(c),
               !SafetyGuard.sharedVendorFolderNames.contains(c),
               !SafetyGuard.leftoverSafeIgnoreNames.contains(c) {
                containment.insert(c)
            }
        }

        func recordBundle(at url: URL, includeLocalized: Bool, isSystemRoot: Bool, bundleIDOnly: Bool = false) {
            let allowContainment = !isSystemRoot && !bundleIDOnly
            if !bundleIDOnly {
                recordName(url.deletingPathExtension().lastPathComponent, allowContainment: allowContainment)
            }
            if let bundle = Bundle(url: url), let info = bundle.infoDictionary {
                if let bid = info["CFBundleIdentifier"] as? String {
                    recordBundleID(bid)
                }
                if !bundleIDOnly {
                    for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"] {
                        if let val = info[key] as? String {
                            recordName(val, allowContainment: allowContainment)
                        }
                    }
                }
            }
            if includeLocalized && !bundleIDOnly {
                for localized in localizedBundleNames(at: url) {
                    recordName(localized, allowContainment: allowContainment)
                }
                let fsDisplay = AppScanner.strippingAppExtension(fm.displayName(atPath: url.path))
                recordName(fsDisplay, allowContainment: allowContainment)
            }
        }

        func scanDir(_ dir: URL, depth: Int, isSystemRoot: Bool) {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles]
            ) else {
                return
            }

            for item in items {
                if item.pathExtension.lowercased() == "app" {
                    recordBundle(at: item, includeLocalized: true, isSystemRoot: isSystemRoot)
                    // Embedded plugins/helpers record ONLY their CFBundleIdentifier (never loose names like
                    // "Share Extension" or "QuickLookPreview" that would pollute `containmentNames`).
                    for subDir in ["Contents/Library/LoginItems", "Contents/PlugIns", "Contents/XPCServices", "Contents/Applications"] {
                        let nested = item.appendingPathComponent(subDir)
                        if let nestedItems = try? fm.contentsOfDirectory(at: nested, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                            for nestedItem in nestedItems {
                                recordBundle(at: nestedItem, includeLocalized: false, isSystemRoot: isSystemRoot, bundleIDOnly: true)
                            }
                        }
                    }
                    continue
                }

                if depth == 0 {
                    let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                    if vals?.isDirectory == true && vals?.isPackage != true {
                        scanDir(item, depth: 1, isSystemRoot: isSystemRoot)
                    }
                }
            }
        }

        for root in roots {
            let isSys = root.standardizedFileURL.path.hasPrefix("/System/")
            scanDir(root, depth: 0, isSystemRoot: isSys)
        }

        // Also record active (non-orphaned) LaunchAgents/LaunchDaemons so live system updaters/drivers
        // (e.g. Microsoft AutoUpdate, printer/hardware daemons) aren't falsely flagged as leftovers.
        if let index = libraryIndex {
            for entry in index.entries where entry.category == .launchAgents || entry.category == .launchDaemons {
                guard let firstProg = entry.launchProgramPaths.first,
                      firstProg.hasPrefix("/"),
                      !StartupScanner.isExecutableDefinitelyMissing(atPath: firstProg) else {
                    continue
                }
                if let label = entry.launchLabel {
                    recordBundleID(label)
                }
                if let enclosing = StartupScanner.extractEnclosingApp(from: entry.launchProgramPaths) {
                    recordBundle(
                        at: URL(fileURLWithPath: enclosing.path),
                        includeLocalized: false,
                        isSystemRoot: enclosing.path.hasPrefix("/System/"),
                        bundleIDOnly: false
                    )
                }
            }
        }

        return InstalledAppInventory(
            bundleIDs: bundleIDs,
            baseBundlePrefixes: basePrefixes,
            appNames: names,
            compactAppNames: compactNames,
            vendorPrefixes: vendors,
            containmentNames: containment
        )
    }

    /// True if a reverse-DNS identifier's product part contains an installed third-party app name,
    /// e.g. `com.baidu.baidunetdisk-mac` while `BaiduNetdisk.app` (`com.baidu.netdisk`) is installed.
    public func productPartContainsInstalledName(_ reverseDNS: String) -> Bool {
        let parts = reverseDNS.lowercased().split(separator: ".")
        guard parts.count >= 3 else { return false }
        let product = Self.compact(parts.dropFirst(2).joined())
        guard product.count >= 5 else { return false }
        return containmentNames.contains { product.contains($0) }
    }

    /// True if a plain (non reverse-DNS) folder/file name contains an installed third-party app name,
    /// e.g. CrashReporter `BaiduNetdisk_mac` while `BaiduNetdisk.app` is installed.
    public func plainNameContainsInstalledName(_ name: String) -> Bool {
        let c = Self.compact(name)
        guard c.count >= 5 else { return false }
        return containmentNames.contains { c.contains($0) }
    }

    /// True if any installed app / live service shares the 2-part vendor prefix (e.g. `com.tencent`).
    public func hasInstalledVendor(_ reverseDNS: String) -> Bool {
        let parts = reverseDNS.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return false }
        return vendorPrefixes.contains(parts.prefix(2).joined(separator: "."))
    }

    public func matchesEntry(stem: String, fullName: String, launchLabel: String?) -> Bool {
        let lowerStem = stem.lowercased()
        let lowerFull = fullName.lowercased()
        let compactStem = lowerStem.replacingOccurrences(of: " ", with: "")

        if appNames.contains(lowerStem) || appNames.contains(lowerFull) || compactAppNames.contains(compactStem) {
            return true
        }

        let idCandidates = [lowerStem, lowerFull, launchLabel?.lowercased()].compactMap { $0 }
        for candidate in idCandidates {
            let stripped = Self.stripContainerPrefixes(candidate)
            if bundleIDs.contains(stripped) {
                return true
            }
            for bid in bundleIDs {
                if ServiceFileMatcher.isBoundaryPrefixMatch(candidate: stripped, prefix: bid)
                    || ServiceFileMatcher.isBoundaryPrefixMatch(candidate: bid, prefix: stripped) {
                    return true
                }
            }
            let parts = stripped.split(separator: ".")
            if parts.count >= 3 {
                let p3 = parts.prefix(3).joined(separator: ".")
                if baseBundlePrefixes.contains(p3) {
                    return true
                }
            }
        }
        return false
    }

    public static func stripContainerPrefixes(_ raw: String) -> String {
        var value = raw
        if value.hasPrefix("group.") {
            value = String(value.dropFirst("group.".count))
        }
        if let dot = value.firstIndex(of: ".") {
            let prefix = value[..<dot]
            if prefix.count == 10, prefix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                value = String(value[value.index(after: dot)...])
                if value.hasPrefix("group.") {
                    value = String(value.dropFirst("group.".count))
                }
            }
        }
        return value
    }
}

public struct LeftoverScanner: Sendable {
    private static let reverseDNSTLDs: Set<String> = [
        "com", "org", "net", "io", "app", "co", "dev", "me", "cn", "jp",
        "uk", "de", "fr", "ca", "au", "tv", "ai", "sh", "cc", "pro", "edu", "gov",
    ]

    public let safetyGuard: SafetyGuard
    public let ignoredLeftoverIDs: Set<String>

    public init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        ignoredLeftoverIDs: [String] = []
    ) {
        self.safetyGuard = safetyGuard
        self.ignoredLeftoverIDs = Set(ignoredLeftoverIDs.map { $0.lowercased() })
    }

    public func scan(
        index: LibraryIndex,
        inventory: InstalledAppInventory
    ) -> [LeftoverGroup] {
        var groupedFiles: [String: (displayName: String, bundleID: String?, confidence: LeftoverConfidence, files: [ServiceFile])] = [:]

        for entry in index.entries {
            guard entry.isRemovable else { continue }

            let stem = InstalledAppInventory.stripUUIDSuffix(entry.stem)
            let strippedID = InstalledAppInventory.stripContainerPrefixes(stem.lowercased())

            // Skip Apple system (incl. parentVendorName == "apple"), CUPS, OpenJDK, CLI/dev tools, and user-ignored leftovers
            if safetyGuard.isProtectedFromLeftoverScan(
                name: stem,
                bundleID: entry.launchLabel ?? strippedID,
                parentVendorName: entry.parentVendorName
            ) {
                continue
            }
            if ignoredLeftoverIDs.contains(strippedID) || ignoredLeftoverIDs.contains(entry.normalizedName) {
                continue
            }

            // Skip individual diagnostic/crash log files to prevent noise
            if entry.category == .logs {
                let ext = entry.url.pathExtension.lowercased()
                if ["ips", "crash", "diag", "spin", "hang", "log"].contains(ext) {
                    continue
                }
            }

            // LaunchAgents & LaunchDaemons: ONLY consider leftover if the target executable is confirmed missing!
            if entry.category == .launchAgents || entry.category == .launchDaemons {
                guard let firstProg = entry.launchProgramPaths.first, firstProg.hasPrefix("/") else {
                    continue
                }
                if !StartupScanner.isExecutableDefinitelyMissing(atPath: firstProg) {
                    continue
                }
            }

            // Check if belongs to any currently installed app
            if inventory.matchesEntry(stem: stem, fullName: entry.name, launchLabel: entry.launchLabel) {
                continue
            }

            let isReverseDNS = Self.looksLikeReverseDNSBundleID(strippedID)
            let isOrphanedLaunch = (entry.category == .launchAgents || entry.category == .launchDaemons)

            if isReverseDNS && !isOrphanedLaunch && inventory.productPartContainsInstalledName(strippedID) {
                continue
            }

            var confidence: LeftoverConfidence
            if isOrphanedLaunch {
                confidence = .high
            } else if isReverseDNS {
                switch entry.category {
                case .containers, .groupContainers, .savedState, .preferences, .caches, .webData, .applicationSupport:
                    confidence = .high
                default:
                    confidence = .medium
                }
            } else {
                guard entry.category == .applicationSupport || entry.category == .caches || entry.category == .logs else {
                    continue
                }
                guard stem.count >= 4,
                      !stem.hasPrefix("@"),
                      !stem.hasPrefix("_"),
                      stem.lowercased() != "(null)",
                      UUID(uuidString: stem) == nil else {
                    continue
                }
                if inventory.plainNameContainsInstalledName(stem) {
                    continue
                }
                if Self.isSystemExecutableName(stem) {
                    continue
                }
                confidence = .medium
            }

            // Never pre-select (default-check) items that are risky to remove blindly:
            //  - system-wide `/Library/...` entries (shared by all users, require admin) [F5].
            //    This intentionally includes orphaned system LaunchDaemons [N4]: they stay unchecked in
            //    Leftovers (no surprise root prompts) and have a dedicated "Broken" filter in Startup Programs.
            //  - data of a vendor that still has installed apps / live services.
            if confidence == .high {
                if entry.isSystemScope {
                    confidence = .medium
                } else if isReverseDNS && inventory.hasInstalledVendor(strippedID) {
                    confidence = .medium
                }
            }

            let groupKey = Self.deriveGroupKey(
                strippedID: strippedID,
                stem: stem,
                isReverseDNS: isReverseDNS,
                launchLabel: entry.launchLabel
            )
            if ignoredLeftoverIDs.contains(groupKey) {
                continue
            }

            let displayName = Self.deriveDisplayName(fromGroupKey: groupKey, fallbackStem: stem)
            let serviceFile = ServiceFile(
                url: entry.url,
                category: entry.category,
                size: nil,
                isSelected: confidence == .high && !entry.isSystemScope,
                requiresAdmin: entry.requiresAdmin,
                requiresReboot: entry.url.path.contains("/Audio/Plug-Ins/HAL/"),
                isSystemScope: entry.isSystemScope,
                confidence: confidence,
                matchReason: confidence == .high ? "Orphaned app identifier" : "Unmatched directory (review)"
            )

            if var existing = groupedFiles[groupKey] {
                existing.files.append(serviceFile)
                if confidence == .high {
                    existing.confidence = .high
                }
                groupedFiles[groupKey] = existing
            } else {
                groupedFiles[groupKey] = (
                    displayName: displayName,
                    bundleID: isReverseDNS ? groupKey : entry.launchLabel,
                    confidence: confidence,
                    files: [serviceFile]
                )
            }
        }

        let groups: [LeftoverGroup] = groupedFiles.map { key, val in
            let sortedFiles = val.files.sorted {
                if $0.category.sortOrder != $1.category.sortOrder {
                    return $0.category.sortOrder < $1.category.sortOrder
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            let anySelected = sortedFiles.contains(where: \.isSelected)
            return LeftoverGroup(
                id: key,
                groupName: val.displayName,
                suspectedBundleID: val.bundleID,
                confidence: val.confidence,
                files: sortedFiles,
                isChecked: anySelected
            )
        }

        return groups.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence {
                return lhs.confidence < rhs.confidence
            }
            return lhs.groupName.localizedCaseInsensitiveCompare(rhs.groupName) == .orderedAscending
        }
    }

    /// Names of macOS-bundled launchd services (meaningful label segment + program basename), read once
    /// from the read-only system volume. Handles dotted suffixes such as `com.apple.BTServer.le` → `btserver`.
    public static let systemServiceNames: Set<String> = {
        let genericSuffixes: Set<String> = [
            "le", "xpc", "agent", "helper", "daemon", "service", "mac", "osx", "app", "ui", "user", "system",
        ]
        var names = Set<String>()
        let fm = FileManager.default
        for dir in ["/System/Library/LaunchAgents", "/System/Library/LaunchDaemons"] {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".plist") {
                let meta = LibraryIndex.parseLaunchPlistMetadata(at: URL(fileURLWithPath: "\(dir)/\(file)"))
                if let label = meta.label?.lowercased() {
                    let parts = label.split(separator: ".").map(String.init)
                    if let last = parts.last, last.count >= 4 {
                        names.insert(last)
                    }
                    // For `com.apple.BTServer.le`, the 3rd segment (`btserver`) is the actual service name
                    if parts.count >= 3, parts[0] == "com", parts[1] == "apple" {
                        let candidate = parts[2]
                        if candidate.count >= 4 && !genericSuffixes.contains(candidate) {
                            names.insert(candidate)
                        }
                    }
                }
                if let prog = meta.programs.first {
                    let exe = URL(fileURLWithPath: prog).lastPathComponent.lowercased()
                    if exe.count >= 4 {
                        names.insert(exe)
                    }
                }
            }
        }
        return names
    }()

    /// True if `name` is an executable / launchd service shipped with macOS (e.g. `accountsd`, `BTServer`, `livefsd`).
    public static func isSystemExecutableName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/") else { return false }
        if systemServiceNames.contains(name.lowercased()) {
            return true
        }
        let fm = FileManager.default
        for dir in ["/usr/libexec", "/usr/sbin", "/usr/bin", "/System/Library/CoreServices"] {
            if fm.fileExists(atPath: "\(dir)/\(name)") {
                return true
            }
        }
        return false
    }

    public static func looksLikeReverseDNSBundleID(_ value: String) -> Bool {
        let parts = value.lowercased().split(separator: ".")
        guard parts.count >= 3 else { return false }
        guard let first = parts.first, reverseDNSTLDs.contains(String(first)) else { return false }
        return parts.allSatisfy { !$0.isEmpty && !$0.contains(" ") }
    }

    private static func deriveGroupKey(
        strippedID: String,
        stem: String,
        isReverseDNS: Bool,
        launchLabel: String?
    ) -> String {
        if isReverseDNS {
            let parts = strippedID.split(separator: ".")
            return parts.prefix(3).joined(separator: ".")
        }
        if let label = launchLabel?.lowercased(), looksLikeReverseDNSBundleID(label) {
            return label.split(separator: ".").prefix(3).joined(separator: ".")
        }
        return stem.lowercased()
    }

    public static func deriveDisplayName(fromGroupKey key: String, fallbackStem: String) -> String {
        let genericTailTokens: Set<String> = [
            "app", "application", "mac", "macos", "desktop", "client", "helper", "agent", "daemon", "main",
        ]
        if looksLikeReverseDNSBundleID(key) {
            let parts = key.split(separator: ".").map(String.init)
            if parts.count >= 3, let last = parts.last {
                let chosen = genericTailTokens.contains(last.lowercased()) ? parts[parts.count - 2] : last
                if !chosen.isEmpty {
                    return chosen.prefix(1).uppercased() + chosen.dropFirst()
                }
            }
        }
        return fallbackStem
    }
}

import Foundation

public struct PkgInfoRecord: Sendable, Equatable {
    public let packageID: String
    public let volume: String
    public let location: String

    public init(packageID: String, volume: String, location: String) {
        self.packageID = packageID
        self.volume = volume
        self.location = location
    }

    /// Resolves a relative entry from `pkgutil --files` against `volume` and `location`.
    public func resolveAbsolutePath(for relativeFile: String) -> String {
        let baseVol = volume.isEmpty ? "/" : volume
        var baseURL = URL(fileURLWithPath: baseVol)
        let trimmedLoc = location.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !trimmedLoc.isEmpty {
            baseURL.appendPathComponent(trimmedLoc)
        }
        let trimmedRel = relativeFile.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !trimmedRel.isEmpty {
            baseURL.appendPathComponent(trimmedRel)
        }
        return baseURL.standardizedFileURL.path
    }
}

public struct ServiceMatchResult: Sendable {
    public let files: [ServiceFile]
    public let matchedPackageIDs: [String]

    public init(files: [ServiceFile], matchedPackageIDs: [String]) {
        self.files = files
        self.matchedPackageIDs = matchedPackageIDs
    }
}

/// Matches an installed application against a prebuilt `LibraryIndex` in memory,
/// plus optional lazy `pkgutil` receipt lookup for pkg-installed components.
public struct ServiceFileMatcher: Sendable {
    private static let genericStopWords: Set<String> = [
        "app", "application", "mac", "macos", "helper", "launcher", "updater", "agent",
        "daemon", "service", "services", "client", "desktop", "pro", "lite", "mini",
        "free", "plus", "studio", "home", "work", "tool", "tools", "utility", "utilities",
        "manager", "player", "viewer", "editor", "reader", "writer", "browser", "search",
        "notes", "mail", "chat", "talk", "sync", "cloud", "drive", "files", "data",
        "cache", "caches", "config", "settings", "system", "core", "common", "shared",
        "local", "public", "private", "temp", "logs", "code", "docs", "sheets", "slides",
        "apple", "google", "microsoft", "adobe", "oracle", "docker",
    ]

    public let safetyGuard: SafetyGuard

    public init(safetyGuard: SafetyGuard = SafetyGuard()) {
        self.safetyGuard = safetyGuard
    }

    /// Fast in-memory match against `LibraryIndex` (no disk traversal).
    public func matchInMemory(app: AppItem, index: LibraryIndex) -> [ServiceFile] {
        let lowerBundleID = app.bundleID.lowercased()
        let hasValidBundleID = !lowerBundleID.isEmpty && !lowerBundleID.hasPrefix("unknown.")
        let appBundlePath = app.url.standardizedFileURL.path
        let nameCandidates = buildSafeNameCandidates(for: app)

        var matched: [ServiceFile] = []
        var seenPaths = Set<String>()

        for entry in index.entries {
            let entryPath = entry.url.standardizedFileURL.path
            guard !seenPaths.contains(entryPath) else { continue }
            guard safetyGuard.validateForRemoval(entry.url).isAllowed else { continue }

            // Avoid matching Apple system files for non-Apple apps.
            if !app.isAppleAppStoreApp && entry.normalizedName.hasPrefix("com.apple.") {
                continue
            }

            if let reason = matchReason(
                entry: entry,
                bundleID: hasValidBundleID ? lowerBundleID : nil,
                appBundlePath: appBundlePath,
                teamID: app.teamIdentifier?.lowercased(),
                nameCandidates: nameCandidates
            ) {
                seenPaths.insert(entryPath)
                let requiresReboot = entryPath.contains("/Audio/Plug-Ins/HAL/")
                matched.append(ServiceFile(
                    url: entry.url,
                    category: entry.category,
                    size: nil,
                    isSelected: true,
                    requiresAdmin: entry.requiresAdmin,
                    requiresReboot: requiresReboot,
                    matchReason: reason
                ))
            }
        }

        return matched.sorted {
            if $0.category.sortOrder != $1.category.sortOrder {
                return $0.category.sortOrder < $1.category.sortOrder
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Lazy lookup of pkg-installed components for a selected app using `pkgutil`.
    public func matchWithPackages(
        app: AppItem,
        index: LibraryIndex,
        allPackageIDs: [String]
    ) -> ServiceMatchResult {
        var files = matchInMemory(app: app, index: index)
        var seenPaths = Set(files.map { $0.url.standardizedFileURL.path })
        seenPaths.insert(app.url.standardizedFileURL.path)

        let matchingPkgs = Self.findMatchingPackageIDs(
            bundleID: app.bundleID,
            allPackageIDs: allPackageIDs,
            allowApple: app.isAppleAppStoreApp
        )

        var verifiedPkgIDs: [String] = []
        let fm = FileManager.default

        for pkgID in matchingPkgs {
            let infoRes = ProcessRunner.run(executable: "/usr/sbin/pkgutil", arguments: ["--pkg-info", pkgID])
            guard infoRes.succeeded, let pkgInfo = Self.parsePkgInfo(infoRes.stdout, fallbackID: pkgID) else {
                continue
            }
            let filesRes = ProcessRunner.run(executable: "/usr/sbin/pkgutil", arguments: ["--files", pkgID])
            guard filesRes.succeeded else { continue }

            verifiedPkgIDs.append(pkgID)
            let relLines = filesRes.stdout.split(whereSeparator: \.isNewline).map(String.init)
            let collapsed = Self.resolveAndCollapsePkgFiles(
                relativeLines: relLines,
                pkgInfo: pkgInfo,
                appBundlePath: app.url.standardizedFileURL.path,
                safetyGuard: safetyGuard
            )

            for absPath in collapsed {
                guard !seenPaths.contains(absPath), fm.fileExists(atPath: absPath) else { continue }
                let url = URL(fileURLWithPath: absPath)
                guard safetyGuard.validateForRemoval(url).isAllowed else { continue }
                seenPaths.insert(absPath)

                let category = Self.categorizePath(absPath)
                let requiresReboot = absPath.contains("/Audio/Plug-Ins/HAL/")
                files.append(ServiceFile(
                    url: url,
                    category: category,
                    size: nil,
                    isSelected: true,
                    requiresAdmin: safetyGuard.requiresAdmin(for: url),
                    requiresReboot: requiresReboot,
                    matchReason: "pkgutil: \(pkgID)"
                ))
            }
        }

        files.sort {
            if $0.category.sortOrder != $1.category.sortOrder {
                return $0.category.sortOrder < $1.category.sortOrder
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        return ServiceMatchResult(files: files, matchedPackageIDs: verifiedPkgIDs)
    }

    /// Loads installed non-Apple third-party pkg receipt IDs once (fast, ~30ms).
    public static func listThirdPartyPackages() -> [String] {
        let res = ProcessRunner.run(executable: "/usr/sbin/pkgutil", arguments: ["--pkgs"])
        guard res.succeeded else { return [] }
        return res.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("com.apple.pkg.") }
    }

    public static func findMatchingPackageIDs(
        bundleID: String,
        allPackageIDs: [String],
        allowApple: Bool = false
    ) -> [String] {
        let lowerBundle = bundleID.lowercased()
        guard !lowerBundle.isEmpty, !lowerBundle.hasPrefix("unknown.") else { return [] }
        if !allowApple && lowerBundle.hasPrefix("com.apple.") { return [] }

        return allPackageIDs.filter { pkg in
            let lowerPkg = pkg.lowercased()
            if !allowApple && lowerPkg.hasPrefix("com.apple.") { return false }
            return isBoundaryPrefixMatch(candidate: lowerPkg, prefix: lowerBundle)
        }
    }

    public static func parsePkgInfo(_ output: String, fallbackID: String) -> PkgInfoRecord? {
        var packageID = fallbackID
        var volume = "/"
        var location = ""
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: ":") {
                let key = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "package-id": packageID = value
                case "volume": volume = value
                case "location": location = value
                default: break
                }
            }
        }
        return PkgInfoRecord(packageID: packageID, volume: volume, location: location)
    }

    /// Resolves relative `pkgutil --files` lines against `volume + location`,
    /// filters out shared system directories and the main `.app` itself,
    /// and collapses nested children under their top-level bundle/folder.
    public static func resolveAndCollapsePkgFiles(
        relativeLines: [String],
        pkgInfo: PkgInfoRecord,
        appBundlePath: String,
        safetyGuard: SafetyGuard
    ) -> [String] {
        let stdApp = URL(fileURLWithPath: appBundlePath).standardizedFileURL.path
        var candidates: [String] = []
        candidates.reserveCapacity(relativeLines.count)

        for rel in relativeLines {
            let trimmed = rel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "." else { continue }
            let absPath = pkgInfo.resolveAbsolutePath(for: trimmed)

            // Exclude the app bundle itself and anything inside it (already handled as main app).
            if absPath == stdApp || absPath.hasPrefix(stdApp + "/") {
                continue
            }
            // Exclude critical system/shared directories (e.g. /Library, /Applications, /usr/local/bin).
            if safetyGuard.isCriticalSharedDirectory(absPath) {
                continue
            }
            if !safetyGuard.validateForRemoval(URL(fileURLWithPath: absPath)).isAllowed {
                continue
            }
            candidates.append(absPath)
        }

        // Sort shortest path first so parent bundles/folders collapse all nested children.
        let sorted = Array(Set(candidates)).sorted { a, b in
            if a.count != b.count { return a.count < b.count }
            return a < b
        }

        var collapsed: [String] = []
        for path in sorted {
            let hasParentAlready = collapsed.contains { parent in
                path.hasPrefix(parent + "/")
            }
            if !hasParentAlready {
                collapsed.append(path)
            }
        }

        return collapsed
    }

    // MARK: - Core Matching Rules

    private func matchReason(
        entry: LibraryEntry,
        bundleID: String?,
        appBundlePath: String,
        teamID: String?,
        nameCandidates: [String]
    ) -> String? {
        // 1. LaunchAgent / LaunchDaemon referencing a binary inside this .app bundle (highest precision!)
        if !entry.launchProgramPaths.isEmpty {
            for prog in entry.launchProgramPaths {
                if prog == appBundlePath || prog.hasPrefix(appBundlePath + "/") {
                    return "Launch plist references app binary"
                }
            }
        }

        let lowerStem = entry.stem.lowercased()
        let lowerFull = entry.normalizedName

        // 2. Bundle ID exact & boundary-prefix matches
        if let bid = bundleID {
            if let label = entry.launchLabel?.lowercased(),
               Self.isBoundaryPrefixMatch(candidate: label, prefix: bid) {
                return "Launch label matches bundle ID"
            }

            if Self.isBoundaryPrefixMatch(candidate: lowerStem, prefix: bid)
                || Self.isBoundaryPrefixMatch(candidate: lowerFull, prefix: bid) {
                return "Bundle ID match"
            }

            // Group Containers: `<TeamID>.<bundleID>`, `group.<bundleID>`, `<TeamID>.group.<bundleID>`
            if entry.category == .groupContainers {
                if Self.matchesGroupContainer(entryName: lowerFull, bundleID: bid, teamID: teamID) {
                    return "App Group match"
                }
            }

            // Preferences/ByHost: `<bundleID>.<UUID>.plist`
            if entry.category == .preferences && lowerFull.hasPrefix(bid + ".") {
                return "Preference match"
            }
        }

        // 3. Name matching (strictly bounded & length >= 4 to prevent false positives)
        for name in nameCandidates {
            if lowerStem == name || lowerFull == name {
                return "App name match"
            }
            // Inside a shared vendor folder (e.g. Application Support/Microsoft/OneNote)
            if entry.isInsideVendorFolder && Self.isBoundaryPrefixMatch(candidate: lowerStem, prefix: name) {
                return "Vendor subfolder match"
            }
            // Diagnostic reports & crash logs: `AppName-2026-11-20-...ips`
            if entry.category == .logs,
               (lowerFull.hasPrefix(name + "-") || lowerFull.hasPrefix(name + "_")) {
                return "Log / crash report match"
            }
        }

        return nil
    }

    private func buildSafeNameCandidates(for app: AppItem) -> [String] {
        var rawNames: [String] = [app.name]
        if app.localizedName != app.name {
            rawNames.append(app.localizedName)
        }
        if let exec = app.executableName {
            rawNames.append(exec)
        }

        var results: [String] = []
        var seen = Set<String>()

        for raw in rawNames {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard trimmed.count >= 4 else { continue }
            guard !Self.genericStopWords.contains(trimmed) else { continue }
            guard !SafetyGuard.sharedVendorFolderNames.contains(trimmed) else { continue }
            if !seen.contains(trimmed) {
                seen.insert(trimmed)
                results.append(trimmed)
            }
            // Also include space-stripped variant if long enough (e.g. "Visual Studio Code" -> "visualstudiocode")
            let compact = trimmed.replacingOccurrences(of: " ", with: "")
            if compact != trimmed, compact.count >= 6,
               !Self.genericStopWords.contains(compact),
               !SafetyGuard.sharedVendorFolderNames.contains(compact),
               !seen.contains(compact) {
                seen.insert(compact)
                results.append(compact)
            }
        }
        return results
    }

    public static func isBoundaryPrefixMatch(candidate: String, prefix: String) -> Bool {
        guard candidate.hasPrefix(prefix) else { return false }
        if candidate.count == prefix.count { return true }
        let nextIndex = candidate.index(candidate.startIndex, offsetBy: prefix.count)
        let nextChar = candidate[nextIndex]
        return nextChar == "." || nextChar == "-" || nextChar == "_" || nextChar == " "
    }

    public static func matchesGroupContainer(entryName: String, bundleID: String, teamID: String?) -> Bool {
        if isBoundaryPrefixMatch(candidate: entryName, prefix: "group." + bundleID) {
            return true
        }
        if let teamID, !teamID.isEmpty {
            if isBoundaryPrefixMatch(candidate: entryName, prefix: "\(teamID).\(bundleID)")
                || isBoundaryPrefixMatch(candidate: entryName, prefix: "\(teamID).group.\(bundleID)") {
                return true
            }
        }
        // Match `<10-char-alnum>.<bundleID>` or `<10-char-alnum>.group.<bundleID>`
        if let dotIdx = entryName.firstIndex(of: ".") {
            let prefixToken = entryName[..<dotIdx]
            let remainder = String(entryName[entryName.index(after: dotIdx)...])
            if prefixToken.count == 10, prefixToken.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                if isBoundaryPrefixMatch(candidate: remainder, prefix: bundleID)
                    || isBoundaryPrefixMatch(candidate: remainder, prefix: "group." + bundleID) {
                    return true
                }
            }
        }
        return false
    }

    private static func categorizePath(_ path: String) -> ServiceFileCategory {
        if path.contains("/LaunchAgents/") { return .launchAgents }
        if path.contains("/LaunchDaemons/") || path.contains("/PrivilegedHelperTools/") { return .launchDaemons }
        if path.contains("/Application Support/") { return .applicationSupport }
        if path.contains("/Caches/") { return .caches }
        if path.contains("/Preferences/") { return .preferences }
        if path.contains("/Containers/") { return .containers }
        if path.contains("/Group Containers/") { return .groupContainers }
        if path.contains("/Saved Application State/") { return .savedState }
        if path.contains("/Logs/") { return .logs }
        if path.contains("/Plug-Ins/") || path.contains("/PreferencePanes/") || path.contains("/QuickLook/") {
            return .plugins
        }
        return .other
    }
}

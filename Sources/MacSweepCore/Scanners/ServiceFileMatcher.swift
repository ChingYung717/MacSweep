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
    public static let genericStopWords: Set<String> = [
        "app", "application", "mac", "macos", "helper", "launcher", "updater", "agent",
        "daemon", "service", "services", "client", "desktop", "pro", "lite", "mini",
        "free", "plus", "studio", "home", "work", "tool", "tools", "utility", "utilities",
        "manager", "player", "viewer", "editor", "reader", "writer", "browser", "search",
        "notes", "mail", "chat", "talk", "sync", "cloud", "drive", "files", "data",
        "cache", "caches", "config", "settings", "system", "core", "common", "shared",
        "local", "public", "private", "temp", "logs", "code", "docs", "sheets", "slides",
        "apple", "google", "microsoft", "adobe", "oracle", "docker",
        "audio", "share", "preview", "install", "installer", "family", "finder", "phone",
        "photos", "music", "video", "books", "calendar", "contacts", "messages", "camera",
        "clock", "maps", "stocks", "weather", "shortcuts", "reminders", "passwords",
    ]

    /// Executable names of shared runtimes / launch shims. Many unrelated apps ship the same
    /// `CFBundleExecutable` (e.g. Electron apps, NW.js apps, Chrome PWAs), so these must never be
    /// used for name-based matching.
    public static let genericExecutableNames: Set<String> = [
        "electron", "nwjs", "nw", "app_mode_loader", "launcher", "stub", "main", "run", "start",
        "applet", "droplet", "java", "javaapplicationstub", "universaljavaapplicationstub",
        "python", "python3", "node", "wine", "wine64", "wineloader", "qtwebengineprocess",
        "cefsharp", "chromium", "helper", "updater", "bootstrap", "loader", "wrapper",
    ]

    /// Only directories carrying one of these bundle extensions may be collapsed by `pkgutil` resolution.
    /// Plain directories (e.g. `/Library/StartupItems`, `/Library/Printers`, `/etc/paths.d`) are NEVER collapsed.
    public static let collapsibleBundleExtensions: Set<String> = [
        "app", "framework", "prefpane", "plugin", "bundle", "driver", "kext", "qlgenerator",
        "mdimporter", "saver", "xpc", "appex", "service", "wdgt", "action", "workflow",
        "importer", "colorpicker", "osax", "component", "vst", "vst3", "au",
    ]

    public let safetyGuard: SafetyGuard

    public init(safetyGuard: SafetyGuard = SafetyGuard()) {
        self.safetyGuard = safetyGuard
    }

    /// Name candidates (claimed by ≥2 installed apps) that must not be used for name-based matching.
    /// Bundle-ID / App-Group / launchd-binary matches are unaffected.
    public static func ambiguousNameCandidates(across apps: [AppItem]) -> Set<String> {
        var counts: [String: Int] = [:]
        for app in apps {
            for name in Set(nameCandidates(for: app)) {
                counts[name, default: 0] += 1
            }
        }
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    /// True if another installed app has a strictly longer bundle ID that also boundary-prefix-matches `candidate`.
    /// Prevents uninstalling `com.vendor.app` from claiming data belonging to `com.vendor.app.extension-app`.
    public static func isClaimedByLongerInstalledBundleID(
        _ candidate: String,
        ownBundleID: String,
        allInstalledBundleIDs: Set<String>
    ) -> Bool {
        guard !allInstalledBundleIDs.isEmpty else { return false }
        let lowerCandidate = candidate.lowercased()
        let lowerOwn = ownBundleID.lowercased()
        for other in allInstalledBundleIDs {
            let lowerOther = other.lowercased()
            guard lowerOther.count > lowerOwn.count,
                  isBoundaryPrefixMatch(candidate: lowerOther, prefix: lowerOwn) else {
                continue
            }
            if isBoundaryPrefixMatch(candidate: lowerCandidate, prefix: lowerOther) {
                return true
            }
        }
        return false
    }

    /// Fast in-memory match against `LibraryIndex` (no disk traversal, no per-entry safety I/O).
    public func matchInMemory(
        app: AppItem,
        index: LibraryIndex,
        ambiguousNames: Set<String> = [],
        allInstalledBundleIDs: Set<String> = []
    ) -> [ServiceFile] {
        let lowerBundleID = app.bundleID.lowercased()
        let hasValidBundleID = !lowerBundleID.isEmpty && !lowerBundleID.hasPrefix("unknown.")
        let appBundlePath = app.url.standardizedFileURL.path
        let nameCandidates = Self.nameCandidates(for: app).filter { !ambiguousNames.contains($0) }

        var matched: [ServiceFile] = []
        var seenPaths = Set<String>()

        for entry in index.entries {
            guard entry.isRemovable else { continue }
            let entryPath = entry.url.path
            guard !seenPaths.contains(entryPath) else { continue }

            // Avoid matching Apple system files for non-Apple apps.
            if !app.isAppleAppStoreApp && entry.normalizedName.hasPrefix("com.apple.") {
                continue
            }

            if let reason = matchReason(
                entry: entry,
                bundleID: hasValidBundleID ? lowerBundleID : nil,
                appBundlePath: appBundlePath,
                teamID: app.teamIdentifier?.lowercased(),
                nameCandidates: nameCandidates,
                allInstalledBundleIDs: allInstalledBundleIDs
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
                    isSystemScope: entry.isSystemScope,
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

    /// Lazy lookup of pkg-installed components for a selected app using `pkgutil --only-files --files`.
    public func matchWithPackages(
        app: AppItem,
        index: LibraryIndex,
        allPackageIDs: [String],
        ambiguousNames: Set<String> = [],
        allInstalledBundleIDs: Set<String> = [],
        otherInstalledAppPaths: Set<String> = []
    ) -> ServiceMatchResult {
        var files = matchInMemory(
            app: app,
            index: index,
            ambiguousNames: ambiguousNames,
            allInstalledBundleIDs: allInstalledBundleIDs
        )
        var seenPaths = Set(files.map { $0.url.standardizedFileURL.path })
        seenPaths.insert(app.url.standardizedFileURL.path)

        let matchingPkgs = Self.findMatchingPackageIDs(
            bundleID: app.bundleID,
            allPackageIDs: allPackageIDs,
            allowApple: app.isAppleAppStoreApp,
            allInstalledBundleIDs: allInstalledBundleIDs
        )

        var verifiedPkgIDs: [String] = []
        let fm = FileManager.default

        for pkgID in matchingPkgs {
            let infoRes = ProcessRunner.run(executable: "/usr/sbin/pkgutil", arguments: ["--pkg-info", pkgID])
            guard infoRes.succeeded, let pkgInfo = Self.parsePkgInfo(infoRes.stdout, fallbackID: pkgID) else {
                continue
            }
            // `--only-files` ensures bare shared directories (`/Library/StartupItems`, `/Library/Printers`,
            // `/etc/paths.d`) are never emitted as removable targets.
            let filesRes = ProcessRunner.run(executable: "/usr/sbin/pkgutil", arguments: ["--only-files", "--files", pkgID])
            guard filesRes.succeeded else { continue }

            verifiedPkgIDs.append(pkgID)
            let relLines = filesRes.stdout.split(whereSeparator: \.isNewline).map(String.init)
            let collapsed = Self.resolveAndCollapsePkgFiles(
                relativeLines: relLines,
                pkgInfo: pkgInfo,
                appBundlePath: app.url.standardizedFileURL.path,
                safetyGuard: safetyGuard,
                otherInstalledAppPaths: otherInstalledAppPaths
            )

            for absPath in collapsed {
                guard !seenPaths.contains(absPath), fm.fileExists(atPath: absPath) else { continue }
                let url = URL(fileURLWithPath: absPath)
                guard safetyGuard.validateForRemoval(url).isAllowed else { continue }
                seenPaths.insert(absPath)

                let category = Self.categorizePath(absPath)
                let requiresReboot = absPath.contains("/Audio/Plug-Ins/HAL/")
                let isSys = absPath.hasPrefix("/Library/") || absPath.hasPrefix("/usr/") || absPath.hasPrefix("/etc/")
                files.append(ServiceFile(
                    url: url,
                    category: category,
                    size: nil,
                    isSelected: true,
                    requiresAdmin: safetyGuard.requiresAdmin(for: url),
                    requiresReboot: requiresReboot,
                    isSystemScope: isSys,
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

    /// Loads installed non-Apple third-party pkg receipt IDs once (excludes ALL `com.apple.*`, not only `com.apple.pkg.*`).
    public static func listThirdPartyPackages() -> [String] {
        let res = ProcessRunner.run(executable: "/usr/sbin/pkgutil", arguments: ["--pkgs"])
        guard res.succeeded else { return [] }
        return res.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("com.apple.") }
    }

    public static func findMatchingPackageIDs(
        bundleID: String,
        allPackageIDs: [String],
        allowApple: Bool = false,
        allInstalledBundleIDs: Set<String> = []
    ) -> [String] {
        let lowerBundle = bundleID.lowercased()
        guard !lowerBundle.isEmpty, !lowerBundle.hasPrefix("unknown.") else { return [] }
        if !allowApple && lowerBundle.hasPrefix("com.apple.") { return [] }

        return allPackageIDs.filter { pkg in
            let lowerPkg = pkg.lowercased()
            if !allowApple && lowerPkg.hasPrefix("com.apple.") { return false }
            guard isBoundaryPrefixMatch(candidate: lowerPkg, prefix: lowerBundle) else { return false }
            if isClaimedByLongerInstalledBundleID(lowerPkg, ownBundleID: lowerBundle, allInstalledBundleIDs: allInstalledBundleIDs) {
                return false
            }
            return true
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

    /// Resolves relative `pkgutil` lines against `volume + location`, collapses ONLY into explicit
    /// macOS bundle ancestors (`.driver`, `.framework`, `.plugin`, `.prefPane`, etc.), and NEVER
    /// collapses into or returns plain shared directories (e.g. `/Library/StartupItems`, `/Library/Printers`).
    public static func resolveAndCollapsePkgFiles(
        relativeLines: [String],
        pkgInfo: PkgInfoRecord,
        appBundlePath: String,
        safetyGuard: SafetyGuard,
        otherInstalledAppPaths: Set<String> = []
    ) -> [String] {
        let stdApp = URL(fileURLWithPath: appBundlePath).standardizedFileURL.path
        let stdOtherApps = Set(otherInstalledAppPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let fm = FileManager.default

        // Resolve all non-empty lines first so we can identify plain parent directories present in `--files` input.
        var resolvedAll: [String] = []
        resolvedAll.reserveCapacity(relativeLines.count)
        for rel in relativeLines {
            let trimmed = rel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "." else { continue }
            resolvedAll.append(pkgInfo.resolveAbsolutePath(for: trimmed))
        }

        let parentDirsOfOtherEntries: Set<String> = {
            var parents = Set<String>()
            for path in resolvedAll {
                var cur = URL(fileURLWithPath: path).deletingLastPathComponent().path
                while cur.count > 1 {
                    if !parents.insert(cur).inserted { break }
                    cur = URL(fileURLWithPath: cur).deletingLastPathComponent().path
                }
            }
            return parents
        }()

        var results: [String] = []
        var seen = Set<String>()

        for absPath in resolvedAll {
            // Exclude the app bundle itself and anything inside it (already handled as main app).
            if absPath == stdApp || absPath.hasPrefix(stdApp + "/") {
                continue
            }

            // Collapse up to the outermost enclosing known bundle (e.g. `OrayVirtualAudioDevice.driver`),
            // never collapsing into a plain directory.
            let targetPath = outermostCollapsibleBundle(for: absPath) ?? absPath

            if targetPath == stdApp || targetPath.hasPrefix(stdApp + "/") {
                continue
            }
            // Do not claim separate installed `.app` bundles belonging to sibling products (e.g. Google Docs/Sheets/Slides).
            if stdOtherApps.contains(targetPath) {
                continue
            }
            let ext = URL(fileURLWithPath: targetPath).pathExtension.lowercased()
            let isKnownBundle = collapsibleBundleExtensions.contains(ext)

            if !isKnownBundle {
                // Reject plain directories (either known parent of other entries in BOM, or existing directory on disk).
                if parentDirsOfOtherEntries.contains(targetPath) {
                    continue
                }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: targetPath, isDirectory: &isDir), isDir.boolValue {
                    continue
                }
                // Reject bare top-level non-extension folder entries directly under `/Library`, `/etc`, `/usr`, `/Applications`
                if ext.isEmpty && isLikelySharedContainerPath(targetPath) {
                    continue
                }
            }

            if safetyGuard.isCriticalSharedDirectory(targetPath) {
                continue
            }
            if !safetyGuard.validateForRemoval(URL(fileURLWithPath: targetPath)).isAllowed {
                continue
            }

            if seen.insert(targetPath).inserted {
                results.append(targetPath)
            }
        }

        return results.sorted()
    }

    private static func outermostCollapsibleBundle(for absPath: String) -> String? {
        let components = URL(fileURLWithPath: absPath).pathComponents
        var built = ""
        for comp in components {
            if comp == "/" {
                built = "/"
                continue
            }
            built = (built == "/") ? "/\(comp)" : "\(built)/\(comp)"
            let ext = URL(fileURLWithPath: comp).pathExtension.lowercased()
            if collapsibleBundleExtensions.contains(ext) {
                return built
            }
        }
        return nil
    }

    private static func isLikelySharedContainerPath(_ path: String) -> Bool {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        return [
            "/",
            "/Library",
            "/etc",
            "/private/etc",
            "/usr",
            "/usr/local",
            "/Applications",
            "/System",
        ].contains(parent)
    }

    // MARK: - Core Matching Rules

    private func matchReason(
        entry: LibraryEntry,
        bundleID: String?,
        appBundlePath: String,
        teamID: String?,
        nameCandidates: [String],
        allInstalledBundleIDs: Set<String>
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

        // 2. Bundle ID exact & boundary-prefix matches (excluding entries owned by a longer installed bundle ID)
        if let bid = bundleID {
            if let label = entry.launchLabel?.lowercased(),
               Self.isBoundaryPrefixMatch(candidate: label, prefix: bid),
               !Self.isClaimedByLongerInstalledBundleID(label, ownBundleID: bid, allInstalledBundleIDs: allInstalledBundleIDs) {
                return "Launch label matches bundle ID"
            }

            let stripped = InstalledAppInventory.stripContainerPrefixes(lowerStem)
            if (Self.isBoundaryPrefixMatch(candidate: lowerStem, prefix: bid)
                || Self.isBoundaryPrefixMatch(candidate: lowerFull, prefix: bid)),
               !Self.isClaimedByLongerInstalledBundleID(stripped, ownBundleID: bid, allInstalledBundleIDs: allInstalledBundleIDs) {
                return "Bundle ID match"
            }

            // Group Containers: `<TeamID>.<bundleID>`, `group.<bundleID>`, `<TeamID>.group.<bundleID>`
            if entry.category == .groupContainers {
                let strippedGroup = InstalledAppInventory.stripContainerPrefixes(lowerFull)
                if Self.matchesGroupContainer(entryName: lowerFull, bundleID: bid, teamID: teamID),
                   !Self.isClaimedByLongerInstalledBundleID(strippedGroup, ownBundleID: bid, allInstalledBundleIDs: allInstalledBundleIDs) {
                    return "App Group match"
                }
            }

            // Preferences/ByHost: `<bundleID>.<UUID>.plist`
            if entry.category == .preferences && lowerFull.hasPrefix(bid + "."),
               !Self.isClaimedByLongerInstalledBundleID(lowerStem, ownBundleID: bid, allInstalledBundleIDs: allInstalledBundleIDs) {
                return "Preference match"
            }
        }

        // 3. Name matching (strictly bounded & length >= 4 to prevent false positives)
        for name in nameCandidates {
            if lowerStem == name || lowerFull == name {
                return "App name match"
            }
            if entry.isInsideVendorFolder && Self.isBoundaryPrefixMatch(candidate: lowerStem, prefix: name) {
                return "Vendor subfolder match"
            }
            if entry.category == .logs,
               (lowerFull.hasPrefix(name + "-") || lowerFull.hasPrefix(name + "_")) {
                return "Log / crash report match"
            }
        }

        return nil
    }

    public static func nameCandidates(for app: AppItem) -> [String] {
        var rawNames: [String] = [app.name]
        if app.localizedName != app.name {
            rawNames.append(app.localizedName)
        }
        if let exec = app.executableName,
           !genericExecutableNames.contains(exec.lowercased()) {
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

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
            var names = Set(nameCandidates(for: app))
            if let exec = app.executableName {
                let trimmed = exec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmed.count >= 4,
                   !genericExecutableNames.contains(trimmed),
                   !genericStopWords.contains(trimmed),
                   !SafetyGuard.sharedVendorFolderNames.contains(trimmed) {
                    names.insert(trimmed)
                }
            }
            for name in names {
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

    /// Returns `true` only for well-formed reverse-DNS bundle identifiers safe for matching.
    /// Strips `group.` / `groups.` / `<10-char TeamID>.` prefixes before checking `com.apple`/`com.apple.*`,
    /// rejects `group.*` / `groups.*` as an app bundle ID, non-`com.apple` Apple group namespaces
    /// (`is.workflow.*`, `tvappservices.*`), single-segment IDs, bare `"com.apple"`, synthetic `"unknown.*"`,
    /// 2-segment shared-vendor prefixes, empty segments, leading `"-"`, whitespace, control chars, and NUL bytes.
    public static func isMatchableBundleID(_ bundleID: String, allowApple: Bool = false) -> Bool {
        let lower = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty,
              !lower.contains("\0"),
              !lower.hasPrefix("-"),
              !lower.hasPrefix("unknown."),
              !lower.hasPrefix("group."),
              !lower.hasPrefix("groups."),
              !lower.contains(where: { $0.isWhitespace || ($0.isASCII && ($0.asciiValue ?? 32) < 32) }),
              lower != "com.apple" else {
            return false
        }
        let stripped = InstalledAppInventory.stripContainerPrefixes(lower)
        if stripped.isEmpty || stripped == "com.apple" {
            return false
        }
        if !allowApple {
            if stripped.hasPrefix("com.apple.")
                || SafetyGuard.isAppleGroupContainerName(lower)
                || SafetyGuard.isAppleGroupContainerName("group." + lower) {
                return false
            }
        }
        let rawParts = lower.split(separator: ".", omittingEmptySubsequences: false)
        guard rawParts.count >= 2, rawParts.allSatisfy({ !$0.isEmpty }) else {
            return false
        }
        // Reject overly broad 2-segment vendor-only prefixes like `com.google`, `com.microsoft`, `com.adobe`.
        if rawParts.count == 2 {
            let second = String(rawParts[1])
            if second == "apple" || SafetyGuard.sharedVendorFolderNames.contains(second) {
                return false
            }
        }
        return true
    }

    /// Only >= 3-segment reverse-DNS identifiers are allowed to boundary-prefix match sub-identifiers,
    /// LaunchDaemons, or pkgutil receipts. 2-segment IDs (e.g. `local.myapp`, `com.docker`, `com.1password`,
    /// `org.python`, `us.zoom`) are restricted to exact matches (plus ByHost `.<UUID>` preferences).
    public static func allowsPrefixMatching(forBundleID bundleID: String) -> Bool {
        let lower = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty }
    }

    private static func matchesBundleIdentifier(candidate: String, bundleID: String, allowPrefix: Bool) -> Bool {
        allowPrefix ? isBoundaryPrefixMatch(candidate: candidate, prefix: bundleID) : (candidate == bundleID)
    }

    private static func normalizedPathKey(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Maps each lowercased `application-groups` entitlement ID to the set of normalized `.app` paths declaring it.
    public static func applicationGroupOwners(across apps: [AppItem]) -> [String: Set<String>] {
        var owners: [String: Set<String>] = [:]
        for app in apps where !app.applicationGroups.isEmpty {
            let pathKey = normalizedPathKey(app.url.path)
            for group in app.applicationGroups {
                let lower = group.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !lower.isEmpty {
                    owners[lower, default: []].insert(pathKey)
                }
            }
        }
        return owners
    }

    /// Returns all lowercased Group Container IDs declared by any OTHER installed `.app`
    /// (different normalized bundle path from `app.url`), preventing shared-suite containers
    /// (e.g. Microsoft Office) and installed third-party `group.*` containers from being claimed.
    public static func otherInstalledApplicationGroups(
        for app: AppItem,
        groupOwners: [String: Set<String>]
    ) -> Set<String> {
        guard !groupOwners.isEmpty else { return [] }
        let selfPathKey = normalizedPathKey(app.url.path)
        var others = Set<String>()
        for (groupID, paths) in groupOwners {
            if paths.contains(where: { $0 != selfPathKey }) {
                others.insert(groupID)
            }
        }
        return others
    }

    /// Fast in-memory match against `LibraryIndex` (no disk traversal, no per-entry safety I/O).
    public func matchInMemory(
        app: AppItem,
        index: LibraryIndex,
        ambiguousNames: Set<String> = [],
        allInstalledBundleIDs: Set<String> = [],
        otherInstalledAppGroups: Set<String> = []
    ) -> [ServiceFile] {
        let lowerBundleID = app.bundleID.lowercased()
        let hasValidBundleID = Self.isMatchableBundleID(lowerBundleID, allowApple: app.isAppleAppStoreApp)
        let lowerTeamID = app.teamIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasVerifiedTeamID = (lowerTeamID?.isEmpty == false)
        let appBundlePath = app.url.standardizedFileURL.path
        let nameCandidates = Self.nameCandidates(for: app).filter { !ambiguousNames.contains($0) }
        let lowerOtherGroups = Set(otherInstalledAppGroups.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        let lowerInstalledIDs = Set(allInstalledBundleIDs.map { $0.lowercased() })
        let verifiedEmbeddedIDs: [String] = hasVerifiedTeamID
            ? app.embeddedBundleIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { bid in
                    bid != lowerBundleID
                        && Self.isMatchableBundleID(bid, allowApple: false)
                        && !lowerInstalledIDs.contains(bid)
                        && !safetyGuard.matchesProtectedBundleID(bid)
                }
            : []
        let verifiedHelperLabels: Set<String> = hasVerifiedTeamID
            ? Set(app.privilegedHelperLabels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            : []
        let uniqueRepeatedVendorPrefix: String? = {
            guard hasVerifiedTeamID, hasValidBundleID else { return nil }
            let parts = lowerBundleID.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[1] == parts[2], parts[1].count >= 4 else { return nil }
            let vendor = String(parts[1])
            guard vendor != "apple", !SafetyGuard.sharedVendorFolderNames.contains(vendor) else { return nil }
            let prefix2 = "\(parts[0]).\(parts[1])"
            let claimedByOther = lowerInstalledIDs.contains { other in
                other != lowerBundleID && (other == prefix2 || other.hasPrefix(prefix2 + "."))
            }
            return claimedByOther ? nil : prefix2
        }()

        // Pre-pass: verify any LaunchDaemon/LaunchAgent plists referencing this app via
        // Rule 1, AssociatedBundleIdentifiers, or SMPrivilegedExecutables so their referenced
        // `/Library/PrivilegedHelperTools/<name>` binaries are also discovered cleanly.
        var helperBinaryTeamCache: [String: String?] = [:]
        func binaryMatchesVerifiedTeam(_ path: String) -> Bool {
            guard let expectedTeam = lowerTeamID, !expectedTeam.isEmpty else { return false }
            let key = Self.normalizedPathKey(path)
            if let cached = helperBinaryTeamCache[key] {
                return cached == expectedTeam
            }
            let actual = AppScanner.extractTeamIdentifier(at: URL(fileURLWithPath: path))?.lowercased()
            helperBinaryTeamCache[key] = actual
            return actual == expectedTeam
        }

        let ownAndEmbeddedIDs = Set(([hasValidBundleID ? lowerBundleID : nil].compactMap { $0 }) + verifiedEmbeddedIDs)
        var verifiedAssociatedHelperPaths = Set<String>()
        var unverifiedAssociatedHelperPaths = Set<String>()
        if hasVerifiedTeamID && (!ownAndEmbeddedIDs.isEmpty || !verifiedHelperLabels.isEmpty) {
            for entry in index.entries where entry.isRemovable && (entry.category == .launchDaemons || entry.category == .launchAgents) {
                let lowerAssoc = Set(entry.associatedBundleIDs.map { $0.lowercased() })
                let lowerLabel = entry.launchLabel?.lowercased()
                let matchesAssoc = !lowerAssoc.isDisjoint(with: ownAndEmbeddedIDs)
                let matchesHelper = lowerLabel.map { verifiedHelperLabels.contains($0) } ?? false
                guard matchesAssoc || matchesHelper else { continue }
                for prog in entry.launchProgramPaths where prog.hasPrefix("/Library/PrivilegedHelperTools/") {
                    if binaryMatchesVerifiedTeam(prog) {
                        verifiedAssociatedHelperPaths.insert(Self.normalizedPathKey(prog))
                    } else if matchesAssoc {
                        unverifiedAssociatedHelperPaths.insert(Self.normalizedPathKey(prog))
                    }
                }
            }
        }

        var matched: [ServiceFile] = []
        var seenPaths = Set<String>()

        for entry in index.entries {
            guard entry.isRemovable else { continue }
            let entryPath = entry.url.standardizedFileURL.path
            let entryKey = Self.normalizedPathKey(entryPath)
            guard !seenPaths.contains(entryKey) else { continue }

            let lowerStem = entry.stem.lowercased()
            let strippedName = InstalledAppInventory.stripContainerPrefixes(entry.normalizedName)
            let strippedStem = InstalledAppInventory.stripContainerPrefixes(lowerStem)
            let lowerLaunchLabel = entry.launchLabel?.lowercased()

            // Avoid matching Apple system, Group Container, or launchd files for non-Apple apps.
            if !app.isAppleAppStoreApp {
                if strippedName == "com.apple" || strippedName.hasPrefix("com.apple.")
                    || strippedStem == "com.apple" || strippedStem.hasPrefix("com.apple.")
                    || lowerLaunchLabel == "com.apple" || (lowerLaunchLabel?.hasPrefix("com.apple.") ?? false) {
                    continue
                }
                if entry.category == .groupContainers && SafetyGuard.isAppleGroupContainerName(entry.normalizedName) {
                    continue
                }
            }

            // Never claim entries belonging to a user-protected bundle ID.
            let noUUIDStem = InstalledAppInventory.stripUUIDSuffix(lowerStem)
            if safetyGuard.matchesProtectedBundleID(entry.normalizedName)
                || safetyGuard.matchesProtectedBundleID(lowerStem)
                || safetyGuard.matchesProtectedBundleID(noUUIDStem)
                || (lowerLaunchLabel.map { safetyGuard.matchesProtectedBundleID($0) } ?? false) {
                continue
            }

            if let match = matchReason(
                entry: entry,
                bundleID: hasValidBundleID ? lowerBundleID : nil,
                embeddedBundleIDs: verifiedEmbeddedIDs,
                uniqueRepeatedVendorPrefix: uniqueRepeatedVendorPrefix,
                privilegedHelperLabels: verifiedHelperLabels,
                verifiedAssociatedHelperPaths: verifiedAssociatedHelperPaths,
                unverifiedAssociatedHelperPaths: unverifiedAssociatedHelperPaths,
                binaryMatchesVerifiedTeam: binaryMatchesVerifiedTeam,
                allowApple: app.isAppleAppStoreApp,
                appBundlePath: appBundlePath,
                appRawNameLower: app.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                appLocalizedNameLower: app.localizedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                teamID: lowerTeamID,
                applicationGroups: app.applicationGroups,
                nameCandidates: nameCandidates,
                allInstalledBundleIDs: allInstalledBundleIDs,
                otherInstalledAppGroups: lowerOtherGroups
            ) {
                seenPaths.insert(entryKey)
                let requiresReboot = entryPath.contains("/Audio/Plug-Ins/HAL/")
                matched.append(ServiceFile(
                    url: entry.url,
                    category: entry.category,
                    size: nil,
                    isSelected: match.defaultSelected,
                    requiresAdmin: entry.requiresAdmin,
                    requiresReboot: requiresReboot,
                    isSystemScope: entry.isSystemScope,
                    matchReason: match.reason,
                    expectedCanonicalParent: entry.expectedCanonicalParent
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
        otherInstalledAppPaths: Set<String> = [],
        otherInstalledAppGroups: Set<String> = []
    ) -> ServiceMatchResult {
        var files = matchInMemory(
            app: app,
            index: index,
            ambiguousNames: ambiguousNames,
            allInstalledBundleIDs: allInstalledBundleIDs,
            otherInstalledAppGroups: otherInstalledAppGroups
        )
        var seenPaths = Set(files.map { Self.normalizedPathKey($0.url.standardizedFileURL.path) })
        seenPaths.insert(Self.normalizedPathKey(app.url.standardizedFileURL.path))

        let matchingPkgs = Self.findMatchingPackageIDs(
            bundleID: app.bundleID,
            allPackageIDs: allPackageIDs,
            allowApple: app.isAppleAppStoreApp,
            allInstalledBundleIDs: allInstalledBundleIDs
        )

        var verifiedPkgIDs: [String] = []
        let fm = FileManager.default

        for pkgID in matchingPkgs {
            guard !safetyGuard.matchesProtectedBundleID(pkgID) else { continue }
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
                let normAbs = Self.normalizedPathKey(absPath)
                guard !seenPaths.contains(normAbs), fm.fileExists(atPath: absPath) else { continue }
                let url = URL(fileURLWithPath: absPath)
                guard safetyGuard.validateForRemoval(url).isAllowed else { continue }
                seenPaths.insert(normAbs)

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
                    matchReason: "pkgutil: \(pkgID)",
                    expectedCanonicalParent: PrivilegedExecutor.canonicalParentPath(forTargetURL: url)
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
        guard isMatchableBundleID(lowerBundle, allowApple: allowApple) else { return [] }
        let allowPrefix = allowsPrefixMatching(forBundleID: lowerBundle)

        return allPackageIDs.filter { pkg in
            let lowerPkg = pkg.lowercased()
            let strippedPkg = InstalledAppInventory.stripContainerPrefixes(lowerPkg)
            if !allowApple && (strippedPkg == "com.apple" || strippedPkg.hasPrefix("com.apple.")) {
                return false
            }
            guard matchesBundleIdentifier(candidate: lowerPkg, bundleID: lowerBundle, allowPrefix: allowPrefix) else {
                return false
            }
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
        let stdAppNorm = normalizedPathKey(appBundlePath)
        let stdOtherAppsNorm = Set(otherInstalledAppPaths.map(normalizedPathKey))
        let fm = FileManager.default

        // Resolve all non-empty lines first so we can identify plain parent directories present in `--files` input.
        var resolvedAll: [String] = []
        resolvedAll.reserveCapacity(relativeLines.count)
        for rel in relativeLines {
            let trimmed = rel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != "." else { continue }
            resolvedAll.append(pkgInfo.resolveAbsolutePath(for: trimmed))
        }

        let parentDirsOfOtherEntriesNorm: Set<String> = {
            var parents = Set<String>()
            for path in resolvedAll {
                var cur = URL(fileURLWithPath: path).deletingLastPathComponent().path
                while cur.count > 1 {
                    let normCur = normalizedPathKey(cur)
                    if !parents.insert(normCur).inserted { break }
                    cur = URL(fileURLWithPath: cur).deletingLastPathComponent().path
                }
            }
            return parents
        }()

        var results: [String] = []
        var seenNorm = Set<String>()

        for absPath in resolvedAll {
            let absNorm = normalizedPathKey(absPath)
            // Exclude the app bundle itself and anything inside it (already handled as main app).
            if absNorm == stdAppNorm || absNorm.hasPrefix(stdAppNorm + "/") {
                continue
            }

            // Collapse up to the outermost enclosing known bundle (e.g. `OrayVirtualAudioDevice.driver`),
            // never collapsing into a plain directory.
            let targetPath = outermostCollapsibleBundle(for: absPath) ?? absPath
            let targetNorm = normalizedPathKey(targetPath)

            if targetNorm == stdAppNorm || targetNorm.hasPrefix(stdAppNorm + "/") {
                continue
            }
            // Do not claim separate installed `.app` bundles (or files inside them) belonging to sibling products.
            if stdOtherAppsNorm.contains(where: { targetNorm == $0 || targetNorm.hasPrefix($0 + "/") }) {
                continue
            }
            let ext = URL(fileURLWithPath: targetPath).pathExtension.lowercased()
            let isKnownBundle = collapsibleBundleExtensions.contains(ext)

            if !isKnownBundle {
                // Reject plain directories (either known parent of other entries in BOM, or existing directory on disk).
                if parentDirsOfOtherEntriesNorm.contains(targetNorm) {
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

            if seenNorm.insert(targetNorm).inserted {
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
        embeddedBundleIDs: [String] = [],
        uniqueRepeatedVendorPrefix: String? = nil,
        privilegedHelperLabels: Set<String> = [],
        verifiedAssociatedHelperPaths: Set<String> = [],
        unverifiedAssociatedHelperPaths: Set<String> = [],
        binaryMatchesVerifiedTeam: (String) -> Bool = { _ in false },
        allowApple: Bool,
        appBundlePath: String,
        appRawNameLower: String = "",
        appLocalizedNameLower: String = "",
        teamID: String?,
        applicationGroups: [String],
        nameCandidates: [String],
        allInstalledBundleIDs: Set<String>,
        otherInstalledAppGroups: Set<String>
    ) -> (reason: String, defaultSelected: Bool)? {
        // 0. Home dot-folders (e.g. `~/.docker`) are strictly restricted to exact non-ambiguous app name matches.
        if entry.isHomeDotEntry {
            guard entry.normalizedName.hasPrefix(".") else { return nil }
            let dotBody = String(entry.normalizedName.dropFirst())
            guard dotBody.count >= 5, !LibraryIndex.protectedHomeDotNames.contains(dotBody) else { return nil }
            let exactSignedNameMatch = (teamID?.isEmpty == false)
                && (appRawNameLower == dotBody || appLocalizedNameLower == dotBody)
                && !SafetyGuard.sharedVendorFolderNames.contains(dotBody)
            guard nameCandidates.contains(dotBody) || exactSignedNameMatch else { return nil }
            return ("Home config folder match", true)
        }

        let normAppBundle = Self.normalizedPathKey(appBundlePath)
        let lowerStem = entry.stem.lowercased()
        let lowerFull = entry.normalizedName

        // 1. LaunchAgent / LaunchDaemon referencing a binary inside this .app bundle (highest precision!)
        if !entry.launchProgramPaths.isEmpty {
            for prog in entry.launchProgramPaths {
                let normProg = Self.normalizedPathKey(prog)
                if normProg == normAppBundle || normProg.hasPrefix(normAppBundle + "/") {
                    return ("Launch plist references app binary", true)
                }
            }
        }

        // 1b. LaunchDaemon / LaunchAgent declaring AssociatedBundleIdentifiers matching this app,
        //     or PrivilegedHelperTools declared in SMPrivilegedExecutables / referenced by a verified daemon.
        let ownAndEmbeddedIDs = Set(([bundleID].compactMap { $0 }) + embeddedBundleIDs)
        if (entry.category == .launchDaemons || entry.category == .launchAgents),
           !entry.associatedBundleIDs.isEmpty,
           !ownAndEmbeddedIDs.isEmpty {
            let lowerAssoc = Set(entry.associatedBundleIDs.map { $0.lowercased() })
            if !lowerAssoc.isDisjoint(with: ownAndEmbeddedIDs) {
                let verifiedBinary = entry.launchProgramPaths.contains { prog in
                    let np = Self.normalizedPathKey(prog)
                    return np == normAppBundle || np.hasPrefix(normAppBundle + "/") || binaryMatchesVerifiedTeam(prog)
                }
                if verifiedBinary {
                    return ("Launch plist associated with app", true)
                } else if !entry.isSystemScope || (teamID?.isEmpty == false) {
                    return ("Launch plist associated with bundle ID", false)
                }
            }
        }

        if entry.category == .launchDaemons {
            let entryPathNorm = Self.normalizedPathKey(entry.url.path)
            if verifiedAssociatedHelperPaths.contains(entryPathNorm) {
                return ("Privileged helper tool match", true)
            }
            if unverifiedAssociatedHelperPaths.contains(entryPathNorm) {
                return ("Associated privileged helper tool", false)
            }
            let candidateLabel = entry.launchLabel?.lowercased() ?? lowerStem
            if !privilegedHelperLabels.isEmpty && privilegedHelperLabels.contains(candidateLabel) {
                let isHelperBinary = entry.url.path.contains("/PrivilegedHelperTools/")
                let verified = isHelperBinary
                    ? binaryMatchesVerifiedTeam(entry.url.path)
                    : entry.launchProgramPaths.contains { binaryMatchesVerifiedTeam($0) }
                if verified {
                    return ("Privileged helper tool match", true)
                }
            }
        }

        // 2. Bundle ID exact & boundary-prefix matches (excluding entries owned by a longer installed bundle ID).
        //    2-segment IDs only exact-match (plus ByHost UUID) so vendor prefixes like `com.docker` cannot
        //    claim 3-segment sibling products or root LaunchDaemons.
        //    LaunchDaemons/LaunchAgents matched without Rule 1 binary ownership default to unselected (`false`).
        let candidateBundleIDs = ([bundleID].compactMap { $0 }) + embeddedBundleIDs
        for bid in candidateBundleIDs {
            let allowPrefix = Self.allowsPrefixMatching(forBundleID: bid)
            let isLaunchEntry = (entry.category == .launchDaemons || entry.category == .launchAgents)

            if let label = entry.launchLabel?.lowercased(),
               Self.matchesBundleIdentifier(candidate: label, bundleID: bid, allowPrefix: allowPrefix),
               !Self.isClaimedByLongerInstalledBundleID(label, ownBundleID: bid, allInstalledBundleIDs: allInstalledBundleIDs) {
                return ("Launch label matches bundle ID", false)
            }

            if entry.category != .groupContainers {
                let stripped = InstalledAppInventory.stripContainerPrefixes(lowerStem)
                if (Self.matchesBundleIdentifier(candidate: lowerStem, bundleID: bid, allowPrefix: allowPrefix)
                    || Self.matchesBundleIdentifier(candidate: lowerFull, bundleID: bid, allowPrefix: allowPrefix)),
                   !Self.isClaimedByLongerInstalledBundleID(stripped, ownBundleID: bid, allInstalledBundleIDs: allInstalledBundleIDs) {
                    return ("Bundle ID match", !isLaunchEntry)
                }
            }

            // Group Containers: require verified `com.apple.security.application-groups` entitlement match
            // or strict verified `<TeamID>.<bundleID>` prefix match (never wildcard/unconditional `group.*`),
            // and NEVER claim a container declared by any other installed app (protects shared suites like Office
            // as well as installed third-party `group.*` containers).
            if entry.category == .groupContainers {
                guard !otherInstalledAppGroups.contains(lowerFull) else {
                    return nil
                }
                let strippedGroup = InstalledAppInventory.stripContainerPrefixes(lowerFull)
                let claimedByOtherInstalled = allInstalledBundleIDs.contains { other in
                    let lowerOther = other.lowercased()
                    guard lowerOther != bid else { return false }
                    return Self.isBoundaryPrefixMatch(candidate: strippedGroup, prefix: lowerOther)
                        || Self.isBoundaryPrefixMatch(candidate: lowerFull, prefix: lowerOther)
                }
                if !claimedByOtherInstalled,
                   Self.matchesGroupContainer(
                    entryName: lowerFull,
                    bundleID: bid,
                    teamID: teamID,
                    applicationGroups: applicationGroups,
                    allowApple: allowApple
                   ),
                   !Self.isClaimedByLongerInstalledBundleID(strippedGroup, ownBundleID: bid, allInstalledBundleIDs: allInstalledBundleIDs) {
                    return ("App Group match", true)
                }
            }

            // Preferences/ByHost: `<bundleID>.<UUID>.plist`
            if entry.category == .preferences {
                let noUUIDStem = InstalledAppInventory.stripUUIDSuffix(lowerStem)
                let prefMatches = allowPrefix
                    ? lowerFull.hasPrefix(bid + ".")
                    : (lowerStem == bid || noUUIDStem == bid)
                if prefMatches,
                   !Self.isClaimedByLongerInstalledBundleID(lowerStem, ownBundleID: bid, allInstalledBundleIDs: allInstalledBundleIDs) {
                    return ("Preference match", true)
                }
            }
        }

        // 2b. Unique repeated-token 2-segment prefix (e.g. `com.docker.docker` -> `com.docker.install`)
        //     restricted to non-launchd, non-group-container entries when signed with a verified TeamID
        //     and no other installed app shares that 2-segment prefix.
        if let prefix2 = uniqueRepeatedVendorPrefix,
           entry.category != .launchAgents,
           entry.category != .launchDaemons,
           entry.category != .groupContainers {
            let stripped = InstalledAppInventory.stripContainerPrefixes(lowerStem)
            if (stripped == prefix2 || stripped.hasPrefix(prefix2 + ".")),
               let primaryBID = bundleID,
               !Self.isClaimedByLongerInstalledBundleID(stripped, ownBundleID: primaryBID, allInstalledBundleIDs: allInstalledBundleIDs) {
                return ("Vendor bundle prefix match", true)
            }
        }

        // 3. Name matching (strictly bounded, length >= 4, never matches LaunchAgents/Daemons, Group Containers,
        //    system/TCC ignore names, reverse-DNS names, or entries belonging to installed/protected bundle IDs).
        if entry.category == .launchAgents || entry.category == .launchDaemons || entry.category == .groupContainers {
            return nil
        }
        let strippedLowerStem = InstalledAppInventory.stripContainerPrefixes(lowerStem)
        let strippedLowerFull = InstalledAppInventory.stripContainerPrefixes(lowerFull)
        let noUUIDLowerStem = InstalledAppInventory.stripUUIDSuffix(lowerStem)

        if SafetyGuard.leftoverSafeIgnoreNames.contains(lowerStem)
            || SafetyGuard.leftoverSafeIgnoreNames.contains(lowerFull)
            || SafetyGuard.leftoverSafeIgnoreNames.contains(noUUIDLowerStem) {
            return nil
        }
        if LeftoverScanner.looksLikeReverseDNSBundleID(strippedLowerStem)
            || LeftoverScanner.looksLikeReverseDNSBundleID(strippedLowerFull) {
            return nil
        }
        if safetyGuard.matchesProtectedBundleID(lowerStem)
            || safetyGuard.matchesProtectedBundleID(lowerFull)
            || safetyGuard.matchesProtectedBundleID(noUUIDLowerStem) {
            return nil
        }
        if !allInstalledBundleIDs.isEmpty {
            let ownLower = bundleID?.lowercased()
            for otherID in allInstalledBundleIDs {
                let lowerOther = otherID.lowercased()
                if lowerOther == ownLower { continue }
                if Self.isBoundaryPrefixMatch(candidate: strippedLowerStem, prefix: lowerOther)
                    || Self.isBoundaryPrefixMatch(candidate: strippedLowerFull, prefix: lowerOther)
                    || Self.isBoundaryPrefixMatch(candidate: lowerStem, prefix: lowerOther) {
                    return nil
                }
            }
        }

        for name in nameCandidates {
            if lowerStem == name || lowerFull == name {
                return ("App name match", true)
            }
            if entry.isInsideVendorFolder && Self.isBoundaryPrefixMatch(candidate: lowerStem, prefix: name) {
                return ("Vendor subfolder match", true)
            }
            if entry.category == .logs,
               (lowerFull.hasPrefix(name + "-") || lowerFull.hasPrefix(name + "_")) {
                return ("Log / crash report match", true)
            }
        }

        return nil
    }

    public static func nameCandidates(for app: AppItem) -> [String] {
        var rawNames: [String] = [app.name]
        if app.localizedName != app.name {
            rawNames.append(app.localizedName)
        }
        if app.teamIdentifier?.isEmpty == false {
            rawNames.append(contentsOf: app.embeddedAppNames)
        }
        if let exec = app.executableName {
            let execTrimmed = exec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !genericExecutableNames.contains(execTrimmed),
               isExecutableNameRelated(execTrimmed, toAppNames: [app.name, app.localizedName]) {
                rawNames.append(exec)
            }
        }

        var results: [String] = []
        var seen = Set<String>()

        for raw in rawNames {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard trimmed.count >= 4 else { continue }
            guard !Self.genericStopWords.contains(trimmed) else { continue }
            guard !SafetyGuard.sharedVendorFolderNames.contains(trimmed) else { continue }
            guard !SafetyGuard.leftoverSafeIgnoreNames.contains(trimmed) else { continue }
            guard !LeftoverScanner.looksLikeReverseDNSBundleID(trimmed) else { continue }
            if !seen.contains(trimmed) {
                seen.insert(trimmed)
                results.append(trimmed)
            }
            let compact = trimmed.replacingOccurrences(of: " ", with: "")
            if compact != trimmed, compact.count >= 6,
               !Self.genericStopWords.contains(compact),
               !SafetyGuard.sharedVendorFolderNames.contains(compact),
               !SafetyGuard.leftoverSafeIgnoreNames.contains(compact),
               !LeftoverScanner.looksLikeReverseDNSBundleID(compact),
               !seen.contains(compact) {
                seen.insert(compact)
                results.append(compact)
            }
        }
        return results
    }

    /// True if `CFBundleExecutable` matches or extends the visible bundle name
    /// (prevents unsigned or arbitrarily signed apps from spoofing unrelated executable names like `Chrome` or `MobileSync`).
    private static func isExecutableNameRelated(_ lowerExec: String, toAppNames names: [String]) -> Bool {
        let compactExec = InstalledAppInventory.compact(lowerExec)
        guard compactExec.count >= 4 else { return false }
        for name in names {
            let compactName = InstalledAppInventory.compact(name)
            guard compactName.count >= 4 else { continue }
            if compactExec == compactName || compactExec.hasPrefix(compactName) {
                return true
            }
        }
        return false
    }

    public static func isBoundaryPrefixMatch(candidate: String, prefix: String) -> Bool {
        guard candidate.hasPrefix(prefix) else { return false }
        if candidate.count == prefix.count { return true }
        let nextIndex = candidate.index(candidate.startIndex, offsetBy: prefix.count)
        let nextChar = candidate[nextIndex]
        return nextChar == "." || nextChar == "-" || nextChar == "_" || nextChar == " "
    }

    public static func matchesGroupContainer(
        entryName: String,
        bundleID: String,
        teamID: String?,
        applicationGroups: [String] = [],
        allowApple: Bool = false
    ) -> Bool {
        let lowerEntry = entryName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lowerBID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowerEntry.isEmpty, !lowerBID.isEmpty else { return false }

        let strippedEntry = InstalledAppInventory.stripContainerPrefixes(lowerEntry)
        if !allowApple {
            if SafetyGuard.isAppleGroupContainerName(lowerEntry)
                || strippedEntry == "com.apple" || strippedEntry.hasPrefix("com.apple.")
                || lowerBID == "com.apple" || lowerBID.hasPrefix("com.apple.") {
                return false
            }
        }

        let allowPrefix = allowsPrefixMatching(forBundleID: lowerBID)

        // 1. Verified `com.apple.security.application-groups` entitlement match (signed under `anchor apple generic`).
        let declaredGroups = Set(
            applicationGroups
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        if declaredGroups.contains(lowerEntry) {
            var hasTeamPrefix = false
            if let dotIdx = lowerEntry.firstIndex(of: ".") {
                let prefixToken = lowerEntry[..<dotIdx]
                if prefixToken.count == 10, prefixToken.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                    hasTeamPrefix = true
                    // If the group container carries a 10-char TeamID prefix, require it to match the app's verified TeamID.
                    if !allowApple {
                        guard let teamID, !teamID.isEmpty, teamID.lowercased() == String(prefixToken) else {
                            return false
                        }
                    }
                }
            }
            if !hasTeamPrefix {
                // Non-TeamID `group.*`/`groups.*` containers must ALSO match the app's own bundle ID
                // (or its verified 2-segment non-shared parent root such as `group.com.docker` for
                // `com.docker.docker`) so an arbitrary Apple Development signer (`com.evil.spoof`)
                // cannot claim unrelated third-party `group.*` containers via self-declared entitlements.
                let exactOrChildMatch = matchesBundleIdentifier(
                    candidate: strippedEntry,
                    bundleID: lowerBID,
                    allowPrefix: allowPrefix
                )
                let verifiedParentGroupMatch: Bool = {
                    guard let teamID, !teamID.isEmpty else { return false }
                    let parts = strippedEntry.split(separator: ".", omittingEmptySubsequences: false)
                    guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
                    if parts.count == 2 {
                        let vendor = String(parts[1])
                        guard vendor != "apple", !SafetyGuard.sharedVendorFolderNames.contains(vendor) else {
                            return false
                        }
                    }
                    return lowerBID.hasPrefix(strippedEntry + ".")
                }()
                guard exactOrChildMatch || verifiedParentGroupMatch else {
                    return false
                }
            }
            return true
        }

        // 2. Strict verified `<TeamID>.<bundleID>` / `<TeamID>.group(s).<bundleID>` match when TeamID is verified.
        //    Never unconditionally match `"group." + lowerBID` or wildcard `<any-10-char>.<bundleID>`.
        guard let teamID, !teamID.isEmpty else {
            return false
        }
        let lowerTeam = teamID.lowercased()
        return matchesBundleIdentifier(candidate: lowerEntry, bundleID: "\(lowerTeam).\(lowerBID)", allowPrefix: allowPrefix)
            || matchesBundleIdentifier(candidate: lowerEntry, bundleID: "\(lowerTeam).group.\(lowerBID)", allowPrefix: allowPrefix)
            || matchesBundleIdentifier(candidate: lowerEntry, bundleID: "\(lowerTeam).groups.\(lowerBID)", allowPrefix: allowPrefix)
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

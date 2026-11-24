import AppKit
import CoreServices
import Darwin
import Foundation
import Security

public struct CodeSigningIdentity: Sendable, Equatable {
    public let teamIdentifier: String?
    public let signingIdentifier: String
    public let isAppleSigned: Bool

    public init(teamIdentifier: String?, signingIdentifier: String, isAppleSigned: Bool) {
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.isAppleSigned = isAppleSigned
    }

    /// True if a running process carrying `self` cryptographically belongs to the same signing
    /// identity as `appIdentity`.
    public func matchesAppIdentity(_ appIdentity: CodeSigningIdentity) -> Bool {
        if isAppleSigned != appIdentity.isAppleSigned {
            return false
        }
        if isAppleSigned {
            // Apple OS / Mac App Store apps must match sealed signing identifier too, so
            // uninstalling Pages never terminates Keynote despite sharing the iWork TeamID.
            guard !signingIdentifier.isEmpty,
                  signingIdentifier.caseInsensitiveCompare(appIdentity.signingIdentifier) == .orderedSame else {
                return false
            }
            if let appTeam = appIdentity.teamIdentifier, !appTeam.isEmpty {
                return teamIdentifier?.caseInsensitiveCompare(appTeam) == .orderedSame
            }
            return true
        }
        guard let appTeam = appIdentity.teamIdentifier, !appTeam.isEmpty,
              let procTeam = teamIdentifier, !procTeam.isEmpty else {
            return false
        }
        return procTeam.caseInsensitiveCompare(appTeam) == .orderedSame
    }
}

public struct RunningProcessMatch: Sendable, Equatable {
    public let bundleID: String
    public let name: String
    public let pid: pid_t

    public init(bundleID: String, name: String, pid: pid_t) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }
}

public struct AppScanner: Sendable {
    public let searchRoots: [URL]
    public let includeUtilities: Bool
    public let showSystemApps: Bool
    public let safetyGuard: SafetyGuard

    public init(
        searchRoots: [URL]? = nil,
        includeUtilities: Bool = false,
        showSystemApps: Bool = false,
        safetyGuard: SafetyGuard = SafetyGuard()
    ) {
        if let searchRoots {
            self.searchRoots = searchRoots
        } else {
            let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
            var roots = [
                URL(fileURLWithPath: "/Applications"),
                userApps,
            ]
            if showSystemApps {
                roots.append(URL(fileURLWithPath: "/System/Applications"))
            }
            self.searchRoots = roots
        }
        self.includeUtilities = includeUtilities
        self.showSystemApps = showSystemApps
        self.safetyGuard = safetyGuard
    }

    /// Safely removes a trailing `.app` suffix (case-insensitive) without corrupting interior occurrences.
    public static func strippingAppExtension(_ name: String) -> String {
        if name.lowercased().hasSuffix(".app") {
            return String(name.dropLast(4))
        }
        return name
    }

    /// Returns bundle IDs of currently running macOS apps.
    public static func runningBundleIDs() -> Set<String> {
        var ids = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier?.lowercased() {
                ids.insert(bid)
            }
        }
        return ids
    }

    /// Returns running processes matching any target bundle ID OR whose `bundleURL` / `executableURL`
    /// lives inside any target `.app` bundle (catches embedded MenuBar / Helper processes).
    ///
    /// When `bundleURLs` is non-empty, any match made solely by `bundleID` (outside `bundleURLs`) MUST
    /// pass cryptographic `SecCodeCopyGuestWithAttributes` (`kSecGuestAttributePid`) signing-identity
    /// verification against the uninstalling `.app` bundle(s).
    public static func runningProcesses(
        matchingBundleIDs bundleIDs: [String],
        bundleURLs: [URL]
    ) -> [RunningProcessMatch] {
        let lowerIDs = Set(bundleIDs.map { $0.lowercased() }.filter {
            !$0.isEmpty && !$0.hasPrefix("unknown.") && $0 != "com.apple"
        })
        guard !lowerIDs.isEmpty || !bundleURLs.isEmpty else { return [] }

        let cachedAppIdentities: [CodeSigningIdentity]? = bundleURLs.isEmpty
            ? nil
            : bundleURLs.compactMap { extractAppSigningIdentity(at: $0) }

        var matches: [RunningProcessMatch] = []
        var seenPIDs = Set<pid_t>()

        for proc in NSWorkspace.shared.runningApplications where !proc.isTerminated {
            let bid = proc.bundleIdentifier ?? ""
            let matched: Bool
            if bundleURLs.isEmpty {
                matched = !bid.isEmpty && lowerIDs.contains(bid.lowercased())
            } else {
                matched = isProcessAuthorizedForAppMatch(
                    pid: proc.processIdentifier,
                    processBundleID: proc.bundleIdentifier,
                    processBundleURL: proc.bundleURL,
                    processExecutableURL: proc.executableURL,
                    targetBundleIDs: lowerIDs,
                    targetAppURLs: bundleURLs,
                    cachedAppIdentities: cachedAppIdentities
                )
            }

            if matched, seenPIDs.insert(proc.processIdentifier).inserted {
                matches.append(RunningProcessMatch(
                    bundleID: bid,
                    name: proc.localizedName ?? bid,
                    pid: proc.processIdentifier
                ))
            }
        }
        return matches
    }

    /// True if `url` itself is a symbolic link (`lstat` without following links).
    private static func isSymbolicLink(at url: URL) -> Bool {
        var st = stat()
        guard lstat(url.standardizedFileURL.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// True if `processURL` equals or resides inside any non-symlink URL in `targetAppURLs`
    /// (standardized, symlink-resolved, and POSIX `realpath(3)` checked case- and Unicode-normalization-insensitively).
    /// Symlink `.app` entries in `targetAppURLs` are always skipped so removing a symlink never terminates its target.
    public static func isProcessURL(_ processURL: URL?, insideAnyOf targetAppURLs: [URL]) -> Bool {
        guard let processURL, !targetAppURLs.isEmpty else { return false }
        func pathVariants(_ url: URL) -> [String] {
            let std = url.standardizedFileURL.path
            let res = url.resolvingSymlinksInPath().standardizedFileURL.path
            let real = SafetyGuard.posixRealpath(std)
            return Array(Set([std, res, real].compactMap {
                $0?.precomposedStringWithCanonicalMapping.lowercased()
            }))
        }
        let procVariants = pathVariants(processURL)
        for appURL in targetAppURLs {
            guard !isSymbolicLink(at: appURL) else { continue }
            let baseVariants = pathVariants(appURL)
            for p in procVariants {
                for base in baseVariants {
                    if p == base || p.hasPrefix(base + "/") {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Authorizes whether a running PID belongs to the uninstalling `.app` bundle(s):
    /// 1. Always authorizes if the process's `bundleURL` or `executableURL` resides inside `targetAppURLs`.
    /// 2. Otherwise, if `processBundleID` is in `targetBundleIDs`, requires BOTH the uninstalling `.app`
    ///    and the live running PID (via `SecCodeCopyGuestWithAttributes` + `kSecGuestAttributePid`) to carry
    ///    valid `anchor apple generic` signatures whose verified `CodeSigningIdentity` matches.
    public static func isProcessAuthorizedForAppMatch(
        pid: pid_t,
        processBundleID: String?,
        processBundleURL: URL?,
        processExecutableURL: URL?,
        targetBundleIDs: Set<String>,
        targetAppURLs: [URL],
        cachedAppIdentities: [CodeSigningIdentity]? = nil,
        processIdentityOverride: CodeSigningIdentity? = nil
    ) -> Bool {
        guard pid > 0, pid != getpid() else { return false }
        if isProcessURL(processBundleURL, insideAnyOf: targetAppURLs)
            || isProcessURL(processExecutableURL, insideAnyOf: targetAppURLs) {
            return true
        }
        guard !targetAppURLs.isEmpty,
              let procBID = processBundleID?.lowercased(),
              !procBID.isEmpty,
              targetBundleIDs.contains(procBID) else {
            return false
        }
        let appIdentities = cachedAppIdentities ?? targetAppURLs.compactMap { extractAppSigningIdentity(at: $0) }
        guard !appIdentities.isEmpty else {
            return false
        }
        guard let procIdentity = processIdentityOverride ?? extractProcessSigningIdentity(pid: pid) else {
            return false
        }
        return appIdentities.contains { procIdentity.matchesAppIdentity($0) }
    }

    public func scanApplications(runningIDs: Set<String>? = nil) -> [AppItem] {
        let activeRunning = runningIDs ?? Self.runningBundleIDs()
        let runningBundlePaths = Self.runningAppBundlePaths()
        var discoveredURLs: [URL] = []
        var seenPaths = Set<String>()
        let fm = FileManager.default

        func collectApps(in dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                return
            }

            for item in items {
                let path = item.standardizedFileURL.path
                if item.pathExtension.lowercased() == "app" {
                    if !seenPaths.contains(path) {
                        seenPaths.insert(path)
                        discoveredURLs.append(item)
                    }
                    continue
                }

                if depth == 0 {
                    let isUtilities = item.lastPathComponent == "Utilities"
                    if isUtilities && !includeUtilities {
                        continue
                    }
                    let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
                    if vals?.isDirectory == true, vals?.isPackage != true, vals?.isSymbolicLink != true {
                        collectApps(in: item, depth: 1)
                    }
                }
            }
        }

        for root in searchRoots {
            collectApps(in: root, depth: 0)
        }

        var apps: [AppItem] = []
        apps.reserveCapacity(discoveredURLs.count)

        for appURL in discoveredURLs {
            guard let item = inspectApp(
                at: appURL,
                runningIDs: activeRunning,
                runningBundlePaths: runningBundlePaths
            ) else {
                continue
            }
            if item.isSystemProtected && !showSystemApps {
                continue
            }
            apps.append(item)
        }

        return apps.sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
    }

    /// Inspects any single `.app` bundle (used both by scanner and Drag & Drop quick uninstall).
    /// Returns `nil` for MacSweep itself to prevent self-uninstall/self-reset via drag & drop.
    public func inspectApp(
        at appURL: URL,
        runningIDs: Set<String>? = nil,
        runningBundlePaths: [String]? = nil
    ) -> AppItem? {
        let fm = FileManager.default
        guard appURL.isFileURL,
              !appURL.path.contains("\0"),
              appURL.pathExtension.lowercased() == "app",
              fm.fileExists(atPath: appURL.path) else {
            return nil
        }

        let rawName = appURL.deletingPathExtension().lastPathComponent
        let bundle = Bundle(url: appURL)
        let info = bundle?.infoDictionary ?? [:]
        let localizedInfo = bundle?.localizedInfoDictionary ?? [:]

        let bundleID = (info["CFBundleIdentifier"] as? String)
            ?? "unknown.\(rawName.lowercased().replacingOccurrences(of: " ", with: "-"))"

        // Block MacSweep itself everywhere (both normal scan and Drag & Drop).
        if safetyGuard.isSelfApp(bundleID: bundleID, url: appURL) {
            return nil
        }

        let activeRunning = runningIDs ?? Self.runningBundleIDs()
        let activePaths = runningBundlePaths ?? Self.runningAppBundlePaths()
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? ""
        let rawExecutable = (info["CFBundleExecutable"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let executableName: String? = {
            guard let exec = rawExecutable,
                  !exec.isEmpty,
                  exec != ".",
                  exec != "..",
                  !exec.contains("/"),
                  !exec.contains("\0") else {
                return nil
            }
            let macOSDir = appURL.appendingPathComponent("Contents/MacOS")
            var dirStat = stat()
            guard lstat(macOSDir.path, &dirStat) == 0, (dirStat.st_mode & S_IFMT) == S_IFDIR else {
                return nil
            }
            let execURL = macOSDir.appendingPathComponent(exec)
            var execStat = stat()
            guard lstat(execURL.path, &execStat) == 0, (execStat.st_mode & S_IFMT) == S_IFREG else {
                return nil
            }
            return exec
        }()

        let displayName = (localizedInfo["CFBundleDisplayName"] as? String)
            ?? (localizedInfo["CFBundleName"] as? String)
            ?? (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? rawName

        let localizedViaFS = Self.strippingAppExtension(fm.displayName(atPath: appURL.path))
        let finalLocalizedName = !localizedViaFS.isEmpty ? localizedViaFS : displayName

        let signing = Self.extractDetailedSigningMetadata(at: appURL)
        let teamID = signing.identity?.teamIdentifier
        let applicationGroups = signing.applicationGroups
        let architectures = Self.extractArchitectures(from: bundle)
        let minimumSystemVersion = (info["LSMinimumSystemVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let embedded = Self.extractVerifiedEmbeddedBundles(at: appURL, parentTeamID: teamID, parentBundleID: bundleID)
        let helperLabels = Self.extractPrivilegedHelperLabels(from: info, teamID: teamID)
        let expectedCanonicalParent = PrivilegedExecutor.canonicalParentPath(forTargetURL: appURL)
        let resVals = try? appURL.resourceValues(forKeys: [.contentModificationDateKey, .contentAccessDateKey])
        let spotlightLastUsed = Self.spotlightLastUsedDate(for: appURL)
        let lastUsed = spotlightLastUsed ?? resVals?.contentAccessDate
        let modified = resVals?.contentModificationDate

        let isSystemProtected = safetyGuard.isSystemProtectedApp(at: appURL)
        let isAppleAppStoreApp = !isSystemProtected
            && safetyGuard.isAppleBundleID(bundleID)
            && Self.hasValidAppleSignature(at: appURL, expectedBundleID: bundleID)
        let isUserProtected = safetyGuard.isUserProtected(bundleID: bundleID, url: appURL)
        let requiresAdmin = safetyGuard.requiresAdmin(for: appURL)
        let isSymlinkBundle = Self.isSymbolicLink(at: appURL)
        let stdAppPath = appURL.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        let lowerBID = bundleID.lowercased()
        let matchedByPath = !isSymlinkBundle
            && activePaths.contains { $0 == stdAppPath || $0.hasPrefix(stdAppPath + "/") }
        let canMatchRunningByID = !isSymlinkBundle
            && (isAppleAppStoreApp || (teamID != nil && !lowerBID.hasPrefix("com.apple.") && lowerBID != "com.apple"))
            && !lowerBID.hasPrefix("unknown.")
            && Self.isInStandardApplicationsRoot(appURL)
        let isRunning: Bool
        if matchedByPath {
            isRunning = true
        } else if canMatchRunningByID && activeRunning.contains(lowerBID) {
            isRunning = !Self.runningProcesses(matchingBundleIDs: [bundleID], bundleURLs: [appURL]).isEmpty
        } else {
            isRunning = false
        }

        let resolvedDeveloper = signing.developerName
            ?? Self.fallbackDeveloperName(from: info, isApple: isSystemProtected || isAppleAppStoreApp)

        return AppItem(
            url: appURL,
            name: rawName,
            localizedName: finalLocalizedName,
            bundleID: bundleID,
            version: version,
            executableName: executableName,
            teamIdentifier: teamID,
            developerName: resolvedDeveloper,
            verificationStatus: signing.verificationStatus,
            architectures: architectures,
            minimumSystemVersion: (minimumSystemVersion?.isEmpty == false) ? minimumSystemVersion : nil,
            applicationGroups: applicationGroups,
            embeddedBundleIDs: embedded.bundleIDs,
            embeddedAppNames: embedded.appNames,
            privilegedHelperLabels: helperLabels,
            expectedCanonicalParent: expectedCanonicalParent,
            lastUsedDate: lastUsed,
            modifiedDate: modified,
            bundleSize: nil,
            serviceFiles: [],
            matchedPackageIDs: [],
            isRunning: isRunning,
            isProtected: isUserProtected,
            isSystemProtected: isSystemProtected,
            isAppleAppStoreApp: isAppleAppStoreApp,
            requiresAdmin: requiresAdmin,
            isChecked: false,
            scanState: .idle
        )
    }

    /// True when `appURL` resides inside a standard macOS applications root (`/Applications`,
    /// `~/Applications`, or `/System/Applications`), as opposed to an arbitrary dropped bundle.
    public static func isInStandardApplicationsRoot(
        _ appURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            homeDirectory.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
        ]
        let normApp = appURL.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        let normRes = appURL.resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        for root in roots {
            let normRoot = root.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
            let normRootRes = root.resolvingSymlinksInPath().standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
            if (normApp.hasPrefix(normRoot + "/") && normRes.hasPrefix(normRootRes + "/")) {
                return true
            }
        }
        return false
    }

    /// Returns `app.bundleID` only when it is safe to match/terminate running processes by bundle ID.
    /// Returns `nil` (forcing strict `bundleURL`-only process matching) when the app shares a bundle ID
    /// with another installed app, resides outside standard application roots (e.g. dropped bundle),
    /// carries an unmatchable bundle ID, or claims `com.apple.*` without a valid Apple signature.
    public static func safeProcessMatchBundleID(
        for app: AppItem,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        guard !app.sharesBundleIDWithOtherApp,
              !isSymbolicLink(at: app.url),
              isInStandardApplicationsRoot(app.url, homeDirectory: homeDirectory) else {
            return nil
        }
        let lower = app.bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty,
              !lower.hasPrefix("unknown."),
              lower != "com.apple",
              ServiceFileMatcher.isMatchableBundleID(lower, allowApple: app.isAppleAppStoreApp) else {
            return nil
        }
        if lower.hasPrefix("com.apple.") && !app.isAppleAppStoreApp {
            return nil
        }
        return app.bundleID
    }

    private static func runningAppBundlePaths() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap {
            $0.bundleURL?.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        }
    }

    private static func spotlightLastUsedDate(for url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else {
            return nil
        }
        guard let value = MDItemCopyAttribute(item, kMDItemLastUsedDate) else {
            return nil
        }
        return value as? Date
    }

    private static let appleGenericRequirementString = "anchor apple generic"
    private static let appleOSOnlyRequirementString = "anchor apple"
    private static let appleAppStoreRequirementString = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9]"
    private static let appleDeveloperIDRequirementString = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"
    private static let appleOfficialRequirementString = "anchor apple or (anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9])"

    public struct AppSigningDetails: Sendable {
        public let identity: CodeSigningIdentity?
        public let applicationGroups: [String]
        public let developerName: String?
        public let verificationStatus: AppVerificationStatus
    }

    private static func makeRequirement(_ text: String) -> SecRequirement? {
        var req: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(), &req) == errSecSuccess else {
            return nil
        }
        return req
    }

    /// Verifies that an `.app` bundle carries a valid Apple OS or Mac App Store code signature
    /// whose cryptographically sealed `kSecCodeInfoIdentifier` matches `expectedBundleID`.
    /// Prevents unsigned/spoofed `.app` bundles from bypassing `com.apple.` filtering via `Info.plist`.
    public static func hasValidAppleSignature(at appURL: URL, expectedBundleID: String) -> Bool {
        guard !isSymbolicLink(at: appURL) else { return false }
        let lowerExpected = expectedBundleID.lowercased()
        guard lowerExpected.hasPrefix("com.apple.") else { return false }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode,
              let req = makeRequirement(appleOfficialRequirementString) else {
            return false
        }

        let checkFlags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        guard SecStaticCodeCheckValidity(code, checkFlags, req) == errSecSuccess else {
            return false
        }

        var infoRef: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, infoFlags, &infoRef) == errSecSuccess,
              let dict = infoRef as? [String: Any],
              let signedID = dict[kSecCodeInfoIdentifier as String] as? String else {
            return false
        }
        return signedID.lowercased() == lowerExpected
    }

    /// Extracts cryptographically verified signing identity, `com.apple.security.application-groups`,
    /// human-readable developer name, and verification status from an `.app` passing `anchor apple generic`.
    public static func extractDetailedSigningMetadata(at appURL: URL) -> AppSigningDetails {
        guard !isSymbolicLink(at: appURL) else {
            return AppSigningDetails(identity: nil, applicationGroups: [], developerName: nil, verificationStatus: .adHocOrUnsigned)
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode,
              let genericReq = makeRequirement(appleGenericRequirementString) else {
            return AppSigningDetails(identity: nil, applicationGroups: [], developerName: nil, verificationStatus: .adHocOrUnsigned)
        }
        let checkFlags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        guard SecStaticCodeCheckValidity(code, checkFlags, genericReq) == errSecSuccess else {
            return AppSigningDetails(identity: nil, applicationGroups: [], developerName: nil, verificationStatus: .adHocOrUnsigned)
        }
        let isAppleOS: Bool = {
            guard let req = makeRequirement(appleOSOnlyRequirementString) else { return false }
            return SecStaticCodeCheckValidity(code, checkFlags, req) == errSecSuccess
        }()
        let isAppStore: Bool = {
            guard let req = makeRequirement(appleAppStoreRequirementString) else { return false }
            return SecStaticCodeCheckValidity(code, checkFlags, req) == errSecSuccess
        }()
        let isDeveloperID: Bool = {
            guard let req = makeRequirement(appleDeveloperIDRequirementString) else { return false }
            return SecStaticCodeCheckValidity(code, checkFlags, req) == errSecSuccess
        }()
        let isAppleSigned = isAppleOS || isAppStore

        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &infoRef) == errSecSuccess,
              let dict = infoRef as? [String: Any] else {
            return AppSigningDetails(identity: nil, applicationGroups: [], developerName: nil, verificationStatus: .adHocOrUnsigned)
        }
        let rawTeam = (dict[kSecCodeInfoTeamIdentifier as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let team = (rawTeam?.isEmpty == false) ? rawTeam : nil
        let signedID = (dict[kSecCodeInfoIdentifier as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        var groups: [String] = []
        if let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            var seen = Set<String>()
            for key in ["com.apple.security.application-groups", "com.apple.security.restricted-application-groups"] {
                if let entries = entitlements[key] as? [String] {
                    for entry in entries {
                        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                        let lower = trimmed.lowercased()
                        if !lower.isEmpty, seen.insert(lower).inserted {
                            groups.append(trimmed)
                        }
                    }
                }
            }
        }

        let developerName = Self.extractDeveloperName(from: dict, isAppleOS: isAppleOS)
        let codeFlags = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let hasHardenedRuntime = (codeFlags & SecCodeSignatureFlags.runtime.rawValue) != 0
        let hasTimestamp = dict[kSecCodeInfoTimestamp as String] != nil
        let hasStapledTicket = FileManager.default.fileExists(
            atPath: appURL.appendingPathComponent("Contents/CodeResources").path
        ) && (
            dict["notarization-date"] != nil
                || FileManager.default.fileExists(
                    atPath: appURL.appendingPathComponent("Contents/CodeSignature/CodeTicket").path
                )
        )
        let hasMASReceipt = FileManager.default.fileExists(
            atPath: appURL.appendingPathComponent("Contents/_MASReceipt/receipt").path
        )

        let verificationStatus: AppVerificationStatus
        if isAppleOS {
            verificationStatus = .appleSystem
        } else if isAppStore || hasMASReceipt {
            verificationStatus = .appStore
        } else if isDeveloperID && (hasStapledTicket || (hasHardenedRuntime && hasTimestamp)) {
            verificationStatus = .notarized
        } else {
            verificationStatus = .developerSigned
        }

        let identity = CodeSigningIdentity(
            teamIdentifier: team,
            signingIdentifier: signedID,
            isAppleSigned: isAppleSigned
        )
        return AppSigningDetails(
            identity: identity,
            applicationGroups: groups,
            developerName: developerName,
            verificationStatus: verificationStatus
        )
    }

    /// Extracts cryptographically verified signing identity and `com.apple.security.application-groups`
    /// entitlements from an `.app` bundle passing `anchor apple generic` (rejects unsigned, ad-hoc, and
    /// arbitrary self-signed certificates).
    public static func extractSigningMetadata(
        at appURL: URL
    ) -> (identity: CodeSigningIdentity?, applicationGroups: [String]) {
        let details = extractDetailedSigningMetadata(at: appURL)
        return (details.identity, details.applicationGroups)
    }

    private static func extractDeveloperName(from signingDict: [String: Any], isAppleOS: Bool) -> String? {
        if isAppleOS {
            return "Apple Inc."
        }
        guard let certs = signingDict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first,
              let rawSummary = SecCertificateCopySubjectSummary(leaf) as String? else {
            return nil
        }
        let rawSummaryTrimmed = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawSummaryTrimmed == "Apple Mac OS Application Signing"
            || rawSummaryTrimmed == "Apple Mac OS Application Signing (Mac App Store)" {
            return nil
        }
        var cleaned = rawSummaryTrimmed
        let prefixes = [
            "Developer ID Application: ",
            "Developer ID Installer: ",
            "3rd Party Mac Developer Application: ",
            "Apple Distribution: ",
            "Apple Development: ",
            "Mac Developer: ",
        ]
        for prefix in prefixes where cleaned.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count))
            break
        }
        // Strip trailing ` (TEAMID)` suffix such as `Docker Inc (9BNSXJN65R)`.
        if cleaned.hasSuffix(")"),
           let openIdx = cleaned.lastIndex(of: "("),
           openIdx > cleaned.startIndex {
            let teamToken = cleaned[cleaned.index(after: openIdx)..<cleaned.index(before: cleaned.endIndex)]
            if teamToken.count == 10, teamToken.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                cleaned = String(cleaned[..<openIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func fallbackDeveloperName(from info: [String: Any], isApple: Bool) -> String? {
        if isApple { return "Apple Inc." }
        if let copyright = (info["NSHumanReadableCopyright"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !copyright.isEmpty {
            var cleaned = copyright
            // Clean leading "Copyright © 2024 " boilerplate for concise display
            if let range = cleaned.range(
                of: #"^(?:copyright\s*)?(?:©|\(c\))?\s*(?:\d{4}(?:\s*[-–—]\s*\d{4})?\s*)?(?:by\s+)?"#,
                options: [.regularExpression, .caseInsensitive]
            ) {
                let stripped = String(cleaned[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty {
                    cleaned = stripped
                }
            }
            if let dotRange = cleaned.range(of: "All rights reserved", options: .caseInsensitive) {
                cleaned = String(cleaned[..<dotRange.lowerBound])
                    .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;·-")))
            }
            if !cleaned.isEmpty, cleaned.count <= 64 {
                return cleaned
            }
        }
        return nil
    }

    private static func extractArchitectures(from bundle: Bundle?) -> [String] {
        guard let rawArchs = bundle?.executableArchitectures else { return [] }
        var out: [String] = []
        for num in rawArchs {
            switch num.intValue {
            case NSBundleExecutableArchitectureARM64:
                if !out.contains("arm64") { out.append("arm64") }
            case NSBundleExecutableArchitectureX86_64:
                if !out.contains("x86_64") { out.append("x86_64") }
            default:
                break
            }
        }
        return out
    }

    /// Scans verified embedded `.app` sub-bundles (e.g. `Docker Desktop.app`, `DockerHelper.app`)
    /// strictly requiring the same cryptographically verified `teamIdentifier` as the parent `.app`,
    /// preventing unsigned or spoofed bundles from injecting unrelated bundle IDs or names.
    public static func extractVerifiedEmbeddedBundles(
        at appURL: URL,
        parentTeamID: String?,
        parentBundleID: String
    ) -> (bundleIDs: [String], appNames: [String]) {
        guard !isSymbolicLink(at: appURL),
              let team = parentTeamID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !team.isEmpty else {
            return ([], [])
        }
        let lowerTeam = team.lowercased()
        let lowerParentBID = parentBundleID.lowercased()
        let fm = FileManager.default
        let searchRelDirs = [
            "Contents/MacOS",
            "Contents/Library/LoginItems",
            "Contents/Library/SecretsEngine",
            "Contents/Helpers",
        ]

        var bundleIDs: [String] = []
        var appNames: [String] = []
        var seenIDs = Set<String>([lowerParentBID])
        var seenNames = Set<String>()

        for rel in searchRelDirs {
            let dirURL = appURL.appendingPathComponent(rel)
            guard !isSymbolicLink(at: dirURL),
                  let items = try? fm.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: [.isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }
            for child in items where child.pathExtension.lowercased() == "app" {
                guard !isSymbolicLink(at: child) else { continue }
                guard let childTeam = extractTeamIdentifier(at: child)?.lowercased(),
                      childTeam == lowerTeam else {
                    continue
                }
                let childBundle = Bundle(url: child)
                let childInfo = childBundle?.infoDictionary ?? [:]
                if let bid = (childInfo["CFBundleIdentifier"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !bid.isEmpty {
                    let lowerBID = bid.lowercased()
                    if !lowerBID.hasPrefix("com.apple."), lowerBID != "com.apple",
                       seenIDs.insert(lowerBID).inserted {
                        bundleIDs.append(bid)
                    }
                }
                let rawStem = child.deletingPathExtension().lastPathComponent
                let candidateNames = [
                    childInfo["CFBundleDisplayName"] as? String,
                    childInfo["CFBundleName"] as? String,
                    rawStem,
                ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                for name in candidateNames where !name.isEmpty {
                    let lower = name.lowercased()
                    if seenNames.insert(lower).inserted {
                        appNames.append(name)
                    }
                }
            }
        }
        return (bundleIDs, appNames)
    }

    /// Reads privileged helper tool labels declared via `SMPrivilegedExecutables` in `Info.plist`,
    /// restricted to apps carrying a verified `anchor apple generic` Team Identifier.
    public static func extractPrivilegedHelperLabels(
        from info: [String: Any],
        teamID: String?
    ) -> [String] {
        guard let team = teamID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !team.isEmpty,
              let dict = info["SMPrivilegedExecutables"] as? [String: Any] else {
            return []
        }
        var labels: [String] = []
        var seen = Set<String>()
        for key in dict.keys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            guard !lower.isEmpty,
                  !lower.hasPrefix("com.apple."),
                  lower != "com.apple",
                  ServiceFileMatcher.isMatchableBundleID(lower, allowApple: false),
                  seen.insert(lower).inserted else {
                continue
            }
            labels.append(trimmed)
        }
        return labels
    }

    /// Lazy Gatekeeper assessment via `spctl --assess --type execute --verbose=4` for a single
    /// selected application bundle (keeps full-list scanning fast while showing authentic Notarized status).
    public static func assessGatekeeperStatus(at appURL: URL) -> AppVerificationStatus? {
        guard !isSymbolicLink(at: appURL) else { return nil }
        let res = ProcessRunner.run(
            executable: "/usr/sbin/spctl",
            arguments: ["--assess", "--type", "execute", "--verbose=4", appURL.path]
        )
        let combined = (res.stdout + "\n" + res.stderr).lowercased()
        if combined.contains("source=notarized developer id") {
            return .notarized
        }
        if combined.contains("source=mac app store") {
            return .appStore
        }
        if combined.contains("source=apple system") {
            return .appleSystem
        }
        if res.succeeded && combined.contains("accepted") {
            return .developerSigned
        }
        return nil
    }

    /// Reads the verified code-signing Team Identifier via Security framework (no subprocess overhead).
    /// Requires a cryptographically valid code signature satisfying `anchor apple generic`.
    public static func extractTeamIdentifier(at appURL: URL) -> String? {
        extractSigningMetadata(at: appURL).identity?.teamIdentifier
    }

    /// Reads verified `com.apple.security.application-groups` entitlements from an `.app` passing
    /// `anchor apple generic`.
    public static func extractApplicationGroups(at appURL: URL) -> [String] {
        extractSigningMetadata(at: appURL).applicationGroups
    }

    /// Reads the verified `CodeSigningIdentity` of an `.app` bundle passing `anchor apple generic`.
    public static func extractAppSigningIdentity(at appURL: URL) -> CodeSigningIdentity? {
        extractSigningMetadata(at: appURL).identity
    }

    /// Reads the verified `CodeSigningIdentity` of a live running PID via
    /// `SecCodeCopyGuestWithAttributes` (`kSecGuestAttributePid`) requiring `anchor apple generic`.
    public static func extractProcessSigningIdentity(pid: pid_t) -> CodeSigningIdentity? {
        guard pid > 0, let genericReq = makeRequirement(appleGenericRequirementString) else {
            return nil
        }
        let attrs = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, SecCSFlags(), &guestCode) == errSecSuccess,
              let code = guestCode else {
            return nil
        }
        guard SecCodeCheckValidity(code, SecCSFlags(), genericReq) == errSecSuccess else {
            return nil
        }
        let isAppleSigned: Bool = {
            guard let appleReq = makeRequirement(appleOfficialRequirementString) else { return false }
            return SecCodeCheckValidity(code, SecCSFlags(), appleReq) == errSecSuccess
        }()

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let sCode = staticCode else {
            return nil
        }
        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(sCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
              let dict = infoRef as? [String: Any] else {
            return nil
        }
        let rawTeam = (dict[kSecCodeInfoTeamIdentifier as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let team = (rawTeam?.isEmpty == false) ? rawTeam : nil
        let signedID = (dict[kSecCodeInfoIdentifier as String] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CodeSigningIdentity(
            teamIdentifier: team,
            signingIdentifier: signedID,
            isAppleSigned: isAppleSigned
        )
    }

    /// Collects bundle IDs and bundle paths of all apps across standard roots INCLUDING
    /// `/System/Applications`, `/System/Applications/Utilities`, `/Applications/Utilities`, and
    /// `/System/Library/CoreServices`, so dropped/spoofed `.app` bundles cannot claim system app data.
    public static func allInstalledBundleIdentities(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> (bundleIDs: Set<String>, bundlePathsByID: [String: Set<String>]) {
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            homeDirectory.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
        ]
        let fm = FileManager.default
        var ids = Set<String>()
        var pathsByID: [String: Set<String>] = [:]

        func scan(_ dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for item in items {
                if item.pathExtension.lowercased() == "app" {
                    let stdPath = item.standardizedFileURL.path
                    if let bid = (Bundle(url: item)?.infoDictionary?["CFBundleIdentifier"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                       !bid.isEmpty, !bid.hasPrefix("unknown.") {
                        ids.insert(bid)
                        pathsByID[bid, default: []].insert(stdPath)
                    }
                    continue
                }
                if depth == 0 {
                    let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
                    if vals?.isDirectory == true, vals?.isPackage != true, vals?.isSymbolicLink != true {
                        scan(item, depth: 1)
                    }
                }
            }
        }
        for root in roots { scan(root, depth: 0) }
        return (ids, pathsByID)
    }

    /// Extracts verified `application-groups` owners for non-`/System/` apps present in
    /// `bundlePathsByID` that were not already inspected in `excludingNormalizedPaths`
    /// (for example `/Applications/Utilities` when Utilities scanning is disabled).
    public static func supplementalApplicationGroupOwners(
        from bundlePathsByID: [String: Set<String>],
        excludingNormalizedPaths: Set<String>
    ) -> [String: Set<String>] {
        var owners: [String: Set<String>] = [:]
        var visited = excludingNormalizedPaths
        for paths in bundlePathsByID.values {
            for rawPath in paths {
                let normPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
                    .precomposedStringWithCanonicalMapping.lowercased()
                guard !normPath.hasPrefix("/system/"),
                      visited.insert(normPath).inserted else {
                    continue
                }
                let url = URL(fileURLWithPath: rawPath)
                let groups = extractApplicationGroups(at: url)
                for group in groups {
                    let lower = group.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if !lower.isEmpty {
                        owners[lower, default: []].insert(normPath)
                    }
                }
            }
        }
        return owners
    }
}

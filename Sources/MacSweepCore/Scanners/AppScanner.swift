import AppKit
import CoreServices
import Foundation
import Security

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

    /// Returns running processes matching any target bundle ID OR whose `bundleURL` lives inside
    /// any target `.app` bundle (catches embedded MenuBar / Helper processes).
    public static func runningProcesses(
        matchingBundleIDs bundleIDs: [String],
        bundleURLs: [URL]
    ) -> [RunningProcessMatch] {
        let lowerIDs = Set(bundleIDs.map { $0.lowercased() }.filter { !$0.isEmpty && !$0.hasPrefix("unknown.") })
        let appPaths = bundleURLs.map { $0.standardizedFileURL.path }
        guard !lowerIDs.isEmpty || !appPaths.isEmpty else { return [] }

        var matches: [RunningProcessMatch] = []
        var seenPIDs = Set<pid_t>()

        for proc in NSWorkspace.shared.runningApplications where !proc.isTerminated {
            let bid = proc.bundleIdentifier ?? ""
            let procPath = proc.bundleURL?.standardizedFileURL.path
            let matchedByID = !bid.isEmpty && lowerIDs.contains(bid.lowercased())
            let matchedByPath = procPath.map { p in
                appPaths.contains { base in p == base || p.hasPrefix(base + "/") }
            } ?? false

            if (matchedByID || matchedByPath), seenPIDs.insert(proc.processIdentifier).inserted {
                matches.append(RunningProcessMatch(
                    bundleID: bid,
                    name: proc.localizedName ?? bid,
                    pid: proc.processIdentifier
                ))
            }
        }
        return matches
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
        guard appURL.pathExtension.lowercased() == "app",
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
        let executableName = info["CFBundleExecutable"] as? String

        let displayName = (localizedInfo["CFBundleDisplayName"] as? String)
            ?? (localizedInfo["CFBundleName"] as? String)
            ?? (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? rawName

        let localizedViaFS = Self.strippingAppExtension(fm.displayName(atPath: appURL.path))
        let finalLocalizedName = !localizedViaFS.isEmpty ? localizedViaFS : displayName

        let teamID = Self.extractTeamIdentifier(at: appURL)
        let resVals = try? appURL.resourceValues(forKeys: [.contentModificationDateKey, .contentAccessDateKey])
        let spotlightLastUsed = Self.spotlightLastUsedDate(for: appURL)
        let lastUsed = spotlightLastUsed ?? resVals?.contentAccessDate
        let modified = resVals?.contentModificationDate

        let isSystemProtected = safetyGuard.isSystemProtectedApp(at: appURL)
        let isAppleAppStoreApp = !isSystemProtected && safetyGuard.isAppleBundleID(bundleID)
        let isUserProtected = safetyGuard.isUserProtected(bundleID: bundleID, url: appURL)
        let requiresAdmin = safetyGuard.requiresAdmin(for: appURL)
        let stdAppPath = appURL.standardizedFileURL.path
        let isRunning = activeRunning.contains(bundleID.lowercased())
            || activePaths.contains { $0 == stdAppPath || $0.hasPrefix(stdAppPath + "/") }

        return AppItem(
            url: appURL,
            name: rawName,
            localizedName: finalLocalizedName,
            bundleID: bundleID,
            version: version,
            executableName: executableName,
            teamIdentifier: teamID,
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

    private static func runningAppBundlePaths() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.path }
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

    /// Reads the real code-signing Team Identifier via Security framework (no subprocess overhead).
    private static func extractTeamIdentifier(at appURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let code = staticCode else {
            return nil
        }
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &infoRef) == errSecSuccess,
              let dict = infoRef as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else {
            return nil
        }
        return team
    }
}

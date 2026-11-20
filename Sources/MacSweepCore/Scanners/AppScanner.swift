import AppKit
import CoreServices
import Foundation

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

    public func scanApplications(runningIDs: Set<String>? = nil) -> [AppItem] {
        let activeRunning = runningIDs ?? Self.runningBundleIDs()
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

                // Recurse 1 level into subfolders (e.g. Setapp, JetBrains, Utilities if enabled).
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
            guard let item = inspectApp(at: appURL, runningIDs: activeRunning) else { continue }
            if item.isSystemProtected && !showSystemApps {
                continue
            }
            // Hide MacSweep itself from accidental self-uninstall list.
            if item.bundleID.lowercased() == "local.macsweep" {
                continue
            }
            apps.append(item)
        }

        return apps.sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }
    }

    /// Inspects any single `.app` bundle (used both by scanner and Drag & Drop quick uninstall).
    public func inspectApp(at appURL: URL, runningIDs: Set<String>? = nil) -> AppItem? {
        let fm = FileManager.default
        guard appURL.pathExtension.lowercased() == "app",
              fm.fileExists(atPath: appURL.path) else {
            return nil
        }

        let activeRunning = runningIDs ?? Self.runningBundleIDs()
        let rawName = appURL.deletingPathExtension().lastPathComponent
        let bundle = Bundle(url: appURL)
        let info = bundle?.infoDictionary ?? [:]
        let localizedInfo = bundle?.localizedInfoDictionary ?? [:]

        let bundleID = (info["CFBundleIdentifier"] as? String)
            ?? "unknown.\(rawName.lowercased().replacingOccurrences(of: " ", with: "-"))"
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? ""
        let executableName = info["CFBundleExecutable"] as? String

        let displayName = (localizedInfo["CFBundleDisplayName"] as? String)
            ?? (localizedInfo["CFBundleName"] as? String)
            ?? (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? rawName

        let localizedViaFS = fm.displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "")
        let finalLocalizedName = !localizedViaFS.isEmpty ? localizedViaFS : displayName

        let teamID = Self.extractTeamIdentifier(from: info)
        let resVals = try? appURL.resourceValues(forKeys: [.contentModificationDateKey, .contentAccessDateKey])
        let spotlightLastUsed = Self.spotlightLastUsedDate(for: appURL)
        let lastUsed = spotlightLastUsed ?? resVals?.contentAccessDate
        let modified = resVals?.contentModificationDate

        let isSystemProtected = safetyGuard.isSystemProtectedApp(at: appURL)
        let isAppleAppStoreApp = !isSystemProtected && safetyGuard.isAppleBundleID(bundleID)
        let isUserProtected = safetyGuard.isUserProtected(bundleID: bundleID, url: appURL)
        let requiresAdmin = safetyGuard.requiresAdmin(for: appURL)
        let isRunning = activeRunning.contains(bundleID.lowercased())

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

    private static func spotlightLastUsedDate(for url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else {
            return nil
        }
        guard let value = MDItemCopyAttribute(item, kMDItemLastUsedDate) else {
            return nil
        }
        return value as? Date
    }

    private static func extractTeamIdentifier(from info: [String: Any]) -> String? {
        if let groups = info["AppGroups"] as? [String], let first = groups.first {
            let parts = first.split(separator: ".")
            if let team = parts.first, team.count == 10 {
                return String(team)
            }
        }
        return nil
    }
}

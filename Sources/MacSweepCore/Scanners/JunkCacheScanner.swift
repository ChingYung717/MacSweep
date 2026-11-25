import AppKit
import Darwin
import Foundation

public struct JunkScannerEnvironment: Sendable {
    public let homeDirectory: URL
    public let systemLogsDirectory: URL
    public let trashDirectory: URL
    public let runningBundleIDs: Set<String>?
    public let runningAppNames: Set<String>?
    public let includeSystemLogs: Bool

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemLogsDirectory: URL = URL(fileURLWithPath: "/Library/Logs"),
        trashDirectory: URL? = nil,
        runningBundleIDs: Set<String>? = nil,
        runningAppNames: Set<String>? = nil,
        includeSystemLogs: Bool = true
    ) {
        let stdHome = homeDirectory.standardizedFileURL
        self.homeDirectory = stdHome
        self.systemLogsDirectory = systemLogsDirectory.standardizedFileURL
        self.trashDirectory = (trashDirectory ?? stdHome.appendingPathComponent(".Trash")).standardizedFileURL
        self.runningBundleIDs = runningBundleIDs
        self.runningAppNames = runningAppNames
        self.includeSystemLogs = includeSystemLogs
    }
}

public struct JunkCacheScanner: Sendable {
    public let safetyGuard: SafetyGuard
    public let environment: JunkScannerEnvironment
    public let sizer: DirectorySizer
    public let progressThrottleInterval: TimeInterval

    private struct RawChild: Sendable {
        let url: URL
        let name: String
        let isDirectory: Bool
        let isUserImmutable: Bool
        let isHidden: Bool
        let isDataless: Bool
        let isSymlink: Bool
    }

    private struct BrowserSpec: Sendable {
        let name: String
        let bundleID: String
        let relativeCachePaths: [String]
        let expandChildren: Bool
    }

    private struct PendingEntrySpec: Sendable {
        let url: URL
        let name: String
        let category: JunkCategory
        let subgroup: String?
        let isDirectory: Bool
        let isSelected: Bool
        let requiresAdmin: Bool
        let isUserImmutable: Bool
        let isHidden: Bool
        let expectedCanonicalParent: String
        let isRunningAppBlocked: Bool
        let runningAppName: String?
        let browserBundleID: String?
        let safetyReason: String?
        let isRecommendedSafe: Bool
    }

    private static let browserSpecs: [BrowserSpec] = [
        BrowserSpec(
            name: "Google Chrome",
            bundleID: "com.google.Chrome",
            relativeCachePaths: ["Library/Caches/Google/Chrome"],
            expandChildren: false
        ),
        BrowserSpec(
            name: "Microsoft Edge",
            bundleID: "com.microsoft.edgemac",
            relativeCachePaths: ["Library/Caches/Microsoft Edge", "Library/Caches/Microsoft/Edge"],
            expandChildren: false
        ),
        BrowserSpec(
            name: "Brave",
            bundleID: "com.brave.Browser",
            relativeCachePaths: ["Library/Caches/BraveSoftware/Brave-Browser"],
            expandChildren: false
        ),
        BrowserSpec(
            name: "Arc",
            bundleID: "company.thebrowser.Browser",
            relativeCachePaths: ["Library/Caches/company.thebrowser.Browser", "Library/Caches/Arc"],
            expandChildren: false
        ),
        BrowserSpec(
            name: "Firefox",
            bundleID: "org.mozilla.firefox",
            relativeCachePaths: ["Library/Caches/Firefox/Profiles", "Library/Caches/Mozilla/Updates"],
            expandChildren: true
        ),
    ]

    public init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        environment: JunkScannerEnvironment,
        sizer: DirectorySizer = DirectorySizer(),
        progressThrottleInterval: TimeInterval = 0.10
    ) {
        self.safetyGuard = safetyGuard
        self.environment = environment
        self.sizer = sizer
        self.progressThrottleInterval = max(0.01, progressThrottleInterval)
    }

    public init(
        safetyGuard: SafetyGuard = SafetyGuard(),
        homeDirectory: URL? = nil,
        includeSystemLogs: Bool? = nil,
        runningBundleIDs: Set<String>? = nil,
        runningAppNames: Set<String>? = nil,
        sizer: DirectorySizer = DirectorySizer(),
        progressThrottleInterval: TimeInterval = 0.10
    ) {
        let resolvedHome = (homeDirectory ?? URL(fileURLWithPath: safetyGuard.homeDirectoryPath)).standardizedFileURL
        let realHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let defaultIncludeSysLogs = (resolvedHome.path == realHome.path) && (homeDirectory == nil)
        self.safetyGuard = safetyGuard
        self.environment = JunkScannerEnvironment(
            homeDirectory: resolvedHome,
            runningBundleIDs: runningBundleIDs,
            runningAppNames: runningAppNames,
            includeSystemLogs: includeSystemLogs ?? defaultIncludeSysLogs
        )
        self.sizer = sizer
        self.progressThrottleInterval = max(0.01, progressThrottleInterval)
    }

    public func scan(
        onProgress: (@Sendable (JunkScanProgress) -> Void)? = nil
    ) async throws -> [JunkCategoryItem] {
        try await scanAll(onProgress: onProgress).categories
    }

    public func scanAll(
        onProgress: (@Sendable (JunkScanProgress) -> Void)? = nil
    ) async throws -> JunkScanResult {
        let startedAt = Date()
        try Task.checkCancellation()

        let runningApps = resolveRunningApps()
        var claimedCanonicalPaths = Set<String>()
        var lastProgressEmit = Date.distantPast
        var discoveredCount = 0

        func emitProgress(category: JunkCategory, path: String, totalBytes: UInt64 = 0, force: Bool = false) {
            guard let onProgress else { return }
            let now = Date()
            if force || now.timeIntervalSince(lastProgressEmit) >= progressThrottleInterval {
                lastProgressEmit = now
                onProgress(JunkScanProgress(
                    currentCategory: category,
                    currentPath: path,
                    scannedEntries: discoveredCount,
                    totalBytesFound: totalBytes
                ))
            }
        }

        // 1. Browser Caches (scanned first to claim browser subpaths before generic ~/Library/Caches)
        emitProgress(category: .browserCaches, path: environment.homeDirectory.appendingPathComponent("Library/Caches").path, force: true)
        var browserBlockedNames: [String] = []
        var browserNeedsFDA = false
        let browserSpecsPending = try scanBrowserCaches(
            runningApps: runningApps,
            claimedCanonicalPaths: &claimedCanonicalPaths,
            needsFDA: &browserNeedsFDA,
            blockedNames: &browserBlockedNames
        )
        discoveredCount += browserSpecsPending.count

        // 2. Developer Caches (scanned second to claim Homebrew / pip / uv / pnpm / swiftpm before generic ~/Library/Caches)
        emitProgress(category: .developerCaches, path: environment.homeDirectory.appendingPathComponent("Library/Developer").path, force: true)
        let devSpecsPending = try scanDeveloperCaches(
            runningApps: runningApps,
            claimedCanonicalPaths: &claimedCanonicalPaths
        )
        discoveredCount += devSpecsPending.count

        // 3. User & App Caches (~/Library/Caches/* with sharedVendorFolderNames drill-down)
        emitProgress(category: .userCaches, path: environment.homeDirectory.appendingPathComponent("Library/Caches").path, force: true)
        let userCacheSpecsPending = try scanUserCaches(
            runningApps: runningApps,
            claimedCanonicalPaths: &claimedCanonicalPaths
        )
        discoveredCount += userCacheSpecsPending.count

        // 4. Logs & Crash Reports
        emitProgress(category: .logs, path: environment.homeDirectory.appendingPathComponent("Library/Logs").path, force: true)
        let logSpecsPending = try scanLogsAndCrashReports()
        discoveredCount += logSpecsPending.count

        // 5. User Trash (~/.Trash/* children only)
        emitProgress(category: .trash, path: environment.trashDirectory.path, force: true)
        let trashSpecsPending = try scanTrashContents()
        discoveredCount += trashSpecsPending.count

        try Task.checkCancellation()

        // Measure sizes concurrently using DirectorySizer.
        let allPending = browserSpecsPending + devSpecsPending + userCacheSpecsPending + logSpecsPending + trashSpecsPending
        let allURLs = allPending.map(\.url)
        let measuredMap = await sizer.measurements(of: allURLs, maxConcurrency: 6, useCache: false)
        try Task.checkCancellation()

        func materialize(_ specs: [PendingEntrySpec]) -> [JunkEntry] {
            var entries: [JunkEntry] = []
            entries.reserveCapacity(specs.count)
            for spec in specs {
                let measuredBytes = UInt64(max(0, measuredMap[spec.url.standardizedFileURL.path]?.bytes ?? 0))
                entries.append(JunkEntry(
                    url: spec.url,
                    name: spec.name,
                    category: spec.category,
                    subgroup: spec.subgroup,
                    bytes: measuredBytes,
                    isDirectory: spec.isDirectory,
                    isSelected: spec.isSelected,
                    requiresAdmin: spec.requiresAdmin,
                    isProtected: false,
                    isUserImmutable: spec.isUserImmutable,
                    isHidden: spec.isHidden,
                    expectedCanonicalParent: spec.expectedCanonicalParent,
                    isRunningAppBlocked: spec.isRunningAppBlocked,
                    runningAppName: spec.runningAppName,
                    browserBundleID: spec.browserBundleID,
                    safetyReason: spec.safetyReason,
                    isRecommendedSafe: spec.isRecommendedSafe
                ))
            }
            return entries.sorted {
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }

        let userEntries = materialize(userCacheSpecsPending)
        let logEntries = materialize(logSpecsPending)
        let browserEntries = materialize(browserSpecsPending)
        let devEntries = materialize(devSpecsPending)
        let trashEntries = materialize(trashSpecsPending)

        let categories: [JunkCategoryItem] = [
            JunkCategoryItem(
                category: .userCaches,
                title: "User & App Caches",
                description: "Reclaimable application cache directories under ~/Library/Caches.",
                entries: userEntries,
                safetyNote: "Apple system caches, MacSweep self-caches, and bare shared vendor roots (e.g. Google, Microsoft, Adobe) are excluded automatically."
            ),
            JunkCategoryItem(
                category: .logs,
                title: "Logs & Crash Reports",
                description: "Application diagnostic logs and crash reports.",
                entries: logEntries,
                safetyNote: "Parent log folders are preserved. System logs under /Library/Logs require administrator privileges and stay unchecked by default."
            ),
            JunkCategoryItem(
                category: .browserCaches,
                title: "Browser Caches",
                description: "Disposable web cache files for third-party browsers.",
                entries: browserEntries,
                safetyNote: "Only cache directories are targeted; bookmarks, cookies, history, and passwords are never touched. Safari caches are managed inside Safari due to macOS sandbox protection.",
                needsFullDiskAccess: browserNeedsFDA,
                blockedDescriptions: browserBlockedNames
            ),
            JunkCategoryItem(
                category: .developerCaches,
                title: "Developer Caches",
                description: "Xcode DerivedData, simulator caches, and package manager download caches.",
                entries: devEntries,
                safetyNote: "Xcode Archives and DeviceSupport are unchecked by default to protect signed builds and symbols. Toolchains and binaries are never removed."
            ),
            JunkCategoryItem(
                category: .trash,
                title: "Trash Contents",
                description: "Items currently inside your Trash folder.",
                entries: trashEntries,
                safetyNote: "Items inside Trash can only be permanently deleted to free disk space."
            ),
        ]

        let grandTotal = categories.reduce(into: UInt64(0)) { $0 &+= $1.totalBytes }
        emitProgress(
            category: .trash,
            path: environment.trashDirectory.path,
            totalBytes: grandTotal,
            force: true
        )

        return JunkScanResult(
            categories: categories,
            totalBytes: grandTotal,
            needsFullDiskAccess: browserNeedsFDA,
            blockedLocations: browserBlockedNames,
            elapsedSeconds: Date().timeIntervalSince(startedAt)
        )
    }

    // MARK: - Category Scanners

    private func scanBrowserCaches(
        runningApps: RunningAppSnapshot,
        claimedCanonicalPaths: inout Set<String>,
        needsFDA: inout Bool,
        blockedNames: inout [String]
    ) throws -> [PendingEntrySpec] {
        var results: [PendingEntrySpec] = []

        for spec in Self.browserSpecs {
            try Task.checkCancellation()
            let runningMatch = isAppRunning(bundleID: spec.bundleID, appName: spec.name, runningApps: runningApps)

            for relPath in spec.relativeCachePaths {
                guard isContainedCanonicalSubpath(relativePath: relPath, under: environment.homeDirectory) else {
                    continue
                }
                let candidate = environment.homeDirectory.appendingPathComponent(relPath).standardizedFileURL
                guard let info = inspectCandidate(candidate), !info.isSymlink, !info.isDataless else {
                    continue
                }

                if spec.expandChildren && info.isDirectory {
                    if !PermissionChecker.canReadDirectory(candidate) {
                        needsFDA = true
                        if !blockedNames.contains(spec.name) {
                            blockedNames.append(spec.name)
                        }
                        claimedCanonicalPaths.insert(canonicalClaimKey(for: candidate))
                        continue
                    }
                    // Firefox: ~/Library/Caches/Firefox/Profiles/<profile> or ~/Library/Caches/Mozilla/Updates
                    if relPath.hasSuffix("Updates") {
                        try appendBrowserEntryIfValid(
                            url: candidate,
                            info: info,
                            browserName: spec.name,
                            bundleID: spec.bundleID,
                            runningMatch: runningMatch,
                            claimedCanonicalPaths: &claimedCanonicalPaths,
                            into: &results
                        )
                    } else {
                        let children = enumerateDirectChildren(of: candidate)
                        for child in children where !child.isSymlink && !child.isDataless {
                            try Task.checkCancellation()
                            try appendBrowserEntryIfValid(
                                url: child.url,
                                info: child,
                                browserName: spec.name,
                                bundleID: spec.bundleID,
                                runningMatch: runningMatch,
                                claimedCanonicalPaths: &claimedCanonicalPaths,
                                into: &results
                            )
                        }
                    }
                } else {
                    if info.isDirectory && !PermissionChecker.canReadDirectory(candidate) {
                        needsFDA = true
                        if !blockedNames.contains(spec.name) {
                            blockedNames.append(spec.name)
                        }
                        claimedCanonicalPaths.insert(canonicalClaimKey(for: candidate))
                        continue
                    }
                    try appendBrowserEntryIfValid(
                        url: candidate,
                        info: info,
                        browserName: spec.name,
                        bundleID: spec.bundleID,
                        runningMatch: runningMatch,
                        claimedCanonicalPaths: &claimedCanonicalPaths,
                        into: &results
                    )
                }
            }
        }

        return results
    }

    private func appendBrowserEntryIfValid(
        url: URL,
        info: RawChild,
        browserName: String,
        bundleID: String,
        runningMatch: String?,
        claimedCanonicalPaths: inout Set<String>,
        into results: inout [PendingEntrySpec]
    ) throws {
        guard safetyGuard.validateCacheSubpath(url).isAllowed else { return }
        let key = canonicalClaimKey(for: url)
        if claimedCanonicalPaths.contains(where: { $0 == key || $0.hasPrefix(key + "/") || key.hasPrefix($0 + "/") }) {
            return
        }
        guard claimedCanonicalPaths.insert(key).inserted else { return }
        let blocked = runningMatch != nil
        results.append(PendingEntrySpec(
            url: url,
            name: "\(browserName) — \(url.lastPathComponent)",
            category: .browserCaches,
            subgroup: browserName,
            isDirectory: info.isDirectory,
            isSelected: !blocked,
            requiresAdmin: safetyGuard.requiresAdmin(for: url),
            isUserImmutable: info.isUserImmutable,
            isHidden: info.isHidden,
            expectedCanonicalParent: PrivilegedExecutor.canonicalParentPath(forTargetURL: url),
            isRunningAppBlocked: blocked,
            runningAppName: runningMatch,
            browserBundleID: bundleID,
            safetyReason: blocked ? "Quit \(browserName) before clearing cache" : nil,
            isRecommendedSafe: !blocked
        ))
    }

    private func scanDeveloperCaches(
        runningApps: RunningAppSnapshot,
        claimedCanonicalPaths: inout Set<String>
    ) throws -> [PendingEntrySpec] {
        var results: [PendingEntrySpec] = []
        let xcodeRunning = isAppRunning(bundleID: "com.apple.dt.Xcode", appName: "Xcode", runningApps: runningApps)
        let simRunning = isAppRunning(bundleID: "com.apple.iphonesimulator", appName: "Simulator", runningApps: runningApps)

        func addChildren(
            underRelativePath relPath: String,
            subgroup: String,
            defaultSelected: Bool,
            safetyReason: String?,
            isRecommended: Bool,
            runningName: String?
        ) throws {
            guard isContainedCanonicalSubpath(relativePath: relPath, under: environment.homeDirectory) else {
                return
            }
            let parent = environment.homeDirectory.appendingPathComponent(relPath).standardizedFileURL
            guard let parentInfo = inspectCandidate(parent),
                  parentInfo.isDirectory,
                  !parentInfo.isSymlink,
                  !parentInfo.isDataless,
                  let expectedCanonicalDir = SafetyGuard.posixRealpath(parent.path) else {
                return
            }
            let normExpectedCanonicalDir = expectedCanonicalDir.precomposedStringWithCanonicalMapping.lowercased()
            for child in enumerateDirectChildren(of: parent) where !child.isSymlink && !child.isDataless {
                try Task.checkCancellation()
                guard safetyGuard.validateForRemoval(child.url).isAllowed else { continue }
                let canonicalParent = PrivilegedExecutor.canonicalParentPath(forTargetURL: child.url)
                guard canonicalParent.precomposedStringWithCanonicalMapping.lowercased() == normExpectedCanonicalDir else {
                    continue
                }
                let key = canonicalClaimKey(for: child.url)
                if claimedCanonicalPaths.contains(where: { $0 == key || $0.hasPrefix(key + "/") || key.hasPrefix($0 + "/") }) {
                    continue
                }
                guard claimedCanonicalPaths.insert(key).inserted else { continue }
                let reqAdmin = safetyGuard.requiresAdmin(for: child.url)
                let blocked = runningName != nil
                results.append(PendingEntrySpec(
                    url: child.url,
                    name: child.name,
                    category: .developerCaches,
                    subgroup: subgroup,
                    isDirectory: child.isDirectory,
                    isSelected: defaultSelected && !reqAdmin && !blocked,
                    requiresAdmin: reqAdmin,
                    isUserImmutable: child.isUserImmutable,
                    isHidden: child.isHidden,
                    expectedCanonicalParent: canonicalParent,
                    isRunningAppBlocked: blocked,
                    runningAppName: runningName,
                    browserBundleID: nil,
                    safetyReason: blocked ? "Quit \(runningName ?? subgroup) first" : safetyReason,
                    isRecommendedSafe: isRecommended && !reqAdmin && !blocked
                ))
            }
        }

        func addExactSubpath(
            relativePath: String,
            displayName: String,
            subgroup: String,
            requiresCacheSubpathCheck: Bool,
            defaultSelected: Bool = true
        ) {
            guard isContainedCanonicalSubpath(relativePath: relativePath, under: environment.homeDirectory) else {
                return
            }
            let target = environment.homeDirectory.appendingPathComponent(relativePath).standardizedFileURL
            guard let info = inspectCandidate(target), !info.isSymlink, !info.isDataless else { return }
            if requiresCacheSubpathCheck {
                guard safetyGuard.validateCacheSubpath(target).isAllowed else { return }
            } else {
                guard safetyGuard.validateForRemoval(target).isAllowed else { return }
            }
            let key = canonicalClaimKey(for: target)
            if claimedCanonicalPaths.contains(where: { $0 == key || $0.hasPrefix(key + "/") || key.hasPrefix($0 + "/") }) {
                return
            }
            guard claimedCanonicalPaths.insert(key).inserted else { return }
            let reqAdmin = safetyGuard.requiresAdmin(for: target)
            results.append(PendingEntrySpec(
                url: target,
                name: displayName,
                category: .developerCaches,
                subgroup: subgroup,
                isDirectory: info.isDirectory,
                isSelected: defaultSelected && !reqAdmin,
                requiresAdmin: reqAdmin,
                isUserImmutable: info.isUserImmutable,
                isHidden: false,
                expectedCanonicalParent: PrivilegedExecutor.canonicalParentPath(forTargetURL: target),
                isRunningAppBlocked: false,
                runningAppName: nil,
                browserBundleID: nil,
                safetyReason: nil,
                isRecommendedSafe: !reqAdmin && defaultSelected
            ))
        }

        // Xcode DerivedData (selected by default unless Xcode is running)
        try addChildren(
            underRelativePath: "Library/Developer/Xcode/DerivedData",
            subgroup: "Xcode DerivedData",
            defaultSelected: true,
            safetyReason: nil,
            isRecommended: true,
            runningName: xcodeRunning
        )
        // Xcode Archives (NEVER selected by default)
        try addChildren(
            underRelativePath: "Library/Developer/Xcode/Archives",
            subgroup: "Xcode Archives",
            defaultSelected: false,
            safetyReason: "Contains signed app archives and dSYMs",
            isRecommended: false,
            runningName: nil
        )
        // Xcode DeviceSupport (NEVER selected by default)
        for devSupport in ["iOS DeviceSupport", "watchOS DeviceSupport", "tvOS DeviceSupport", "visionOS DeviceSupport"] {
            try addChildren(
                underRelativePath: "Library/Developer/Xcode/\(devSupport)",
                subgroup: "Xcode \(devSupport)",
                defaultSelected: false,
                safetyReason: "Re-copied automatically when connecting a device",
                isRecommended: false,
                runningName: nil
            )
        }
        // CoreSimulator/Caches ONLY (NEVER CoreSimulator/Devices)
        try addChildren(
            underRelativePath: "Library/Developer/CoreSimulator/Caches",
            subgroup: "CoreSimulator Caches",
            defaultSelected: true,
            safetyReason: nil,
            isRecommended: true,
            runningName: simRunning
        )

        // Package manager download/build caches (specific subpaths only)
        addExactSubpath(relativePath: "Library/Caches/Homebrew", displayName: "Homebrew Cache", subgroup: "Homebrew", requiresCacheSubpathCheck: true)
        addExactSubpath(relativePath: "Library/Caches/org.swift.swiftpm", displayName: "SwiftPM Cache", subgroup: "SwiftPM", requiresCacheSubpathCheck: true)
        addExactSubpath(relativePath: "Library/Caches/pip", displayName: "pip Cache (Library)", subgroup: "Python pip", requiresCacheSubpathCheck: true)
        addExactSubpath(relativePath: "Library/Caches/uv", displayName: "uv Cache (Library)", subgroup: "Python uv", requiresCacheSubpathCheck: true)
        addExactSubpath(relativePath: "Library/Caches/pnpm", displayName: "pnpm Cache", subgroup: "pnpm", requiresCacheSubpathCheck: true)
        addExactSubpath(relativePath: ".npm/_cacache", displayName: "npm _cacache", subgroup: "npm", requiresCacheSubpathCheck: false)
        addExactSubpath(relativePath: ".npm/_logs", displayName: "npm _logs", subgroup: "npm", requiresCacheSubpathCheck: false)
        addExactSubpath(relativePath: "Library/pnpm/store", displayName: "pnpm Store", subgroup: "pnpm", requiresCacheSubpathCheck: false)
        addExactSubpath(relativePath: ".pnpm-store", displayName: "pnpm Store (.pnpm-store)", subgroup: "pnpm", requiresCacheSubpathCheck: false)
        addExactSubpath(relativePath: ".cache/pip", displayName: "pip Cache (~/.cache/pip)", subgroup: "Python pip", requiresCacheSubpathCheck: false)
        addExactSubpath(relativePath: ".cache/uv", displayName: "uv Cache (~/.cache/uv)", subgroup: "Python uv", requiresCacheSubpathCheck: false)
        addExactSubpath(relativePath: ".cargo/registry/cache", displayName: "Cargo Registry Cache", subgroup: "Rust Cargo", requiresCacheSubpathCheck: false)
        addExactSubpath(relativePath: ".cargo/git/db", displayName: "Cargo Git Cache", subgroup: "Rust Cargo", requiresCacheSubpathCheck: false)

        return results
    }

    private func scanUserCaches(
        runningApps: RunningAppSnapshot,
        claimedCanonicalPaths: inout Set<String>
    ) throws -> [PendingEntrySpec] {
        guard isContainedCanonicalSubpath(relativePath: "Library/Caches", under: environment.homeDirectory) else {
            return []
        }
        let cachesRoot = environment.homeDirectory.appendingPathComponent("Library/Caches").standardizedFileURL
        guard let rootInfo = inspectCandidate(cachesRoot),
              rootInfo.isDirectory,
              !rootInfo.isSymlink,
              !rootInfo.isDataless else {
            return []
        }

        var results: [PendingEntrySpec] = []
        let children = enumerateDirectChildren(of: cachesRoot)

        for child in children where !child.isSymlink && !child.isDataless {
            try Task.checkCancellation()
            let lowerName = child.name.precomposedStringWithCanonicalMapping.lowercased()
            if isAppleOrSelfName(lowerName) || lowerName == "firefox" {
                continue
            }

            if SafetyGuard.sharedVendorFolderNames.contains(lowerName) && child.isDirectory {
                // Never add bare shared vendor root; drill down 1 level into <Vendor>/<AppCache>.
                let vendorChildren = enumerateDirectChildren(of: child.url)
                for sub in vendorChildren where !sub.isSymlink && !sub.isDataless {
                    try Task.checkCancellation()
                    let subLower = sub.name.precomposedStringWithCanonicalMapping.lowercased()
                    if isAppleOrSelfName(subLower) { continue }
                    appendUserCacheIfValid(
                        child: sub,
                        subgroup: child.name,
                        runningApps: runningApps,
                        claimedCanonicalPaths: &claimedCanonicalPaths,
                        into: &results
                    )
                }
            } else {
                appendUserCacheIfValid(
                    child: child,
                    subgroup: nil,
                    runningApps: runningApps,
                    claimedCanonicalPaths: &claimedCanonicalPaths,
                    into: &results
                )
            }
        }

        return results
    }

    private func appendUserCacheIfValid(
        child: RawChild,
        subgroup: String?,
        runningApps: RunningAppSnapshot,
        claimedCanonicalPaths: inout Set<String>,
        into results: inout [PendingEntrySpec]
    ) {
        guard safetyGuard.validateCacheSubpath(child.url).isAllowed else { return }
        let key = canonicalClaimKey(for: child.url)
        if claimedCanonicalPaths.contains(where: { $0 == key || $0.hasPrefix(key + "/") || key.hasPrefix($0 + "/") }) {
            return
        }
        guard claimedCanonicalPaths.insert(key).inserted else { return }
        let runningName = matchRunningApp(forCacheName: child.name, runningApps: runningApps)
        let blocked = runningName != nil
        let reqAdmin = safetyGuard.requiresAdmin(for: child.url)
        results.append(PendingEntrySpec(
            url: child.url,
            name: child.name,
            category: .userCaches,
            subgroup: subgroup,
            isDirectory: child.isDirectory,
            isSelected: !blocked && !reqAdmin,
            requiresAdmin: reqAdmin,
            isUserImmutable: child.isUserImmutable,
            isHidden: child.isHidden,
            expectedCanonicalParent: PrivilegedExecutor.canonicalParentPath(forTargetURL: child.url),
            isRunningAppBlocked: blocked,
            runningAppName: runningName,
            browserBundleID: nil,
            safetyReason: blocked ? "Quit \(runningName ?? child.name) before clearing cache" : nil,
            isRecommendedSafe: !blocked && !reqAdmin
        ))
    }

    private func scanLogsAndCrashReports() throws -> [PendingEntrySpec] {
        var results: [PendingEntrySpec] = []
        var seenPaths = Set<String>()

        func scanLogRoot(
            baseRoot: URL,
            relativePath relPath: String,
            subgroup: String,
            forceAdmin: Bool,
            skipDiagnosticReportsEntry: Bool
        ) throws {
            guard isContainedCanonicalSubpath(relativePath: relPath, under: baseRoot) else {
                return
            }
            let root = relPath.isEmpty
                ? baseRoot.standardizedFileURL
                : baseRoot.appendingPathComponent(relPath).standardizedFileURL
            guard let rootInfo = inspectCandidate(root),
                  rootInfo.isDirectory,
                  !rootInfo.isSymlink,
                  !rootInfo.isDataless,
                  let canonicalRoot = SafetyGuard.posixRealpath(root.path) else {
                return
            }
            let normCanonicalRoot = canonicalRoot.precomposedStringWithCanonicalMapping.lowercased()
            for child in enumerateDirectChildren(of: root) where !child.isSymlink && !child.isDataless {
                try Task.checkCancellation()
                let lower = child.name.precomposedStringWithCanonicalMapping.lowercased()
                if skipDiagnosticReportsEntry && lower == "diagnosticreports" {
                    continue
                }
                if isAppleOrSelfName(lower) {
                    continue
                }

                if SafetyGuard.sharedVendorFolderNames.contains(lower) && child.isDirectory {
                    for sub in enumerateDirectChildren(of: child.url) where !sub.isSymlink && !sub.isDataless {
                        try Task.checkCancellation()
                        let subLower = sub.name.precomposedStringWithCanonicalMapping.lowercased()
                        if isAppleOrSelfName(subLower) { continue }
                        appendLogEntryIfValid(
                            sub,
                            subgroup: "\(subgroup) / \(child.name)",
                            expectedCanonicalRootLower: normCanonicalRoot,
                            forceAdmin: forceAdmin,
                            seenPaths: &seenPaths,
                            into: &results
                        )
                    }
                } else {
                    appendLogEntryIfValid(
                        child,
                        subgroup: subgroup,
                        expectedCanonicalRootLower: normCanonicalRoot,
                        forceAdmin: forceAdmin,
                        seenPaths: &seenPaths,
                        into: &results
                    )
                }
            }
        }

        func appendLogEntryIfValid(
            _ child: RawChild,
            subgroup: String,
            expectedCanonicalRootLower: String,
            forceAdmin: Bool,
            seenPaths: inout Set<String>,
            into results: inout [PendingEntrySpec]
        ) {
            guard safetyGuard.validateForRemoval(child.url).isAllowed else { return }
            let canonicalParent = PrivilegedExecutor.canonicalParentPath(forTargetURL: child.url)
            let normCanonicalParent = canonicalParent.precomposedStringWithCanonicalMapping.lowercased()
            guard normCanonicalParent == expectedCanonicalRootLower
                || normCanonicalParent.hasPrefix(expectedCanonicalRootLower + "/") else {
                return
            }
            let key = canonicalClaimKey(for: child.url)
            guard seenPaths.insert(key).inserted else { return }
            let reqAdmin = forceAdmin || safetyGuard.requiresAdmin(for: child.url)
            results.append(PendingEntrySpec(
                url: child.url,
                name: child.name,
                category: .logs,
                subgroup: subgroup,
                isDirectory: child.isDirectory,
                isSelected: !reqAdmin,
                requiresAdmin: reqAdmin,
                isUserImmutable: child.isUserImmutable,
                isHidden: child.isHidden,
                expectedCanonicalParent: canonicalParent,
                isRunningAppBlocked: false,
                runningAppName: nil,
                browserBundleID: nil,
                safetyReason: reqAdmin ? "System log (requires administrator privileges)" : nil,
                isRecommendedSafe: !reqAdmin
            ))
        }

        try scanLogRoot(baseRoot: environment.homeDirectory, relativePath: "Library/Logs", subgroup: "User Logs", forceAdmin: false, skipDiagnosticReportsEntry: true)
        try scanLogRoot(baseRoot: environment.homeDirectory, relativePath: "Library/Logs/DiagnosticReports", subgroup: "Crash Reports", forceAdmin: false, skipDiagnosticReportsEntry: false)
        try scanLogRoot(baseRoot: environment.homeDirectory, relativePath: "Library/Application Support/CrashReporter", subgroup: "CrashReporter", forceAdmin: false, skipDiagnosticReportsEntry: false)

        if environment.includeSystemLogs {
            try scanLogRoot(baseRoot: environment.systemLogsDirectory, relativePath: "", subgroup: "System Logs", forceAdmin: true, skipDiagnosticReportsEntry: true)
            try scanLogRoot(baseRoot: environment.systemLogsDirectory, relativePath: "DiagnosticReports", subgroup: "System Crash Reports", forceAdmin: true, skipDiagnosticReportsEntry: false)
        }

        return results
    }

    private func scanTrashContents() throws -> [PendingEntrySpec] {
        let trashRoot = environment.trashDirectory.standardizedFileURL
        let homePath = environment.homeDirectory.standardizedFileURL.path
        if trashRoot.path.hasPrefix(homePath + "/") {
            let relTrash = String(trashRoot.path.dropFirst(homePath.count + 1))
            guard isContainedCanonicalSubpath(relativePath: relTrash, under: environment.homeDirectory) else {
                return []
            }
        } else {
            guard isContainedCanonicalSubpath(relativePath: "", under: trashRoot) else {
                return []
            }
        }
        guard let rootInfo = inspectCandidate(trashRoot),
              rootInfo.isDirectory,
              !rootInfo.isSymlink,
              !rootInfo.isDataless,
              let canonicalTrashRoot = SafetyGuard.posixRealpath(trashRoot.path) else {
            return []
        }
        let normCanonicalTrashRoot = canonicalTrashRoot.precomposedStringWithCanonicalMapping.lowercased()

        var results: [PendingEntrySpec] = []
        for child in enumerateDirectChildren(of: trashRoot) where !child.isSymlink && !child.isDataless {
            try Task.checkCancellation()
            guard safetyGuard.validateForRemoval(child.url).isAllowed else { continue }
            let canonicalParent = PrivilegedExecutor.canonicalParentPath(forTargetURL: child.url)
            guard canonicalParent.precomposedStringWithCanonicalMapping.lowercased() == normCanonicalTrashRoot else {
                continue
            }
            let reqAdmin = safetyGuard.requiresAdmin(for: child.url)
            results.append(PendingEntrySpec(
                url: child.url,
                name: child.name,
                category: .trash,
                subgroup: "Trash",
                isDirectory: child.isDirectory,
                isSelected: !reqAdmin,
                requiresAdmin: reqAdmin,
                isUserImmutable: child.isUserImmutable,
                isHidden: child.isHidden,
                expectedCanonicalParent: canonicalParent,
                isRunningAppBlocked: false,
                runningAppName: nil,
                browserBundleID: nil,
                safetyReason: reqAdmin ? "Owned by root; requires administrator privileges" : nil,
                isRecommendedSafe: !reqAdmin
            ))
        }
        return results
    }

    // MARK: - POSIX Directory Helpers

    private func enumerateDirectChildren(of directory: URL) -> [RawChild] {
        guard let dirPtr = Darwin.opendir(directory.path) else {
            return []
        }
        defer { Darwin.closedir(dirPtr) }

        let dirFD = Darwin.dirfd(dirPtr)
        var children: [RawChild] = []

        while let ent = Darwin.readdir(dirPtr) {
            let name = withUnsafePointer(to: &ent.pointee.d_name) { ptr -> String in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { cStr in
                    String(cString: cStr)
                }
            }
            if name.isEmpty || name == "." || name == ".." || name == ".DS_Store" || name == ".localized" {
                continue
            }

            var st = stat()
            guard Darwin.fstatat(dirFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
                continue
            }
            let mode = st.st_mode & S_IFMT
            let isSymlink = (mode == S_IFLNK)
            let isDir = (mode == S_IFDIR)
            let isReg = (mode == S_IFREG)
            if !isSymlink && !isDir && !isReg {
                // Skip FIFOs, sockets, device nodes without ever opening them.
                continue
            }

            let isDataless = (st.st_flags & UInt32(SF_DATALESS)) != 0
            let isImmutable = (st.st_flags & UInt32(UF_IMMUTABLE)) != 0
            let isHidden = name.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0
            let childURL = directory.appendingPathComponent(name).standardizedFileURL
            children.append(RawChild(
                url: childURL,
                name: name,
                isDirectory: isDir,
                isUserImmutable: isImmutable,
                isHidden: isHidden,
                isDataless: isDataless,
                isSymlink: isSymlink
            ))
        }

        return children
    }

    private func inspectCandidate(_ url: URL) -> RawChild? {
        var st = stat()
        guard Darwin.lstat(url.path, &st) == 0 else { return nil }
        let mode = st.st_mode & S_IFMT
        let isSymlink = (mode == S_IFLNK)
        let isDir = (mode == S_IFDIR)
        let isReg = (mode == S_IFREG)
        if !isSymlink && !isDir && !isReg {
            return nil
        }
        let name = url.lastPathComponent
        return RawChild(
            url: url.standardizedFileURL,
            name: name,
            isDirectory: isDir,
            isUserImmutable: (st.st_flags & UInt32(UF_IMMUTABLE)) != 0,
            isHidden: name.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0,
            isDataless: (st.st_flags & UInt32(SF_DATALESS)) != 0,
            isSymlink: isSymlink
        )
    }

    private func isContainedCanonicalSubpath(
        relativePath: String,
        under baseRoot: URL
    ) -> Bool {
        let stdBase = baseRoot.standardizedFileURL
        var baseStat = stat()
        guard Darwin.lstat(stdBase.path, &baseStat) == 0,
              (baseStat.st_mode & S_IFMT) == S_IFDIR,
              (baseStat.st_flags & UInt32(SF_DATALESS)) == 0,
              let baseReal = SafetyGuard.posixRealpath(stdBase.path) else {
            return false
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var currentURL = stdBase
        var expectedCanonicalPath = (baseReal.count > 1 && baseReal.hasSuffix("/"))
            ? String(baseReal.dropLast())
            : baseReal

        for (idx, comp) in components.enumerated() {
            currentURL = currentURL.appendingPathComponent(comp).standardizedFileURL
            expectedCanonicalPath = expectedCanonicalPath == "/"
                ? "/\(comp)"
                : "\(expectedCanonicalPath)/\(comp)"

            var st = stat()
            guard Darwin.lstat(currentURL.path, &st) == 0 else { return false }
            let mode = st.st_mode & S_IFMT
            let isLast = (idx == components.count - 1)
            if mode == S_IFLNK || (st.st_flags & UInt32(SF_DATALESS)) != 0 {
                return false
            }
            if isLast {
                if mode != S_IFDIR && mode != S_IFREG {
                    return false
                }
            } else if mode != S_IFDIR {
                return false
            }

            let resolved = SafetyGuard.canonicalPathResolvingDeepestAncestor(for: currentURL)
            let normResolved = resolved.precomposedStringWithCanonicalMapping.lowercased()
            let normExpected = expectedCanonicalPath.precomposedStringWithCanonicalMapping.lowercased()
            guard normResolved == normExpected else {
                return false
            }
        }
        return true
    }

    private func canonicalClaimKey(for url: URL) -> String {
        let parent = PrivilegedExecutor.canonicalParentPath(forTargetURL: url)
        return URL(fileURLWithPath: parent)
            .appendingPathComponent(url.lastPathComponent)
            .standardizedFileURL
            .path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    private func isAppleOrSelfName(_ lowerName: String) -> Bool {
        if lowerName == "apple" || lowerName == "com.apple" || lowerName.hasPrefix("com.apple.") {
            return true
        }
        if SafetyGuard.isAppleGroupContainerName(lowerName) {
            return true
        }
        if lowerName == "local.macsweep" || lowerName.hasPrefix("local.macsweep.") {
            return true
        }
        return false
    }

    // MARK: - Running App Matching

    private struct RunningAppSnapshot: Sendable {
        let bundleIDsLower: Set<String>
        let displayNameByBundleIDLower: [String: String]
        let namesLower: [String: String]
    }

    private func resolveRunningApps() -> RunningAppSnapshot {
        if let injectedIDs = environment.runningBundleIDs {
            let lowerIDs = Set(injectedIDs.map { $0.lowercased() })
            var nameMap: [String: String] = [:]
            if let injectedNames = environment.runningAppNames {
                for n in injectedNames {
                    nameMap[n.lowercased()] = n
                }
            }
            return RunningAppSnapshot(
                bundleIDsLower: lowerIDs,
                displayNameByBundleIDLower: [:],
                namesLower: nameMap
            )
        }
        var lowerIDs = Set<String>()
        var byID: [String: String] = [:]
        var names: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier?.lowercased(), !bid.isEmpty {
                lowerIDs.insert(bid)
                if let locName = app.localizedName, !locName.isEmpty {
                    byID[bid] = locName
                }
            }
            if let locName = app.localizedName, !locName.isEmpty {
                names[locName.lowercased()] = locName
            }
        }
        if let injectedNames = environment.runningAppNames {
            for n in injectedNames {
                names[n.lowercased()] = n
            }
        }
        return RunningAppSnapshot(
            bundleIDsLower: lowerIDs,
            displayNameByBundleIDLower: byID,
            namesLower: names
        )
    }

    private func isAppRunning(
        bundleID: String,
        appName: String,
        runningApps: RunningAppSnapshot
    ) -> String? {
        let lowerID = bundleID.lowercased()
        if runningApps.bundleIDsLower.contains(lowerID) {
            return runningApps.displayNameByBundleIDLower[lowerID] ?? appName
        }
        if let matched = runningApps.namesLower[appName.lowercased()] {
            return matched
        }
        return nil
    }

    private func matchRunningApp(
        forCacheName cacheName: String,
        runningApps: RunningAppSnapshot
    ) -> String? {
        let lower = cacheName.lowercased()
        if runningApps.bundleIDsLower.contains(lower) {
            return runningApps.displayNameByBundleIDLower[lower] ?? cacheName
        }
        if let exactName = runningApps.namesLower[lower] {
            return exactName
        }
        return nil
    }
}

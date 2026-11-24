import Foundation
import MacSweepCore

if CommandLine.arguments.contains("--live-audit") {
    print("== MacSweep Read-Only Live Host Audit ==")
    let fda = PermissionChecker.checkFullDiskAccess()
    print("FDA Status: \(fda.hasFullDiskAccess) (probe: \(fda.probePathUsed))")

    let sg = SafetyGuard()
    let index = LibraryIndex.build(safetyGuard: sg)
    print("LibraryIndex entries: \(index.entries.count)")

    let apps = AppScanner(safetyGuard: sg).scanApplications()
    let appleStoreApps = apps.filter(\.isAppleAppStoreApp).map(\.localizedName)
    let hasSafari = apps.contains(where: { $0.bundleID == "com.apple.Safari" })
    print("Applications found: \(apps.count) (Safari hidden/protected: \(!hasSafari), Apple App Store apps: \(appleStoreApps))")

    let matcher = ServiceFileMatcher(safetyGuard: sg)
    let allPkgs = ServiceFileMatcher.listThirdPartyPackages()
    let allIDs = Set(apps.map { $0.bundleID.lowercased() }.filter { !$0.hasPrefix("unknown.") })
    let allPaths = Set(apps.map { $0.url.standardizedFileURL.path })
    let groupOwners = ServiceFileMatcher.applicationGroupOwners(across: apps)
    for probeName in ["AweSun", "Google Drive", "印象笔记", "aDrive", "Microsoft Word"] {
        if let app = apps.first(where: { $0.name == probeName || $0.localizedName == probeName }) {
            let otherGroups = ServiceFileMatcher.otherInstalledApplicationGroups(for: app, groupOwners: groupOwners)
            let res = matcher.matchWithPackages(
                app: app,
                index: index,
                allPackageIDs: allPkgs,
                allInstalledBundleIDs: allIDs,
                otherInstalledAppPaths: allPaths.subtracting([app.url.standardizedFileURL.path]),
                otherInstalledAppGroups: otherGroups
            )
            let sharedOfficeSuffixes: Set<String> = [
                "UBF8T346G9.Office",
                "UBF8T346G9.ms",
                "UBF8T346G9.com.microsoft.entrabroker",
                "UBF8T346G9.com.microsoft.oneauth",
                "UBF8T346G9.group.com.microsoft.shared",
                "UBF8T346G9.OfficeOsfWebHost",
                "UBF8T346G9.OfficeOneDriveSyncIntegration",
            ]
            let badPaths = res.files.map(\.url.path).filter {
                $0 == "/Library/StartupItems" || $0 == "/Library/Printers" || $0 == "/etc/paths.d"
                    || $0.hasPrefix("/Applications/Google Docs")
                    || (probeName == "Microsoft Word" && sharedOfficeSuffixes.contains(URL(fileURLWithPath: $0).lastPathComponent))
            }
            print("  - \(app.localizedName) [\(app.bundleID)]: \(res.files.count) files, pkgs=\(res.matchedPackageIDs.count), badSharedHits=\(badPaths)")
        }
    }

    let startups = StartupScanner(safetyGuard: sg).scanAll()
    let disabledCount = startups.filter { !$0.isEnabled }.count
    let orphanedCount = startups.filter(\.isOrphanedBinary).count
    let loginCount = startups.filter { $0.scope == .appLoginItem }.count
    print("Startup items: \(startups.count) (disabled: \(disabledCount), orphaned: \(orphanedCount), appLoginItems: \(loginCount))")

    let inventory = InstalledAppInventory.build(libraryIndex: index)
    let leftovers = LeftoverScanner(safetyGuard: sg).scan(index: index, inventory: inventory)
    let highLeft = leftovers.filter { $0.confidence == .high }
    let medLeft = leftovers.filter { $0.confidence == .medium }
    let allLeftPaths = leftovers.flatMap { $0.files.map(\.url.path) }
    let osLeakCheck = allLeftPaths.filter {
        $0.contains("/Apple/") || $0.contains("org.cups.") || $0.contains("net.java.openjdk")
            || $0.contains("com.plausiblelabs.crashreporter") || $0.hasSuffix("/BTServer")
            || $0.hasSuffix("/ApplePushService") || $0.hasSuffix("/livefsd")
            || $0 == "/Library/Logs/DiagnosticReports"
    }
    print("Leftovers: \(leftovers.count) groups (high: \(highLeft.count), medium: \(medLeft.count), containmentNames: \(inventory.containmentNames.count), osLeakHits: \(osLeakCheck))")
    for g in highLeft.prefix(5) {
        print("  - [HIGH] \(g.groupName) (\(g.suspectedBundleID ?? g.id)): \(g.files.count) files")
    }
    for g in medLeft.prefix(5) {
        print("  - [MED]  \(g.groupName): \(g.files.count) files")
    }

    let extRes = ExtensionScanner(safetyGuard: sg).scanAll()
    let byCat = Dictionary(grouping: extRes.items, by: \.category).mapValues(\.count)
    let pluginkitItems = extRes.items.filter { $0.category == .browserSafari || $0.category == .appExtension }
    let enabledPluginkit = pluginkitItems.filter(\.isEnabled).count
    print("Extensions: \(extRes.items.count) total (pluginkit enabled: \(enabledPluginkit)/\(pluginkitItems.count), needsFDAForBrowsers: \(extRes.needsFullDiskAccessForBrowsers), blocked: \(extRes.blockedBrowserNames))")
    for (cat, count) in byCat.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
        print("  - \(cat.rawValue): \(count)")
    }
    exit(0)
}

let runner = CheckRunner()
runSafetyGuardChecks(runner)
runServiceFileMatcherChecks(runner)
runRemovalEngineChecks(runner)
runStartupChecks(runner)
runLeftoverChecks(runner)
runExtensionChecks(runner)
runReviewRegressionChecks(runner)
runAuditFixChecks(runner)
runner.summaryAndExit()

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
    let sampleApps = apps.prefix(5)
    for app in sampleApps {
        let sf = matcher.matchInMemory(app: app, index: index)
        print("  - \(app.localizedName) [\(app.bundleID)]: \(sf.count) service files")
    }

    let startups = StartupScanner(safetyGuard: sg).scanAll()
    let disabledCount = startups.filter { !$0.isEnabled }.count
    let orphanedCount = startups.filter(\.isOrphanedBinary).count
    print("Startup items: \(startups.count) (disabled: \(disabledCount), orphaned: \(orphanedCount))")

    let inventory = InstalledAppInventory.build(libraryIndex: index)
    let leftovers = LeftoverScanner(safetyGuard: sg).scan(index: index, inventory: inventory)
    let highLeft = leftovers.filter { $0.confidence == .high }
    let medLeft = leftovers.filter { $0.confidence == .medium }
    print("Leftovers: \(leftovers.count) groups (high: \(highLeft.count), medium: \(medLeft.count))")
    for g in highLeft.prefix(5) {
        print("  - [HIGH] \(g.groupName) (\(g.suspectedBundleID ?? g.id)): \(g.files.count) files")
    }
    for g in medLeft.prefix(5) {
        print("  - [MED]  \(g.groupName): \(g.files.count) files")
    }

    let extRes = ExtensionScanner(safetyGuard: sg).scanAll()
    let byCat = Dictionary(grouping: extRes.items, by: \.category).mapValues(\.count)
    print("Extensions: \(extRes.items.count) total (needsFDAForBrowsers: \(extRes.needsFullDiskAccessForBrowsers), blocked: \(extRes.blockedBrowserNames))")
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
runner.summaryAndExit()

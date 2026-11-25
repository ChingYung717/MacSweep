import Foundation

public struct DemoFixtureCatalog: Sendable, Equatable {
    public static let demoUsername: String = "alex"
    public static let homeDirectoryPath: String = "/Users/alex"
    public static let homeDirectoryURL: URL = URL(fileURLWithPath: "/Users/alex")
    public static let applicationsDirectoryURL: URL = URL(fileURLWithPath: "/Applications")
    public static let trashDirectoryURL: URL = URL(fileURLWithPath: "/Users/alex/.Trash")
    public static let referenceDate: Date = Date(timeIntervalSince1970: 1_760_000_000)

    public let defaultPreferences: SweepPreferences
    public let cleanupHistory: [CleanupRecord]
    public let applications: [AppItem]
    public let startupItems: [StartupItem]
    public let extensionItems: [ExtensionItem]
    public let extensionScanResult: ExtensionScanResult
    public let leftoverGroups: [LeftoverGroup]
    public let diskTree: DiskTreeNode
    public let applicationsDiskTree: DiskTreeNode
    public let volumeInfo: VolumeStorageInfo
    public let availableVolumes: [VolumeStorageInfo]
    public let favorites: [FileBrowserFavorite]
    public let fileBrowserEntries: [FileBrowserEntry]
    public let browserDirectories: [String: [FileBrowserEntry]]
    public let junkCategories: [JunkCategoryItem]
    public let junkScanResult: JunkScanResult
    public let largeFiles: [LargeFileItem]
    public let duplicateGroups: [DuplicateGroup]
    public let memorySnapshot: MemorySnapshot
    public let runningBundleIDs: Set<String>
    public let plistPreviews: [String: String]
    public let filePreviews: [String: FilePreviewPayload]

    public let defaultSelectedAppID: String
    public let defaultSelectedStartupID: String
    public let defaultSelectedExtensionID: String
    public let defaultSelectedLeftoverGroupID: String
    public let defaultBrowserDirectoryURL: URL
    public let defaultInspectedFileURL: URL

    public static let `default`: DemoFixtureCatalog = makeDefault()

    public static var demoSafetyGuard: SafetyGuard {
        let prefs = Self.default.defaultPreferences
        return SafetyGuard(
            homeDirectory: homeDirectoryURL,
            selfBundlePath: "/Applications/MacSweep.app",
            protectedPaths: prefs.protectedPaths,
            protectedBundleIDs: prefs.protectedBundleIDs
        )
    }

    public static var diskTreeRoot: DiskTreeNode {
        Self.default.diskTree
    }

    public static func makeDefault() -> DemoFixtureCatalog {
        let prefs = SweepPreferences(
            themeMode: .deepOcean,
            language: .en,
            defaultRemovalMode: .trash,
            showSystemApps: false,
            includeUtilitiesFolder: false,
            protectedBundleIDs: ["com.codepulse.ide"],
            protectedPaths: [
                "/Users/alex/Projects/aurora-core",
                "/Users/alex/Documents/Tax-2025-Archive.pdf",
            ],
            ignoredLeftoverIDs: ["com.legacy.soundboard"]
        )

        let history: [CleanupRecord] = [
            CleanupRecord(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555501")!,
                date: daysAgo(1),
                actionTitle: "Clean 4 junk items",
                mode: .trash,
                itemCount: 4,
                freedBytes: 2_840_000_000,
                removedPaths: [
                    "/Users/alex/Library/Caches/com.novanote.desktop",
                    "/Users/alex/Library/Logs/PixelForge/render-2025.log",
                    "/Users/alex/Library/Caches/Homebrew/downloads",
                    "/Users/alex/Library/Caches/com.codepulse.ide",
                ]
            ),
            CleanupRecord(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555502")!,
                date: daysAgo(4),
                actionTitle: "Uninstall StreamDeckPro.app",
                mode: .trash,
                itemCount: 3,
                freedBytes: 418_500_000,
                removedPaths: [
                    "/Applications/StreamDeckPro.app",
                    "/Users/alex/Library/Application Support/StreamDeckPro",
                    "/Users/alex/Library/Preferences/com.streamdeckpro.mac.plist",
                ]
            ),
            CleanupRecord(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555503")!,
                date: daysAgo(12),
                actionTitle: "Remove 2 duplicate files",
                mode: .permanent,
                itemCount: 2,
                freedBytes: 1_240_000_000,
                removedPaths: [
                    "/Users/alex/Downloads/macOS-15-SDK-copy.dmg",
                    "/Users/alex/Downloads/design-kit-v4 (1).zip",
                ]
            ),
        ]

        // MARK: Applications
        var novaNote = AppItem(
            url: url("/Applications/NovaNote.app"),
            name: "NovaNote",
            localizedName: "NovaNote",
            bundleID: "com.novanote.desktop",
            version: "3.4.2",
            executableName: "NovaNote",
            teamIdentifier: "NV84LABS21",
            developerName: "Nova Labs Inc.",
            verificationStatus: .notarized,
            architectures: ["arm64", "x86_64"],
            minimumSystemVersion: "13.0",
            applicationGroups: ["NV84LABS21.com.novanote.shared"],
            embeddedBundleIDs: ["com.novanote.helper"],
            embeddedAppNames: ["NovaNoteHelper"],
            privilegedHelperLabels: ["com.novanote.helper"],
            expectedCanonicalParent: "/Applications",
            lastUsedDate: daysAgo(1),
            modifiedDate: daysAgo(14),
            bundleSize: 486_000_000,
            bundleFileCount: 1_420,
            bundleFolderCount: 118,
            serviceFiles: [
                sf("/Users/alex/Library/Application Support/NovaNote", .applicationSupport, 742_000_000, files: 312, folders: 28, isDir: true, reason: "Bundle ID & App Name"),
                sf("/Users/alex/Library/Caches/com.novanote.desktop", .caches, 418_000_000, files: 640, folders: 45, isDir: true, reason: "Exact Bundle ID"),
                sf("/Users/alex/Library/Containers/com.novanote.desktop", .containers, 194_000_000, files: 95, folders: 14, isDir: true, reason: "Sandbox Container"),
                sf("/Users/alex/Library/Group Containers/NV84LABS21.com.novanote.shared", .groupContainers, 48_200_000, files: 24, folders: 6, isDir: true, reason: "Application Group"),
                sf("/Users/alex/Library/Preferences/com.novanote.desktop.plist", .preferences, 124_000, files: 1, folders: 0, isDir: false, reason: "Exact Bundle ID"),
                sf("/Users/alex/Library/Logs/NovaNote", .logs, 18_400_000, files: 19, folders: 2, isDir: true, reason: "App Name Match"),
                sf("/Users/alex/Library/Saved Application State/com.novanote.desktop.savedState", .savedState, 1_850_000, files: 8, folders: 1, isDir: true, reason: "Exact Bundle ID"),
                sf("/Users/alex/Library/LaunchAgents/com.novanote.helper.plist", .launchAgents, 2_480, files: 1, folders: 0, isDir: false, reason: "Embedded Helper"),
            ],
            matchedPackageIDs: ["com.novanote.desktop.pkg"],
            isRunning: false,
            isProtected: false,
            isSystemProtected: false,
            isAppleAppStoreApp: false,
            requiresAdmin: false,
            isChecked: false,
            scanState: .ready
        )
        novaNote.hasEnrichedPackages = true
        novaNote.hasAssessedNotarization = true

        var pixelForge = AppItem(
            url: url("/Applications/PixelForge Studio.app"),
            name: "PixelForge Studio",
            localizedName: "PixelForge Studio",
            bundleID: "io.pixelforge.studio",
            version: "5.1.0",
            executableName: "PixelForge",
            teamIdentifier: "PF92GRFX10",
            developerName: "PixelForge Graphics Ltd.",
            verificationStatus: .notarized,
            architectures: ["arm64"],
            minimumSystemVersion: "14.0",
            expectedCanonicalParent: "/Applications",
            lastUsedDate: daysAgo(3),
            modifiedDate: daysAgo(21),
            bundleSize: 1_180_000_000,
            bundleFileCount: 3_810,
            bundleFolderCount: 290,
            serviceFiles: [
                sf("/Users/alex/Library/Application Support/PixelForge Studio", .applicationSupport, 286_000_000, files: 188, folders: 16, isDir: true, reason: "App Name Match"),
                sf("/Users/alex/Library/Caches/io.pixelforge.studio", .caches, 174_000_000, files: 410, folders: 22, isDir: true, reason: "Exact Bundle ID"),
                sf("/Users/alex/Library/Preferences/io.pixelforge.studio.plist", .preferences, 68_400, files: 1, folders: 0, isDir: false, reason: "Exact Bundle ID"),
            ],
            matchedPackageIDs: ["io.pixelforge.studio.pkg"],
            isRunning: false,
            isProtected: false,
            isSystemProtected: false,
            isAppleAppStoreApp: false,
            requiresAdmin: false,
            isChecked: false,
            scanState: .ready
        )
        pixelForge.hasEnrichedPackages = true
        pixelForge.hasAssessedNotarization = true

        var codePulse = AppItem(
            url: url("/Applications/CodePulse IDE.app"),
            name: "CodePulse IDE",
            localizedName: "CodePulse IDE",
            bundleID: "com.codepulse.ide",
            version: "2026.2",
            executableName: "CodePulse",
            teamIdentifier: "CP44DEV998",
            developerName: "CodePulse DevTools",
            verificationStatus: .developerSigned,
            architectures: ["arm64"],
            minimumSystemVersion: "14.0",
            expectedCanonicalParent: "/Applications",
            lastUsedDate: daysAgo(0),
            modifiedDate: daysAgo(7),
            bundleSize: 820_000_000,
            bundleFileCount: 2_640,
            bundleFolderCount: 210,
            serviceFiles: [
                sf("/Users/alex/Library/Application Support/CodePulse", .applicationSupport, 312_000_000, files: 410, folders: 34, isDir: true, reason: "App Name Match"),
                sf("/Users/alex/Library/Caches/JetBrains/CodePulse2026", .caches, 198_000_000, files: 520, folders: 40, isDir: true, reason: "Vendor Subpath"),
            ],
            matchedPackageIDs: [],
            isRunning: true,
            isProtected: true,
            isSystemProtected: false,
            isAppleAppStoreApp: false,
            requiresAdmin: false,
            isChecked: false,
            scanState: .ready
        )
        codePulse.hasEnrichedPackages = true
        codePulse.hasAssessedNotarization = true

        var cloudSync = AppItem(
            url: url("/Applications/CloudSync Drive.app"),
            name: "CloudSync Drive",
            localizedName: "CloudSync Drive",
            bundleID: "com.cloudsync.drive",
            version: "4.8.1",
            executableName: "CloudSync",
            teamIdentifier: "CS71SYNC44",
            developerName: "CloudSync Systems",
            verificationStatus: .appStore,
            architectures: ["arm64", "x86_64"],
            minimumSystemVersion: "13.0",
            expectedCanonicalParent: "/Applications",
            lastUsedDate: daysAgo(2),
            modifiedDate: daysAgo(30),
            bundleSize: 215_000_000,
            bundleFileCount: 740,
            bundleFolderCount: 62,
            serviceFiles: [
                sf("/Users/alex/Library/Application Support/CloudSync Drive", .applicationSupport, 94_500_000, files: 112, folders: 14, isDir: true, reason: "App Name Match"),
                sf("/Users/alex/Library/Caches/com.cloudsync.drive", .caches, 51_200_000, files: 84, folders: 9, isDir: true, reason: "Exact Bundle ID"),
            ],
            matchedPackageIDs: [],
            isRunning: false,
            isProtected: false,
            isSystemProtected: false,
            isAppleAppStoreApp: false,
            requiresAdmin: false,
            isChecked: false,
            scanState: .ready
        )
        cloudSync.hasEnrichedPackages = true
        cloudSync.hasAssessedNotarization = true

        var audioWeave = AppItem(
            url: url("/Applications/AudioWeave Pro.app"),
            name: "AudioWeave Pro",
            localizedName: "AudioWeave Pro",
            bundleID: "audio.audioweave.pro",
            version: "2.9.4",
            executableName: "AudioWeave",
            teamIdentifier: "AW55DSP102",
            developerName: "AudioWeave DSP",
            verificationStatus: .notarized,
            architectures: ["arm64"],
            minimumSystemVersion: "13.0",
            expectedCanonicalParent: "/Applications",
            lastUsedDate: daysAgo(8),
            modifiedDate: daysAgo(45),
            bundleSize: 342_000_000,
            bundleFileCount: 980,
            bundleFolderCount: 84,
            serviceFiles: [
                sf("/Users/alex/Library/Application Support/AudioWeave", .applicationSupport, 64_000_000, files: 46, folders: 6, isDir: true, reason: "App Name Match"),
                sf("/Library/Audio/Plug-Ins/HAL/AudioWeaveVirtual.driver", .plugins, 14_200_000, files: 18, folders: 4, isDir: true, selected: false, requiresAdmin: true, requiresReboot: true, systemScope: true, reason: "HAL Audio Driver"),
            ],
            matchedPackageIDs: ["audio.audioweave.driver.pkg"],
            isRunning: false,
            isProtected: false,
            isSystemProtected: false,
            isAppleAppStoreApp: false,
            requiresAdmin: false,
            isChecked: false,
            scanState: .ready
        )
        audioWeave.hasEnrichedPackages = true
        audioWeave.hasAssessedNotarization = true

        var deckFlow = AppItem(
            url: url("/Applications/DeckFlow.app"),
            name: "DeckFlow",
            localizedName: "DeckFlow",
            bundleID: "com.deckflow.presenter",
            version: "1.12.0",
            executableName: "DeckFlow",
            teamIdentifier: "DF31PRES19",
            developerName: "DeckFlow Studio",
            verificationStatus: .developerSigned,
            architectures: ["arm64"],
            minimumSystemVersion: "14.0",
            expectedCanonicalParent: "/Applications",
            lastUsedDate: daysAgo(19),
            modifiedDate: daysAgo(62),
            bundleSize: 64_500_000,
            bundleFileCount: 220,
            bundleFolderCount: 18,
            serviceFiles: [
                sf("/Users/alex/Library/Caches/com.deckflow.presenter", .caches, 12_400_000, files: 36, folders: 4, isDir: true, reason: "Exact Bundle ID"),
                sf("/Users/alex/Library/Preferences/com.deckflow.presenter.plist", .preferences, 18_200, files: 1, folders: 0, isDir: false, reason: "Exact Bundle ID"),
            ],
            matchedPackageIDs: [],
            isRunning: false,
            isProtected: false,
            isSystemProtected: false,
            isAppleAppStoreApp: false,
            requiresAdmin: false,
            isChecked: false,
            scanState: .ready
        )
        deckFlow.hasEnrichedPackages = true
        deckFlow.hasAssessedNotarization = true

        let apps = [novaNote, pixelForge, codePulse, audioWeave, cloudSync, deckFlow]

        // MARK: Startup Items & Plist Previews
        let startup: [StartupItem] = [
            StartupItem(
                label: "com.novanote.helper",
                plistURL: url("/Users/alex/Library/LaunchAgents/com.novanote.helper.plist"),
                programPath: "/Applications/NovaNote.app/Contents/Library/LoginItems/NovaNoteHelper.app/Contents/MacOS/NovaNoteHelper",
                programArguments: [
                    "/Applications/NovaNote.app/Contents/Library/LoginItems/NovaNoteHelper.app/Contents/MacOS/NovaNoteHelper",
                    "--background",
                ],
                scope: .userAgent,
                isEnabled: true,
                runAtLoad: true,
                keepAlive: false,
                isOrphanedBinary: false,
                associatedAppPath: "/Applications/NovaNote.app",
                associatedAppName: "NovaNote",
                associatedAppExists: true,
                labelFromPlist: "com.novanote.helper",
                requiresAdmin: false,
                canToggle: true,
                canRemove: true,
                fileSize: 612,
                expectedCanonicalParent: "/Users/alex/Library/LaunchAgents"
            ),
            StartupItem(
                label: "com.veloxvpn.agent",
                plistURL: url("/Users/alex/Library/LaunchAgents/com.veloxvpn.agent.plist"),
                programPath: "/Users/alex/Library/Application Support/VeloxVPN/velox-tunnel",
                programArguments: [
                    "/Users/alex/Library/Application Support/VeloxVPN/velox-tunnel",
                    "--daemon",
                ],
                scope: .userAgent,
                isEnabled: true,
                runAtLoad: true,
                keepAlive: true,
                isOrphanedBinary: true,
                associatedAppPath: nil,
                associatedAppName: nil,
                associatedAppExists: false,
                labelFromPlist: "com.veloxvpn.agent",
                requiresAdmin: false,
                canToggle: true,
                canRemove: true,
                fileSize: 548,
                expectedCanonicalParent: "/Users/alex/Library/LaunchAgents"
            ),
            StartupItem(
                label: "com.cloudsync.updater",
                plistURL: url("/Users/alex/Library/LaunchAgents/com.cloudsync.updater.plist"),
                programPath: "/Applications/CloudSync Drive.app/Contents/Resources/updater",
                programArguments: ["/Applications/CloudSync Drive.app/Contents/Resources/updater"],
                scope: .userAgent,
                isEnabled: false,
                runAtLoad: false,
                keepAlive: false,
                isOrphanedBinary: false,
                associatedAppPath: "/Applications/CloudSync Drive.app",
                associatedAppName: "CloudSync Drive",
                associatedAppExists: true,
                labelFromPlist: "com.cloudsync.updater",
                requiresAdmin: false,
                canToggle: true,
                canRemove: true,
                fileSize: 496,
                expectedCanonicalParent: "/Users/alex/Library/LaunchAgents"
            ),
            StartupItem(
                label: "io.pixelforge.license-daemon",
                plistURL: url("/Library/LaunchDaemons/io.pixelforge.license-daemon.plist"),
                programPath: "/Library/PrivilegedHelperTools/io.pixelforge.license-daemon",
                programArguments: ["/Library/PrivilegedHelperTools/io.pixelforge.license-daemon"],
                scope: .systemDaemon,
                isEnabled: true,
                runAtLoad: true,
                keepAlive: true,
                isOrphanedBinary: false,
                associatedAppPath: "/Applications/PixelForge Studio.app",
                associatedAppName: "PixelForge Studio",
                associatedAppExists: true,
                labelFromPlist: "io.pixelforge.license-daemon",
                requiresAdmin: true,
                canToggle: true,
                canRemove: true,
                fileSize: 684,
                expectedCanonicalParent: "/Library/LaunchDaemons"
            ),
            StartupItem(
                label: "com.codepulse.CodePulseLoginHelper",
                plistURL: url("/Applications/CodePulse IDE.app/Contents/Library/LoginItems/CodePulseLoginHelper.app"),
                programPath: nil,
                programArguments: [],
                scope: .appLoginItem,
                isEnabled: true,
                runAtLoad: true,
                keepAlive: false,
                isOrphanedBinary: false,
                associatedAppPath: "/Applications/CodePulse IDE.app",
                associatedAppName: "CodePulse IDE",
                associatedAppExists: true,
                labelFromPlist: nil,
                requiresAdmin: false,
                canToggle: false,
                canRemove: false,
                fileSize: 0,
                expectedCanonicalParent: "/Applications/CodePulse IDE.app/Contents/Library/LoginItems"
            ),
        ]

        let plists: [String: String] = [
            "/Users/alex/Library/LaunchAgents/com.novanote.helper.plist": makeLaunchPlistXML(
                label: "com.novanote.helper",
                programArguments: [
                    "/Applications/NovaNote.app/Contents/Library/LoginItems/NovaNoteHelper.app/Contents/MacOS/NovaNoteHelper",
                    "--background",
                ],
                runAtLoad: true,
                keepAlive: false
            ),
            "/Users/alex/Library/LaunchAgents/com.veloxvpn.agent.plist": makeLaunchPlistXML(
                label: "com.veloxvpn.agent",
                programArguments: [
                    "/Users/alex/Library/Application Support/VeloxVPN/velox-tunnel",
                    "--daemon",
                ],
                runAtLoad: true,
                keepAlive: true
            ),
            "/Users/alex/Library/LaunchAgents/com.cloudsync.updater.plist": makeLaunchPlistXML(
                label: "com.cloudsync.updater",
                programArguments: ["/Applications/CloudSync Drive.app/Contents/Resources/updater"],
                runAtLoad: false,
                keepAlive: false
            ),
            "/Library/LaunchDaemons/io.pixelforge.license-daemon.plist": makeLaunchPlistXML(
                label: "io.pixelforge.license-daemon",
                programArguments: ["/Library/PrivilegedHelperTools/io.pixelforge.license-daemon"],
                runAtLoad: true,
                keepAlive: true
            ),
        ]

        // MARK: Extensions
        let extensions: [ExtensionItem] = [
            ExtensionItem(
                name: "uBlock Origin Lite",
                identifier: "ddkjiahejlhfcafbddmgiahcphecmpfh",
                version: "2025.10",
                category: .browserChrome,
                path: url("/Users/alex/Library/Application Support/Google/Chrome/Default/Extensions/ddkjiahejlhfcafbddmgiahcphecmpfh/2025.10_0"),
                profileName: "Default",
                hostAppPath: url("/Applications/Google Chrome.app"),
                hostAppExists: true,
                pathExists: true,
                browserBundleID: "com.google.Chrome",
                size: 4_820_000,
                isEnabled: true,
                canToggle: false,
                canRemove: true,
                requiresAdmin: false,
                requiresReboot: false,
                isChecked: false,
                expectedCanonicalParent: "/Users/alex/Library/Application Support/Google/Chrome/Default/Extensions/ddkjiahejlhfcafbddmgiahcphecmpfh"
            ),
            ExtensionItem(
                name: "JSON Formatter Pro",
                identifier: "bcjindcccaagfpapjjmafapmmgkkhgoa",
                version: "0.7.2",
                category: .browserChrome,
                path: url("/Users/alex/Library/Application Support/Google/Chrome/Default/Extensions/bcjindcccaagfpapjjmafapmmgkkhgoa/0.7.2_0"),
                profileName: "Default",
                hostAppPath: url("/Applications/Google Chrome.app"),
                hostAppExists: true,
                pathExists: true,
                browserBundleID: "com.google.Chrome",
                size: 920_000,
                isEnabled: true,
                canToggle: false,
                canRemove: true,
                requiresAdmin: false,
                requiresReboot: false,
                isChecked: false,
                expectedCanonicalParent: "/Users/alex/Library/Application Support/Google/Chrome/Default/Extensions/bcjindcccaagfpapjjmafapmmgkkhgoa"
            ),
            ExtensionItem(
                name: "Multi-Account Containers",
                identifier: "@testpilot-containers",
                version: "8.2.0",
                category: .browserFirefox,
                path: url("/Users/alex/Library/Application Support/Firefox/Profiles/alex-default.release/extensions/@testpilot-containers.xpi"),
                profileName: "alex-default",
                hostAppPath: url("/Applications/Firefox.app"),
                hostAppExists: true,
                pathExists: true,
                browserBundleID: "org.mozilla.firefox",
                size: 1_340_000,
                isEnabled: true,
                canToggle: false,
                canRemove: true,
                requiresAdmin: false,
                requiresReboot: false,
                isChecked: false,
                expectedCanonicalParent: "/Users/alex/Library/Application Support/Firefox/Profiles/alex-default.release/extensions"
            ),
            ExtensionItem(
                name: "NovaNote Web Clipper",
                identifier: "com.novanote.desktop.SafariClipper",
                version: "3.4.2",
                category: .browserSafari,
                path: url("/Applications/NovaNote.app/Contents/PlugIns/SafariClipper.appex"),
                profileName: nil,
                hostAppPath: url("/Applications/NovaNote.app"),
                hostAppExists: true,
                pathExists: true,
                browserBundleID: nil,
                size: 3_150_000,
                isEnabled: true,
                canToggle: true,
                canRemove: false,
                requiresAdmin: false,
                requiresReboot: false,
                isChecked: false,
                expectedCanonicalParent: "/Applications/NovaNote.app/Contents/PlugIns"
            ),
            ExtensionItem(
                name: "SyntaxHighlightQL.qlgenerator",
                identifier: "com.codepulse.qlgenerator",
                version: "1.4.0",
                category: .quickLook,
                path: url("/Users/alex/Library/QuickLook/SyntaxHighlightQL.qlgenerator"),
                profileName: nil,
                hostAppPath: nil,
                hostAppExists: false,
                pathExists: true,
                browserBundleID: nil,
                size: 6_400_000,
                isEnabled: true,
                canToggle: false,
                canRemove: true,
                requiresAdmin: false,
                requiresReboot: false,
                isChecked: false,
                expectedCanonicalParent: "/Users/alex/Library/QuickLook"
            ),
            ExtensionItem(
                name: "AudioWeaveVirtual.driver",
                identifier: "audio.audioweave.virtualdriver",
                version: "2.9.4",
                category: .audioPlugin,
                path: url("/Library/Audio/Plug-Ins/HAL/AudioWeaveVirtual.driver"),
                profileName: nil,
                hostAppPath: url("/Applications/AudioWeave Pro.app"),
                hostAppExists: true,
                pathExists: true,
                browserBundleID: nil,
                size: 14_200_000,
                isEnabled: true,
                canToggle: false,
                canRemove: true,
                requiresAdmin: true,
                requiresReboot: true,
                isChecked: false,
                expectedCanonicalParent: "/Library/Audio/Plug-Ins/HAL"
            ),
        ]

        let extScanResult = ExtensionScanResult(
            items: extensions,
            needsFullDiskAccessForBrowsers: false,
            blockedBrowserNames: []
        )

        // MARK: Leftovers
        let leftovers: [LeftoverGroup] = [
            LeftoverGroup(
                id: "com.veloxvpn.client",
                groupName: "VeloxVPN",
                suspectedBundleID: "com.veloxvpn.client",
                confidence: .high,
                files: [
                    sf("/Users/alex/Library/Application Support/VeloxVPN", .applicationSupport, 184_000_000, files: 48, folders: 6, isDir: true, selected: true, confidence: .high, reason: "Orphaned App Support"),
                    sf("/Users/alex/Library/Caches/com.veloxvpn.client", .caches, 62_400_000, files: 120, folders: 12, isDir: true, selected: true, confidence: .high, reason: "Orphaned Bundle Cache"),
                    sf("/Users/alex/Library/LaunchAgents/com.veloxvpn.agent.plist", .launchAgents, 548, files: 1, folders: 0, isDir: false, selected: true, confidence: .high, reason: "Orphaned LaunchAgent"),
                    sf("/Library/Application Support/VeloxVPN", .applicationSupport, 12_800_000, files: 9, folders: 2, isDir: true, selected: false, requiresAdmin: true, systemScope: true, confidence: .high, reason: "System-Scope Leftover"),
                ],
                isChecked: true
            ),
            LeftoverGroup(
                id: "io.renderbox.app",
                groupName: "RenderBox 3D",
                suspectedBundleID: "io.renderbox.app",
                confidence: .high,
                files: [
                    sf("/Users/alex/Library/Application Support/RenderBox", .applicationSupport, 412_000_000, files: 214, folders: 18, isDir: true, selected: true, confidence: .high, reason: "Orphaned App Support"),
                    sf("/Users/alex/Library/Preferences/io.renderbox.app.plist", .preferences, 48_200, files: 1, folders: 0, isDir: false, selected: true, confidence: .high, reason: "Orphaned Preferences"),
                ],
                isChecked: true
            ),
            LeftoverGroup(
                id: "OldPodcastSync",
                groupName: "OldPodcastSync",
                suspectedBundleID: nil,
                confidence: .medium,
                files: [
                    sf("/Users/alex/Library/Caches/OldPodcastSync", .caches, 96_500_000, files: 86, folders: 8, isDir: true, selected: false, confidence: .medium, reason: "Unmatched Cache Folder"),
                ],
                isChecked: false
            ),
            LeftoverGroup(
                id: "com.sketchpad.legacy",
                groupName: "SketchPad Legacy",
                suspectedBundleID: "com.sketchpad.legacy",
                confidence: .medium,
                files: [
                    sf("/Users/alex/Library/Application Support/SketchPad Legacy", .applicationSupport, 28_400_000, files: 34, folders: 5, isDir: true, selected: false, confidence: .medium, reason: "Possible Legacy App Data"),
                ],
                isChecked: false
            ),
        ]

        // MARK: Volumes & Disk Space Analyzer Tree
        let macHD = VolumeStorageInfo(
            url: url("/"),
            name: "Macintosh HD",
            totalBytes: 1_000_000_000_000,
            availableBytes: 358_000_000_000,
            usedBytes: 642_000_000_000,
            isInternal: true,
            isRemovable: false,
            isReadOnly: false,
            fileSystemType: "apfs"
        )
        let backupVol = VolumeStorageInfo(
            url: url("/Volumes/Alex-Backup"),
            name: "Alex-Backup",
            totalBytes: 2_000_000_000_000,
            availableBytes: 1_110_000_000_000,
            usedBytes: 890_000_000_000,
            isInternal: false,
            isRemovable: true,
            isReadOnly: false,
            fileSystemType: "apfs"
        )

        let swiftStudioNode = DiskTreeNode(
            url: url("/Users/alex/Projects/swift-studio"),
            name: "swift-studio",
            isDirectory: true,
            bytes: 38_200_000_000,
            fileCount: 11_420,
            folderCount: 982,
            modificationDate: daysAgo(2),
            accessDate: daysAgo(0),
            children: [
                DiskTreeNode(
                    url: url("/Users/alex/Projects/swift-studio/.build"),
                    name: ".build",
                    isDirectory: true,
                    bytes: 21_400_000_000,
                    fileCount: 6_210,
                    folderCount: 410,
                    modificationDate: daysAgo(2),
                    accessDate: daysAgo(0),
                    expectedCanonicalParent: "/Users/alex/Projects/swift-studio"
                ),
                DiskTreeNode(
                    url: url("/Users/alex/Projects/swift-studio/vendor"),
                    name: "vendor",
                    isDirectory: true,
                    bytes: 16_800_000_000,
                    fileCount: 5_210,
                    folderCount: 570,
                    modificationDate: daysAgo(20),
                    accessDate: daysAgo(5),
                    children: [
                        DiskTreeNode(
                            url: url("/Users/alex/Projects/swift-studio/vendor/SwiftStudio-SDK.dmg"),
                            name: "SwiftStudio-SDK.dmg",
                            isDirectory: false,
                            bytes: 1_240_000_000,
                            fileCount: 1,
                            folderCount: 0,
                            modificationDate: daysAgo(90),
                            accessDate: daysAgo(45),
                            expectedCanonicalParent: "/Users/alex/Projects/swift-studio/vendor"
                        ),
                    ],
                    expectedCanonicalParent: "/Users/alex/Projects/swift-studio"
                ),
            ],
            expectedCanonicalParent: "/Users/alex/Projects"
        )

        let auroraNode = DiskTreeNode(
            url: url("/Users/alex/Projects/aurora-core"),
            name: "aurora-core",
            isDirectory: true,
            bytes: 18_600_000_000,
            fileCount: 4_850,
            folderCount: 430,
            modificationDate: daysAgo(5),
            accessDate: daysAgo(1),
            isProtected: true,
            expectedCanonicalParent: "/Users/alex/Projects"
        )

        let mlDatasetsNode = DiskTreeNode(
            url: url("/Users/alex/Projects/ml-datasets"),
            name: "ml-datasets",
            isDirectory: true,
            bytes: 15_600_000_000,
            fileCount: 1_920,
            folderCount: 112,
            modificationDate: daysAgo(65),
            accessDate: daysAgo(30),
            children: [
                DiskTreeNode(
                    url: url("/Users/alex/Projects/ml-datasets/training-corpus-v2.tar.gz"),
                    name: "training-corpus-v2.tar.gz",
                    isDirectory: false,
                    bytes: 2_950_000_000,
                    fileCount: 1,
                    folderCount: 0,
                    modificationDate: daysAgo(65),
                    accessDate: daysAgo(30),
                    expectedCanonicalParent: "/Users/alex/Projects/ml-datasets"
                ),
            ],
            expectedCanonicalParent: "/Users/alex/Projects"
        )

        let projectsNode = DiskTreeNode(
            url: url("/Users/alex/Projects"),
            name: "Projects",
            isDirectory: true,
            bytes: 72_400_000_000,
            fileCount: 18_190,
            folderCount: 1_527,
            modificationDate: daysAgo(2),
            accessDate: daysAgo(0),
            children: [swiftStudioNode, auroraNode, mlDatasetsNode],
            expectedCanonicalParent: "/Users/alex"
        )

        let libraryNode = DiskTreeNode(
            url: url("/Users/alex/Library"),
            name: "Library",
            isDirectory: true,
            bytes: 48_900_000_000,
            fileCount: 19_420,
            folderCount: 2_183,
            modificationDate: daysAgo(0),
            accessDate: daysAgo(0),
            children: [
                DiskTreeNode(
                    url: url("/Users/alex/Library/Developer"),
                    name: "Developer",
                    isDirectory: true,
                    bytes: 26_400_000_000,
                    fileCount: 9_800,
                    folderCount: 1_040,
                    modificationDate: daysAgo(1),
                    accessDate: daysAgo(0),
                    expectedCanonicalParent: "/Users/alex/Library"
                ),
                DiskTreeNode(
                    url: url("/Users/alex/Library/Caches"),
                    name: "Caches",
                    isDirectory: true,
                    bytes: 14_200_000_000,
                    fileCount: 7_110,
                    folderCount: 820,
                    modificationDate: daysAgo(0),
                    accessDate: daysAgo(0),
                    expectedCanonicalParent: "/Users/alex/Library"
                ),
                DiskTreeNode(
                    url: url("/Users/alex/Library/Application Support"),
                    name: "Application Support",
                    isDirectory: true,
                    bytes: 8_300_000_000,
                    fileCount: 2_510,
                    folderCount: 320,
                    modificationDate: daysAgo(3),
                    accessDate: daysAgo(1),
                    expectedCanonicalParent: "/Users/alex/Library"
                ),
            ],
            expectedCanonicalParent: "/Users/alex"
        )

        let downloadsNode = DiskTreeNode(
            url: url("/Users/alex/Downloads"),
            name: "Downloads",
            isDirectory: true,
            bytes: 32_800_000_000,
            fileCount: 248,
            folderCount: 24,
            modificationDate: daysAgo(5),
            accessDate: daysAgo(2),
            children: [
                DiskTreeNode(
                    url: url("/Users/alex/Downloads/macOS-15-Installer.dmg"),
                    name: "macOS-15-Installer.dmg",
                    isDirectory: false,
                    bytes: 14_200_000_000,
                    fileCount: 1,
                    folderCount: 0,
                    modificationDate: daysAgo(140),
                    accessDate: daysAgo(120),
                    expectedCanonicalParent: "/Users/alex/Downloads"
                ),
                DiskTreeNode(
                    url: url("/Users/alex/Downloads/4K-Product-Demo-Raw.mov"),
                    name: "4K-Product-Demo-Raw.mov",
                    isDirectory: false,
                    bytes: 9_840_000_000,
                    fileCount: 1,
                    folderCount: 0,
                    modificationDate: daysAgo(210),
                    accessDate: daysAgo(190),
                    expectedCanonicalParent: "/Users/alex/Downloads"
                ),
                DiskTreeNode(
                    url: url("/Users/alex/Downloads/SwiftStudio-SDK-Backup.zip"),
                    name: "SwiftStudio-SDK-Backup.zip",
                    isDirectory: false,
                    bytes: 4_620_000_000,
                    fileCount: 1,
                    folderCount: 0,
                    modificationDate: daysAgo(110),
                    accessDate: daysAgo(95),
                    expectedCanonicalParent: "/Users/alex/Downloads"
                ),
                DiskTreeNode(
                    url: url("/Users/alex/Downloads/design-system-assets.tar.gz"),
                    name: "design-system-assets.tar.gz",
                    isDirectory: false,
                    bytes: 2_840_000_000,
                    fileCount: 1,
                    folderCount: 0,
                    modificationDate: daysAgo(45),
                    accessDate: daysAgo(25),
                    expectedCanonicalParent: "/Users/alex/Downloads"
                ),
            ],
            expectedCanonicalParent: "/Users/alex"
        )

        let moviesNode = DiskTreeNode(
            url: url("/Users/alex/Movies"),
            name: "Movies",
            isDirectory: true,
            bytes: 19_800_000_000,
            fileCount: 64,
            folderCount: 8,
            modificationDate: daysAgo(15),
            accessDate: daysAgo(10),
            children: [
                DiskTreeNode(
                    url: url("/Users/alex/Movies/ScreenCapture-2025-Q3.mov"),
                    name: "ScreenCapture-2025-Q3.mov",
                    isDirectory: false,
                    bytes: 11_400_000_000,
                    fileCount: 1,
                    folderCount: 0,
                    modificationDate: daysAgo(125),
                    accessDate: daysAgo(110),
                    expectedCanonicalParent: "/Users/alex/Movies"
                ),
                DiskTreeNode(
                    url: url("/Users/alex/Movies/Podcast-Episode-14.mp4"),
                    name: "Podcast-Episode-14.mp4",
                    isDirectory: false,
                    bytes: 8_400_000_000,
                    fileCount: 1,
                    folderCount: 0,
                    modificationDate: daysAgo(95),
                    accessDate: daysAgo(80),
                    expectedCanonicalParent: "/Users/alex/Movies"
                ),
            ],
            expectedCanonicalParent: "/Users/alex"
        )

        let documentsNode = DiskTreeNode(
            url: url("/Users/alex/Documents"),
            name: "Documents",
            isDirectory: true,
            bytes: 8_400_000_000,
            fileCount: 3_110,
            folderCount: 242,
            modificationDate: daysAgo(1),
            accessDate: daysAgo(0),
            children: [
                DiskTreeNode(
                    url: url("/Users/alex/Documents/Architecture-RFCs"),
                    name: "Architecture-RFCs",
                    isDirectory: true,
                    bytes: 4_200_000_000,
                    fileCount: 840,
                    folderCount: 64,
                    modificationDate: daysAgo(4),
                    accessDate: daysAgo(1),
                    expectedCanonicalParent: "/Users/alex/Documents"
                ),
                DiskTreeNode(
                    url: url("/Users/alex/Documents/Tax-2025-Archive.pdf"),
                    name: "Tax-2025-Archive.pdf",
                    isDirectory: false,
                    bytes: 12_400_000,
                    fileCount: 1,
                    folderCount: 0,
                    modificationDate: daysAgo(60),
                    accessDate: daysAgo(12),
                    isProtected: true,
                    expectedCanonicalParent: "/Users/alex/Documents"
                ),
                DiskTreeNode(
                    url: url("/Users/alex/Documents/Q4-Release-Notes.md"),
                    name: "Q4-Release-Notes.md",
                    isDirectory: false,
                    bytes: 48_200,
                    fileCount: 1,
                    folderCount: 0,
                    modificationDate: daysAgo(1),
                    accessDate: daysAgo(0),
                    expectedCanonicalParent: "/Users/alex/Documents"
                ),
                DiskTreeNode(
                    url: url("/Users/alex/Documents/System-Health-Report.json"),
                    name: "System-Health-Report.json",
                    isDirectory: false,
                    bytes: 18_640,
                    fileCount: 1,
                    folderCount: 0,
                    modificationDate: daysAgo(2),
                    accessDate: daysAgo(1),
                    expectedCanonicalParent: "/Users/alex/Documents"
                ),
            ],
            expectedCanonicalParent: "/Users/alex"
        )

        let desktopNode = DiskTreeNode(
            url: url("/Users/alex/Desktop"),
            name: "Desktop",
            isDirectory: true,
            bytes: 3_600_000_000,
            fileCount: 1_778,
            folderCount: 144,
            modificationDate: daysAgo(3),
            accessDate: daysAgo(1),
            children: [
                DiskTreeNode(
                    url: url("/Users/alex/Desktop/Demo-Mockups"),
                    name: "Demo-Mockups",
                    isDirectory: true,
                    bytes: 2_400_000_000,
                    fileCount: 412,
                    folderCount: 38,
                    modificationDate: daysAgo(3),
                    accessDate: daysAgo(1),
                    expectedCanonicalParent: "/Users/alex/Desktop"
                ),
                DiskTreeNode(
                    url: url("/Users/alex/Desktop/Release-Checklist.md"),
                    name: "Release-Checklist.md",
                    isDirectory: false,
                    bytes: 14_800,
                    fileCount: 1,
                    folderCount: 0,
                    modificationDate: daysAgo(1),
                    accessDate: daysAgo(0),
                    expectedCanonicalParent: "/Users/alex/Desktop"
                ),
            ],
            expectedCanonicalParent: "/Users/alex"
        )

        let rootDiskTree = DiskTreeNode(
            url: url("/Users/alex"),
            name: "alex",
            isDirectory: true,
            bytes: 186_900_000_000,
            fileCount: 42_815,
            folderCount: 4_136,
            modificationDate: daysAgo(0),
            accessDate: daysAgo(0),
            children: [projectsNode, libraryNode, downloadsNode, moviesNode, documentsNode, desktopNode],
            expectedCanonicalParent: "/Users"
        )

        let appsDiskTree = DiskTreeNode(
            url: url("/Applications"),
            name: "Applications",
            isDirectory: true,
            bytes: 3_107_500_000,
            fileCount: 9_810,
            folderCount: 788,
            modificationDate: daysAgo(7),
            accessDate: daysAgo(0),
            children: apps.map { app in
                DiskTreeNode(
                    url: app.url,
                    name: app.url.lastPathComponent,
                    isDirectory: true,
                    isPackage: true,
                    bytes: UInt64(max(0, app.bundleSize ?? 0)),
                    fileCount: app.bundleFileCount ?? 1,
                    folderCount: app.bundleFolderCount ?? 0,
                    modificationDate: app.modifiedDate,
                    accessDate: app.lastUsedDate,
                    isProtected: app.isProtected,
                    expectedCanonicalParent: "/Applications"
                )
            }.sorted { $0.bytes > $1.bytes },
            expectedCanonicalParent: "/"
        )

        // MARK: File Browser Favorites, Entries & Previews
        let favs: [FileBrowserFavorite] = [
            FileBrowserFavorite(kind: .home, title: "alex", url: url("/Users/alex"), isAccessible: true),
            FileBrowserFavorite(kind: .desktop, title: "Desktop", url: url("/Users/alex/Desktop"), isAccessible: true),
            FileBrowserFavorite(kind: .documents, title: "Documents", url: url("/Users/alex/Documents"), isAccessible: true),
            FileBrowserFavorite(kind: .downloads, title: "Downloads", url: url("/Users/alex/Downloads"), isAccessible: true),
            FileBrowserFavorite(kind: .applications, title: "Applications", url: url("/Applications"), isAccessible: true),
            FileBrowserFavorite(kind: .caches, title: "Caches", url: url("/Users/alex/Library/Caches"), isAccessible: true),
            FileBrowserFavorite(kind: .volume, title: "Macintosh HD", url: url("/"), isAccessible: true),
        ]

        let documentsEntries: [FileBrowserEntry] = [
            fbDir("/Users/alex/Documents/Architecture-RFCs", size: 4_200_000_000, modDays: 4, parent: "/Users/alex/Documents"),
            fbDir("/Users/alex/Documents/.git-templates", size: 320_000, modDays: 32, hidden: true, parent: "/Users/alex/Documents"),
            fbFile("/Users/alex/Documents/Q4-Release-Notes.md", size: 48_200, modDays: 1, uti: "net.daringfireball.markdown", kindDesc: "Markdown Document", parent: "/Users/alex/Documents"),
            fbFile("/Users/alex/Documents/System-Health-Report.json", size: 18_640, modDays: 2, uti: "public.json", kindDesc: "JSON Document", parent: "/Users/alex/Documents"),
            fbFile("/Users/alex/Documents/workspace-config.plist", size: 4_120, modDays: 6, uti: "com.apple.property-list", kindDesc: "Property List", parent: "/Users/alex/Documents"),
            fbFile("/Users/alex/Documents/Tax-2025-Archive.pdf", size: 12_400_000, modDays: 60, isProtected: true, protectionReason: "Protected by user Skip List", uti: "com.adobe.pdf", kindDesc: "PDF Document", parent: "/Users/alex/Documents"),
            fbFile("/Users/alex/Documents/Release-Keys.lock", size: 2_048, modDays: 18, isImmutable: true, uti: "public.data", kindDesc: "Locked Configuration", parent: "/Users/alex/Documents"),
            fbFile("/Users/alex/Documents/Q3-Product-Deck.pdf", size: 84_500_000, modDays: 75, uti: "com.adobe.pdf", kindDesc: "PDF Document", parent: "/Users/alex/Documents"),
            fbSymlink("/Users/alex/Documents/latest-rfc-link", modDays: 5, parent: "/Users/alex/Documents"),
        ]

        let homeEntries: [FileBrowserEntry] = [
            fbDir("/Users/alex/Projects", size: 72_400_000_000, modDays: 2, parent: "/Users/alex"),
            fbDir("/Users/alex/Library", size: 48_900_000_000, modDays: 0, parent: "/Users/alex"),
            fbDir("/Users/alex/Downloads", size: 32_800_000_000, modDays: 5, parent: "/Users/alex"),
            fbDir("/Users/alex/Movies", size: 19_800_000_000, modDays: 15, parent: "/Users/alex"),
            fbDir("/Users/alex/Documents", size: 8_400_000_000, modDays: 1, parent: "/Users/alex"),
            fbDir("/Users/alex/Desktop", size: 3_600_000_000, modDays: 3, parent: "/Users/alex"),
            fbDir("/Users/alex/.Trash", size: 952_000_000, modDays: 2, hidden: true, parent: "/Users/alex"),
            fbFile("/Users/alex/.zshrc", size: 2_840, modDays: 14, hidden: true, uti: "public.plain-text", kindDesc: "Shell Configuration", parent: "/Users/alex"),
        ]

        let downloadsEntries: [FileBrowserEntry] = [
            fbFile("/Users/alex/Downloads/macOS-15-Installer.dmg", size: 14_200_000_000, modDays: 140, uti: "com.apple.disk-image-udif", kindDesc: "Disk Image", parent: "/Users/alex/Downloads"),
            fbFile("/Users/alex/Downloads/4K-Product-Demo-Raw.mov", size: 9_840_000_000, modDays: 210, uti: "com.apple.quicktime-movie", kindDesc: "QuickTime Movie", parent: "/Users/alex/Downloads"),
            fbFile("/Users/alex/Downloads/SwiftStudio-SDK-Backup.zip", size: 4_620_000_000, modDays: 110, uti: "public.zip-archive", kindDesc: "ZIP Archive", parent: "/Users/alex/Downloads"),
            fbFile("/Users/alex/Downloads/design-system-assets.tar.gz", size: 2_840_000_000, modDays: 45, uti: "org.gnu.gnu-zip-tar-archive", kindDesc: "Gzip Tar Archive", parent: "/Users/alex/Downloads"),
            fbFile("/Users/alex/Downloads/SwiftStudio-SDK (1).dmg", size: 1_240_000_000, modDays: 12, uti: "com.apple.disk-image-udif", kindDesc: "Disk Image", parent: "/Users/alex/Downloads"),
        ]

        let projectsEntries: [FileBrowserEntry] = [
            fbDir("/Users/alex/Projects/swift-studio", size: 38_200_000_000, modDays: 2, parent: "/Users/alex/Projects"),
            fbDir("/Users/alex/Projects/aurora-core", size: 18_600_000_000, modDays: 5, isProtected: true, protectionReason: "Protected by user Skip List", parent: "/Users/alex/Projects"),
            fbDir("/Users/alex/Projects/ml-datasets", size: 15_600_000_000, modDays: 65, parent: "/Users/alex/Projects"),
        ]

        let desktopEntries: [FileBrowserEntry] = [
            fbDir("/Users/alex/Desktop/Demo-Mockups", size: 2_400_000_000, modDays: 3, parent: "/Users/alex/Desktop"),
            fbFile("/Users/alex/Desktop/Release-Checklist.md", size: 14_800, modDays: 1, uti: "net.daringfireball.markdown", kindDesc: "Markdown Document", parent: "/Users/alex/Desktop"),
            fbFile("/Users/alex/Desktop/Q3-Product-Deck-Final.pdf", size: 84_500_000, modDays: 20, uti: "com.adobe.pdf", kindDesc: "PDF Document", parent: "/Users/alex/Desktop"),
        ]

        let cachesEntries: [FileBrowserEntry] = [
            fbDir("/Users/alex/Library/Caches/com.novanote.desktop", size: 418_000_000, modDays: 1, parent: "/Users/alex/Library/Caches"),
            fbDir("/Users/alex/Library/Caches/io.pixelforge.studio", size: 612_000_000, modDays: 3, parent: "/Users/alex/Library/Caches"),
            fbDir("/Users/alex/Library/Caches/Google", size: 785_000_000, modDays: 0, parent: "/Users/alex/Library/Caches"),
            fbDir("/Users/alex/Library/Caches/Homebrew", size: 1_140_000_000, modDays: 9, parent: "/Users/alex/Library/Caches"),
        ]

        let applicationsEntries: [FileBrowserEntry] = apps.map { app in
            FileBrowserEntry(
                url: app.url,
                name: app.url.lastPathComponent,
                kind: .package,
                sizeBytes: app.bundleSize ?? 0,
                modificationDate: app.modifiedDate,
                createdDate: app.modifiedDate,
                isDirectory: true,
                isPackage: true,
                isSymbolicLink: false,
                isSymlinkBroken: false,
                isHidden: false,
                isDataless: false,
                isUserImmutable: false,
                isSIPRestricted: false,
                isProtected: app.isProtected,
                protectionReason: app.isProtected ? "Protected application bundle ID" : nil,
                requiresAdmin: app.requiresAdmin,
                utiIdentifier: "com.apple.application-bundle",
                kindDescription: "Application",
                expectedCanonicalParent: "/Applications"
            )
        }

        let dirMap: [String: [FileBrowserEntry]] = [
            "/Users/alex": homeEntries,
            "/Users/alex/Documents": documentsEntries,
            "/Users/alex/Downloads": downloadsEntries,
            "/Users/alex/Projects": projectsEntries,
            "/Users/alex/Desktop": desktopEntries,
            "/Users/alex/Library/Caches": cachesEntries,
            "/Applications": applicationsEntries,
        ]

        let releaseNotesText = """
        # MacSweep Q4 Release Notes

        - Target: macOS 14+ (arm64/x86_64)
        - Core: Swift 6 strict concurrency
        - Safety Guards:
          - Canonical parent TOCTOU check
          - Trash-first & Finder Put Back
          - Single-volume & hardlink dedup
        - Storage Summary (/Users/alex):
          - Projects:  72.4 GB
          - Library:   48.9 GB
          - Downloads: 32.8 GB
        """

        let healthReportText = """
        {
          "workspace": "/Users/alex/Projects/swift-studio",
          "hostProfile": "Workstation-M4",
          "safetyBoundary": "strict",
          "volume": {
            "name": "Macintosh HD",
            "usedGB": 642,
            "availableGB": 358
          },
          "checksPassed": true
        }
        """

        let dmgHexDump = """
        00000000  78 01 73 79 6E 74 68 65  |x.synthe|
        00000008  74 69 63 2D 64 6D 67 2D  |tic-dmg-|
        00000010  68 65 61 64 65 72 20 6D  |header m|
        00000018  61 63 4F 53 20 31 35 20  |acOS 15 |
        00000020  41 50 46 53 20 43 6F 6E  |APFS Con|
        00000028  74 61 69 6E 65 72 20 76  |tainer v|
        00000030  32 2E 34 00 00 00 00 00  |2.4.....|
        00000038  4B 4F 4C 59 00 00 00 01  |KOLY....|
        """

        var previews: [String: FilePreviewPayload] = [:]
        for entry in documentsEntries + homeEntries + downloadsEntries + projectsEntries + desktopEntries + cachesEntries + applicationsEntries {
            let meta = makeMetadata(from: entry)
            let content: FilePreviewContent
            if entry.isSymbolicLink {
                content = .unavailable(reason: .symbolicLink)
            } else if entry.isDirectory {
                content = .unavailable(reason: .directory)
            } else if entry.url.path == "/Users/alex/Documents/Q4-Release-Notes.md" {
                content = .text(releaseNotesText, encodingDescription: "UTF-8", isTruncated: false, totalBytes: entry.sizeBytes)
            } else if entry.url.path == "/Users/alex/Documents/System-Health-Report.json" {
                content = .text(healthReportText, encodingDescription: "UTF-8", isTruncated: false, totalBytes: entry.sizeBytes)
            } else if entry.url.path == "/Users/alex/Documents/workspace-config.plist" {
                let plistBody = makeLaunchPlistXML(
                    label: "com.alex.workspace.sync",
                    programArguments: ["/Users/alex/Projects/swift-studio/bin/sync-tool", "--watch"],
                    runAtLoad: true,
                    keepAlive: false
                )
                content = .text(plistBody, encodingDescription: "UTF-8 XML", isTruncated: false, totalBytes: entry.sizeBytes)
            } else if entry.url.path == "/Users/alex/Downloads/macOS-15-Installer.dmg" {
                content = .hexDump(dmgHexDump, byteCount: 64, isTruncated: true, totalBytes: entry.sizeBytes)
            } else if entry.url.pathExtension.lowercased() == "md" {
                content = .text("# \(entry.name)\n\nSanitized demo preview for `/Users/alex`.\n", encodingDescription: "UTF-8", isTruncated: false, totalBytes: entry.sizeBytes)
            } else {
                content = .hexDump(dmgHexDump, byteCount: 64, isTruncated: true, totalBytes: entry.sizeBytes)
            }
            previews[entry.url.path] = FilePreviewPayload(
                metadata: meta,
                content: content,
                isProtected: entry.isProtected,
                protectionReason: entry.protectionReason
            )
        }

        // MARK: Junk & Cache Cleaner
        let junkCats: [JunkCategoryItem] = [
            JunkCategoryItem(
                category: .userCaches,
                title: "User & App Caches",
                description: "Reclaimable application cache directories under ~/Library/Caches.",
                entries: [
                    JunkEntry(
                        url: url("/Users/alex/Library/Caches/JetBrains/CodePulse2026"),
                        name: "JetBrains / CodePulse2026",
                        category: .userCaches,
                        subgroup: "JetBrains",
                        bytes: 890_000_000,
                        isDirectory: true,
                        isSelected: true,
                        expectedCanonicalParent: "/Users/alex/Library/Caches/JetBrains",
                        isRecommendedSafe: true
                    ),
                    JunkEntry(
                        url: url("/Users/alex/Library/Caches/io.pixelforge.studio"),
                        name: "io.pixelforge.studio",
                        category: .userCaches,
                        bytes: 612_000_000,
                        isDirectory: true,
                        isSelected: true,
                        expectedCanonicalParent: "/Users/alex/Library/Caches",
                        isRecommendedSafe: true
                    ),
                    JunkEntry(
                        url: url("/Users/alex/Library/Caches/com.novanote.desktop"),
                        name: "com.novanote.desktop",
                        category: .userCaches,
                        bytes: 418_000_000,
                        isDirectory: true,
                        isSelected: true,
                        expectedCanonicalParent: "/Users/alex/Library/Caches",
                        isRecommendedSafe: true
                    ),
                    JunkEntry(
                        url: url("/Users/alex/Library/Caches/Adobe/PixelBridge"),
                        name: "Adobe / PixelBridge",
                        category: .userCaches,
                        subgroup: "Adobe",
                        bytes: 324_000_000,
                        isDirectory: true,
                        isSelected: true,
                        expectedCanonicalParent: "/Users/alex/Library/Caches/Adobe",
                        isRecommendedSafe: true
                    ),
                ],
                safetyNote: "Apple system caches, MacSweep self-caches, and bare shared vendor roots (e.g. Google, Microsoft, Adobe) are excluded automatically."
            ),
            JunkCategoryItem(
                category: .logs,
                title: "Logs & Crash Reports",
                description: "Application diagnostic logs and crash reports.",
                entries: [
                    JunkEntry(
                        url: url("/Users/alex/Library/Logs/NovaNote"),
                        name: "NovaNote Logs",
                        category: .logs,
                        bytes: 42_800_000,
                        isDirectory: true,
                        isSelected: true,
                        expectedCanonicalParent: "/Users/alex/Library/Logs",
                        isRecommendedSafe: true
                    ),
                    JunkEntry(
                        url: url("/Users/alex/Library/Logs/DiagnosticReports/PixelForge-2025-10-01.ips"),
                        name: "PixelForge-2025-10-01.ips",
                        category: .logs,
                        subgroup: "DiagnosticReports",
                        bytes: 18_400_000,
                        isDirectory: false,
                        isSelected: true,
                        expectedCanonicalParent: "/Users/alex/Library/Logs/DiagnosticReports",
                        isRecommendedSafe: true
                    ),
                    JunkEntry(
                        url: url("/Library/Logs/DiagnosticReports/KernelPanic-Sample.panic"),
                        name: "KernelPanic-Sample.panic",
                        category: .logs,
                        subgroup: "System Logs",
                        bytes: 24_000_000,
                        isDirectory: false,
                        isSelected: false,
                        requiresAdmin: true,
                        expectedCanonicalParent: "/Library/Logs/DiagnosticReports",
                        safetyReason: "System log requires administrator privileges",
                        isRecommendedSafe: false
                    ),
                ],
                safetyNote: "Parent log folders are preserved. System logs under /Library/Logs require administrator privileges and stay unchecked by default."
            ),
            JunkCategoryItem(
                category: .browserCaches,
                title: "Browser Caches",
                description: "Disposable web cache files for third-party browsers.",
                entries: [
                    JunkEntry(
                        url: url("/Users/alex/Library/Caches/Google/Chrome"),
                        name: "Google Chrome — Default",
                        category: .browserCaches,
                        subgroup: "Google Chrome",
                        bytes: 785_000_000,
                        isDirectory: true,
                        isSelected: true,
                        expectedCanonicalParent: "/Users/alex/Library/Caches/Google",
                        browserBundleID: "com.google.Chrome",
                        isRecommendedSafe: true
                    ),
                    JunkEntry(
                        url: url("/Users/alex/Library/Caches/Firefox/Profiles/alex-default"),
                        name: "Firefox — alex-default",
                        category: .browserCaches,
                        subgroup: "Firefox",
                        bytes: 246_000_000,
                        isDirectory: true,
                        isSelected: true,
                        expectedCanonicalParent: "/Users/alex/Library/Caches/Firefox/Profiles",
                        browserBundleID: "org.mozilla.firefox",
                        isRecommendedSafe: true
                    ),
                    JunkEntry(
                        url: url("/Users/alex/Library/Caches/BraveSoftware/Brave-Browser"),
                        name: "Brave — Brave-Browser",
                        category: .browserCaches,
                        subgroup: "Brave",
                        bytes: 164_000_000,
                        isDirectory: true,
                        isSelected: true,
                        expectedCanonicalParent: "/Users/alex/Library/Caches/BraveSoftware",
                        browserBundleID: "com.brave.Browser",
                        isRecommendedSafe: true
                    ),
                ],
                safetyNote: "Only cache directories are targeted; bookmarks, cookies, history, and passwords are never touched."
            ),
            JunkCategoryItem(
                category: .developerCaches,
                title: "Developer Caches",
                description: "Xcode DerivedData, simulator caches, and package manager download caches.",
                entries: [
                    JunkEntry(
                        url: url("/Users/alex/Library/Developer/Xcode/DerivedData/NovaNote-d8f3a1c2"),
                        name: "NovaNote-d8f3a1c2",
                        category: .developerCaches,
                        subgroup: "Xcode DerivedData",
                        bytes: 4_820_000_000,
                        isDirectory: true,
                        isSelected: true,
                        expectedCanonicalParent: "/Users/alex/Library/Developer/Xcode/DerivedData",
                        isRecommendedSafe: true
                    ),
                    JunkEntry(
                        url: url("/Users/alex/Library/Developer/CoreSimulator/Caches"),
                        name: "CoreSimulator Caches",
                        category: .developerCaches,
                        subgroup: "Xcode",
                        bytes: 2_150_000_000,
                        isDirectory: true,
                        isSelected: true,
                        expectedCanonicalParent: "/Users/alex/Library/Developer/CoreSimulator",
                        isRecommendedSafe: true
                    ),
                    JunkEntry(
                        url: url("/Users/alex/Library/Caches/Homebrew"),
                        name: "Homebrew Downloads",
                        category: .developerCaches,
                        subgroup: "Homebrew",
                        bytes: 1_140_000_000,
                        isDirectory: true,
                        isSelected: true,
                        expectedCanonicalParent: "/Users/alex/Library/Caches",
                        isRecommendedSafe: true
                    ),
                    JunkEntry(
                        url: url("/Users/alex/.npm/_cacache"),
                        name: "npm Cache",
                        category: .developerCaches,
                        subgroup: "npm",
                        bytes: 486_000_000,
                        isDirectory: true,
                        isSelected: true,
                        expectedCanonicalParent: "/Users/alex/.npm",
                        isRecommendedSafe: true
                    ),
                    JunkEntry(
                        url: url("/Users/alex/Library/Developer/Xcode/Archives/2025-09-28"),
                        name: "2025-09-28",
                        category: .developerCaches,
                        subgroup: "Xcode Archives",
                        bytes: 3_400_000_000,
                        isDirectory: true,
                        isSelected: false,
                        expectedCanonicalParent: "/Users/alex/Library/Developer/Xcode/Archives",
                        safetyReason: "Contains signed app archives; unchecked by default",
                        isRecommendedSafe: false
                    ),
                ],
                safetyNote: "Xcode Archives and DeviceSupport are unchecked by default to protect signed builds and symbols."
            ),
            JunkCategoryItem(
                category: .trash,
                title: "Trash Contents",
                description: "Items currently inside your Trash folder.",
                entries: [
                    JunkEntry(
                        url: url("/Users/alex/.Trash/old-prototype-build.zip"),
                        name: "old-prototype-build.zip",
                        category: .trash,
                        bytes: 640_000_000,
                        isDirectory: false,
                        isSelected: true,
                        expectedCanonicalParent: "/Users/alex/.Trash",
                        isRecommendedSafe: true
                    ),
                    JunkEntry(
                        url: url("/Users/alex/.Trash/unused-textures"),
                        name: "unused-textures",
                        category: .trash,
                        bytes: 312_000_000,
                        isDirectory: true,
                        isSelected: true,
                        expectedCanonicalParent: "/Users/alex/.Trash",
                        isRecommendedSafe: true
                    ),
                ],
                safetyNote: "Items inside Trash can only be permanently deleted to free disk space."
            ),
        ]

        let junkTotal = junkCats.reduce(into: UInt64(0)) { $0 &+= $1.totalBytes }
        let junkResult = JunkScanResult(
            categories: junkCats,
            totalBytes: junkTotal,
            needsFullDiskAccess: false,
            blockedLocations: [],
            elapsedSeconds: 0.42
        )

        // MARK: Large Files
        let largeFileItems: [LargeFileItem] = [
            LargeFileItem(
                url: url("/Users/alex/Downloads/macOS-15-Installer.dmg"),
                name: "macOS-15-Installer.dmg",
                bytes: 14_200_000_000,
                modificationDate: daysAgo(140),
                accessDate: daysAgo(120),
                category: .installer,
                expectedCanonicalParent: "/Users/alex/Downloads",
                relativePathFromRoot: "Downloads/macOS-15-Installer.dmg"
            ),
            LargeFileItem(
                url: url("/Users/alex/Movies/ScreenCapture-2025-Q3.mov"),
                name: "ScreenCapture-2025-Q3.mov",
                bytes: 11_400_000_000,
                modificationDate: daysAgo(125),
                accessDate: daysAgo(110),
                category: .video,
                expectedCanonicalParent: "/Users/alex/Movies",
                relativePathFromRoot: "Movies/ScreenCapture-2025-Q3.mov"
            ),
            LargeFileItem(
                url: url("/Users/alex/Downloads/4K-Product-Demo-Raw.mov"),
                name: "4K-Product-Demo-Raw.mov",
                bytes: 9_840_000_000,
                modificationDate: daysAgo(210),
                accessDate: daysAgo(190),
                category: .video,
                expectedCanonicalParent: "/Users/alex/Downloads",
                relativePathFromRoot: "Downloads/4K-Product-Demo-Raw.mov"
            ),
            LargeFileItem(
                url: url("/Users/alex/Downloads/SwiftStudio-SDK-Backup.zip"),
                name: "SwiftStudio-SDK-Backup.zip",
                bytes: 4_620_000_000,
                modificationDate: daysAgo(110),
                accessDate: daysAgo(95),
                category: .diskImageAndArchive,
                expectedCanonicalParent: "/Users/alex/Downloads",
                relativePathFromRoot: "Downloads/SwiftStudio-SDK-Backup.zip"
            ),
            LargeFileItem(
                url: url("/Users/alex/Projects/ml-datasets/training-corpus-v2.tar.gz"),
                name: "training-corpus-v2.tar.gz",
                bytes: 2_950_000_000,
                modificationDate: daysAgo(65),
                accessDate: daysAgo(30),
                category: .diskImageAndArchive,
                expectedCanonicalParent: "/Users/alex/Projects/ml-datasets",
                relativePathFromRoot: "Projects/ml-datasets/training-corpus-v2.tar.gz"
            ),
            LargeFileItem(
                url: url("/Users/alex/Music/Mastering-Stems-2024.wav"),
                name: "Mastering-Stems-2024.wav",
                bytes: 1_180_000_000,
                modificationDate: daysAgo(280),
                accessDate: daysAgo(240),
                category: .audio,
                expectedCanonicalParent: "/Users/alex/Music",
                relativePathFromRoot: "Music/Mastering-Stems-2024.wav"
            ),
        ]

        // Add preview entries for large files if not already present
        for item in largeFileItems where previews[item.url.path] == nil {
            let meta = FileMetadataInfo(
                url: item.url,
                name: item.name,
                kind: .regularFile,
                sizeBytes: Int64(item.bytes),
                allocatedSizeBytes: Int64(item.bytes),
                createdDate: item.modificationDate,
                modifiedDate: item.modificationDate,
                accessedDate: item.accessDate,
                posixPermissions: 0o644,
                ownerUID: 501,
                groupGID: 20,
                isDirectory: false,
                isPackage: false,
                isSymbolicLink: false,
                isSymlinkBroken: false,
                symlinkTarget: nil,
                resolvedTargetPath: nil,
                isUserImmutable: item.isUserImmutable,
                isSIPRestricted: false,
                isHidden: false,
                isDataless: false,
                utiIdentifier: "public.data",
                kindDescription: item.category == .video ? "MPEG-4 / QuickTime Video" : "Archive / Media File",
                expectedCanonicalParent: item.expectedCanonicalParent
            )
            previews[item.url.path] = FilePreviewPayload(
                metadata: meta,
                content: .hexDump(dmgHexDump, byteCount: 64, isTruncated: true, totalBytes: Int64(item.bytes)),
                isProtected: item.isProtected,
                protectionReason: nil
            )
        }

        // MARK: Duplicate Groups (3-Stage SHA-256)
        let dupGroups: [DuplicateGroup] = [
            DuplicateGroup(
                sha256Hex: "9b4e1a87c3f012d8a4b2c6e1f09876543210fedcba9876543210abcdef012345",
                fileSize: 1_240_000_000,
                files: [
                    DuplicateFileEntry(
                        url: url("/Users/alex/Projects/swift-studio/vendor/SwiftStudio-SDK.dmg"),
                        name: "SwiftStudio-SDK.dmg",
                        modificationDate: daysAgo(90),
                        expectedCanonicalParent: "/Users/alex/Projects/swift-studio/vendor",
                        isSelected: false,
                        relativePathFromRoot: "Projects/swift-studio/vendor/SwiftStudio-SDK.dmg"
                    ),
                    DuplicateFileEntry(
                        url: url("/Users/alex/Downloads/SwiftStudio-SDK (1).dmg"),
                        name: "SwiftStudio-SDK (1).dmg",
                        modificationDate: daysAgo(12),
                        expectedCanonicalParent: "/Users/alex/Downloads",
                        isSelected: true,
                        relativePathFromRoot: "Downloads/SwiftStudio-SDK (1).dmg"
                    ),
                ]
            ),
            DuplicateGroup(
                sha256Hex: "4c8d209a1e7b55f3012948abcdeffedcba98765432100123456789abcdef1122",
                fileSize: 485_000_000,
                files: [
                    DuplicateFileEntry(
                        url: url("/Users/alex/Documents/Architecture-RFCs/Design-System-v4.zip"),
                        name: "Design-System-v4.zip",
                        modificationDate: daysAgo(60),
                        expectedCanonicalParent: "/Users/alex/Documents/Architecture-RFCs",
                        isSelected: false,
                        relativePathFromRoot: "Documents/Architecture-RFCs/Design-System-v4.zip"
                    ),
                    DuplicateFileEntry(
                        url: url("/Users/alex/Desktop/Demo-Mockups/Design-System-v4.zip"),
                        name: "Design-System-v4.zip",
                        modificationDate: daysAgo(30),
                        expectedCanonicalParent: "/Users/alex/Desktop/Demo-Mockups",
                        isSelected: true,
                        relativePathFromRoot: "Desktop/Demo-Mockups/Design-System-v4.zip"
                    ),
                    DuplicateFileEntry(
                        url: url("/Users/alex/Downloads/Design-System-v4 copy.zip"),
                        name: "Design-System-v4 copy.zip",
                        modificationDate: daysAgo(5),
                        expectedCanonicalParent: "/Users/alex/Downloads",
                        isSelected: true,
                        relativePathFromRoot: "Downloads/Design-System-v4 copy.zip"
                    ),
                ]
            ),
            DuplicateGroup(
                sha256Hex: "7f3a91c0284e66b1d5a9023456789abcdef0123456789abcdef0987654321abc",
                fileSize: 318_000_000,
                files: [
                    DuplicateFileEntry(
                        url: url("/Users/alex/Movies/B-Roll-Studio-Intro.mp4"),
                        name: "B-Roll-Studio-Intro.mp4",
                        modificationDate: daysAgo(150),
                        expectedCanonicalParent: "/Users/alex/Movies",
                        isSelected: false,
                        relativePathFromRoot: "Movies/B-Roll-Studio-Intro.mp4"
                    ),
                    DuplicateFileEntry(
                        url: url("/Users/alex/Downloads/B-Roll-Studio-Intro.mp4"),
                        name: "B-Roll-Studio-Intro.mp4",
                        modificationDate: daysAgo(40),
                        expectedCanonicalParent: "/Users/alex/Downloads",
                        isSelected: true,
                        relativePathFromRoot: "Downloads/B-Roll-Studio-Intro.mp4"
                    ),
                ]
            ),
            DuplicateGroup(
                sha256Hex: "2a6f88d19e4c3012b7890abcdef1234567890abcdef1234567890abcdef99887",
                fileSize: 84_500_000,
                files: [
                    DuplicateFileEntry(
                        url: url("/Users/alex/Documents/Q3-Product-Deck.pdf"),
                        name: "Q3-Product-Deck.pdf",
                        modificationDate: daysAgo(75),
                        expectedCanonicalParent: "/Users/alex/Documents",
                        isSelected: false,
                        relativePathFromRoot: "Documents/Q3-Product-Deck.pdf"
                    ),
                    DuplicateFileEntry(
                        url: url("/Users/alex/Desktop/Q3-Product-Deck-Final.pdf"),
                        name: "Q3-Product-Deck-Final.pdf",
                        modificationDate: daysAgo(20),
                        expectedCanonicalParent: "/Users/alex/Desktop",
                        isSelected: true,
                        relativePathFromRoot: "Desktop/Q3-Product-Deck-Final.pdf"
                    ),
                ]
            ),
        ].map { $0.applyingPreset(.preferNonDownloads) }

        // MARK: Memory Snapshot
        let memSnap = MemorySnapshot(
            capturedAt: referenceDate,
            totalBytes: 34_359_738_368,
            activeBytes: 12_884_901_888,
            inactiveBytes: 5_368_709_120,
            wiredBytes: 4_294_967_296,
            compressedBytes: 3_435_973_836,
            cachedFilesBytes: 6_442_450_944,
            appMemoryBytes: 14_495_514_624,
            freeBytes: 2_684_354_560,
            swapUsedBytes: 1_342_177_280,
            swapTotalBytes: 2_147_483_648,
            pageSizeBytes: 16_384,
            pressureLevel: .warning
        )

        return DemoFixtureCatalog(
            defaultPreferences: prefs,
            cleanupHistory: history,
            applications: apps,
            startupItems: startup,
            extensionItems: extensions,
            extensionScanResult: extScanResult,
            leftoverGroups: leftovers,
            diskTree: rootDiskTree,
            applicationsDiskTree: appsDiskTree,
            volumeInfo: macHD,
            availableVolumes: [macHD, backupVol],
            favorites: favs,
            fileBrowserEntries: documentsEntries,
            browserDirectories: dirMap,
            junkCategories: junkCats,
            junkScanResult: junkResult,
            largeFiles: largeFileItems,
            duplicateGroups: dupGroups,
            memorySnapshot: memSnap,
            runningBundleIDs: ["com.codepulse.ide"],
            plistPreviews: plists,
            filePreviews: previews,
            defaultSelectedAppID: novaNote.id,
            defaultSelectedStartupID: startup[0].id,
            defaultSelectedExtensionID: extensions[0].id,
            defaultSelectedLeftoverGroupID: leftovers[0].id,
            defaultBrowserDirectoryURL: url("/Users/alex/Documents"),
            defaultInspectedFileURL: url("/Users/alex/Documents/Q4-Release-Notes.md")
        )
    }

    // MARK: - Query & Navigation Helpers

    public func diskTreeRoot(for rootURL: URL) -> DiskTreeNode {
        let norm = Self.normalizedKey(rootURL.path)
        if norm == "/applications" {
            return applicationsDiskTree
        }
        if let matched = findDiskNode(in: diskTree, normalizedPath: norm) {
            return matched
        }
        return diskTree
    }

    public func fileBrowserEntries(
        at directoryURL: URL,
        showHidden: Bool,
        sortBy: FileBrowserSort,
        ascending: Bool,
        searchQuery: String = ""
    ) -> [FileBrowserEntry] {
        let stdPath = directoryURL.standardizedFileURL.path
        let norm = Self.normalizedKey(stdPath)
        var entries: [FileBrowserEntry]
        if let explicit = Self.lookupNormalized(in: browserDirectories, standardizedPath: stdPath, normalizedPath: norm) {
            entries = explicit
        } else if let node = findDiskNode(in: diskTree, normalizedPath: norm) {
            entries = node.children.map { child in
                FileBrowserEntry(
                    url: child.url,
                    name: child.name,
                    kind: child.isSymlink ? .symbolicLink : (child.isPackage ? .package : (child.isDirectory ? .directory : .regularFile)),
                    sizeBytes: Int64(min(child.bytes, UInt64(Int64.max))),
                    modificationDate: child.modificationDate,
                    createdDate: child.modificationDate,
                    isDirectory: child.isDirectory,
                    isPackage: child.isPackage,
                    isSymbolicLink: child.isSymlink,
                    isSymlinkBroken: false,
                    isHidden: child.name.hasPrefix("."),
                    isDataless: false,
                    isUserImmutable: child.isUserImmutable,
                    isSIPRestricted: false,
                    isProtected: child.isProtected,
                    protectionReason: child.isProtected ? "Protected by user Skip List" : nil,
                    requiresAdmin: false,
                    utiIdentifier: child.isDirectory ? "public.folder" : "public.data",
                    kindDescription: child.isDirectory ? "Folder" : "Document",
                    expectedCanonicalParent: child.expectedCanonicalParent
                )
            }
        } else {
            entries = []
        }

        if !showHidden {
            entries = entries.filter { !$0.isHidden && !$0.name.hasPrefix(".") }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            entries = entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
        }

        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            let cmp: ComparisonResult
            switch sortBy {
            case .name:
                cmp = lhs.name.localizedStandardCompare(rhs.name)
            case .size:
                if lhs.sizeBytes != rhs.sizeBytes {
                    cmp = lhs.sizeBytes < rhs.sizeBytes ? .orderedAscending : .orderedDescending
                } else {
                    cmp = lhs.name.localizedStandardCompare(rhs.name)
                }
            case .modificationDate:
                let ld = lhs.modificationDate ?? .distantPast
                let rd = rhs.modificationDate ?? .distantPast
                if ld != rd {
                    cmp = ld < rd ? .orderedAscending : .orderedDescending
                } else {
                    cmp = lhs.name.localizedStandardCompare(rhs.name)
                }
            case .kind:
                let kindCmp = lhs.kindDescription.localizedStandardCompare(rhs.kindDescription)
                if kindCmp != .orderedSame {
                    cmp = kindCmp
                } else {
                    cmp = lhs.name.localizedStandardCompare(rhs.name)
                }
            }
            if cmp == .orderedSame {
                let pathCmp = lhs.url.path.localizedStandardCompare(rhs.url.path)
                return ascending ? pathCmp == .orderedAscending : pathCmp == .orderedDescending
            }
            return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
        }

        return entries
    }

    public func previewPayload(for targetURL: URL) -> FilePreviewPayload {
        let std = targetURL.standardizedFileURL
        let norm = Self.normalizedKey(std.path)
        if let found = Self.lookupNormalized(in: filePreviews, standardizedPath: std.path, normalizedPath: norm) {
            return found
        }
        if let node = findDiskNode(in: diskTree, normalizedPath: norm) ?? findDiskNode(in: applicationsDiskTree, normalizedPath: norm) {
            let kind: FileItemKind = node.isSymlink ? .symbolicLink : (node.isPackage ? .package : (node.isDirectory ? .directory : .regularFile))
            let meta = FileMetadataInfo(
                url: node.url,
                name: node.name,
                kind: kind,
                sizeBytes: Int64(min(node.bytes, UInt64(Int64.max))),
                allocatedSizeBytes: Int64(min(node.bytes, UInt64(Int64.max))),
                createdDate: node.modificationDate,
                modifiedDate: node.modificationDate,
                accessedDate: node.accessDate,
                posixPermissions: node.isDirectory ? 0o755 : 0o644,
                ownerUID: 501,
                groupGID: 20,
                isDirectory: node.isDirectory,
                isPackage: node.isPackage,
                isSymbolicLink: node.isSymlink,
                isSymlinkBroken: false,
                symlinkTarget: node.isSymlink ? "/Users/alex/Documents/Architecture-RFCs" : nil,
                resolvedTargetPath: nil,
                isUserImmutable: node.isUserImmutable,
                isSIPRestricted: false,
                isHidden: node.name.hasPrefix("."),
                isDataless: false,
                utiIdentifier: node.isDirectory ? "public.folder" : "public.data",
                kindDescription: node.isPackage ? "Application" : (node.isDirectory ? "Folder" : "Document"),
                expectedCanonicalParent: node.expectedCanonicalParent
            )
            let content: FilePreviewContent = node.isSymlink
                ? .unavailable(reason: .symbolicLink)
                : (node.isDirectory
                    ? .unavailable(reason: .directory)
                    : .text("Demo preview for \(node.name)\nPath: \(node.url.path)\n", encodingDescription: "UTF-8", isTruncated: false, totalBytes: Int64(min(node.bytes, UInt64(Int64.max)))))
            return FilePreviewPayload(
                metadata: meta,
                content: content,
                isProtected: node.isProtected,
                protectionReason: node.isProtected ? "Protected by user Skip List" : nil
            )
        }
        let fallbackMeta = FileMetadataInfo(
            url: std,
            name: std.lastPathComponent,
            kind: .regularFile,
            sizeBytes: 0,
            allocatedSizeBytes: 0,
            createdDate: Self.referenceDate,
            modifiedDate: Self.referenceDate,
            accessedDate: Self.referenceDate,
            posixPermissions: 0o644,
            ownerUID: 501,
            groupGID: 20,
            isDirectory: false,
            isPackage: false,
            isSymbolicLink: false,
            isSymlinkBroken: false,
            symlinkTarget: nil,
            resolvedTargetPath: nil,
            isUserImmutable: false,
            isSIPRestricted: false,
            isHidden: std.lastPathComponent.hasPrefix("."),
            isDataless: false,
            utiIdentifier: "public.data",
            kindDescription: "Document",
            expectedCanonicalParent: Self.parentPath(of: std)
        )
        return FilePreviewPayload(
            metadata: fallbackMeta,
            content: .unavailable(reason: .notFound),
            isProtected: false,
            protectionReason: nil
        )
    }

    public func plistPreview(for plistURL: URL) -> String? {
        let stdPath = plistURL.standardizedFileURL.path
        return Self.lookupNormalized(
            in: plistPreviews,
            standardizedPath: stdPath,
            normalizedPath: Self.normalizedKey(stdPath)
        )
    }

    public func directoryChildren(for dirURL: URL) -> [(url: URL, name: String, isDirectory: Bool, isSymbolicLink: Bool, size: Int64?)] {
        let stdPath = dirURL.standardizedFileURL.path
        let norm = Self.normalizedKey(stdPath)
        if let entries = Self.lookupNormalized(in: browserDirectories, standardizedPath: stdPath, normalizedPath: norm) {
            return entries.map { entry in
                (url: entry.url, name: entry.name, isDirectory: entry.isDirectory, isSymbolicLink: entry.isSymbolicLink, size: entry.sizeBytes)
            }
        }
        if let node = findDiskNode(in: diskTree, normalizedPath: norm) {
            return node.children.map { child in
                (url: child.url, name: child.name, isDirectory: child.isDirectory, isSymbolicLink: child.isSymlink, size: Int64(min(child.bytes, UInt64(Int64.max))))
            }
        }
        return []
    }

    public func memoryReleaseResult(from before: MemorySnapshot, elevated: Bool) -> MemoryReleaseResult {
        if elevated {
            let reclaimedCache: UInt64 = min(before.cachedFilesBytes, 2_415_919_104)
            let newCached = before.cachedFilesBytes &- reclaimedCache
            let newFree = before.freeBytes &+ reclaimedCache
            let after = MemorySnapshot(
                capturedAt: Self.referenceDate.addingTimeInterval(2),
                totalBytes: before.totalBytes,
                activeBytes: before.activeBytes,
                inactiveBytes: before.inactiveBytes > reclaimedCache ? before.inactiveBytes &- reclaimedCache : 0,
                wiredBytes: before.wiredBytes,
                compressedBytes: before.compressedBytes,
                cachedFilesBytes: newCached,
                appMemoryBytes: before.appMemoryBytes,
                freeBytes: newFree,
                swapUsedBytes: before.swapUsedBytes,
                swapTotalBytes: before.swapTotalBytes,
                pageSizeBytes: before.pageSizeBytes,
                pressureLevel: .normal
            )
            return MemoryReleaseResult(
                before: before,
                after: after,
                reclaimedEstimateBytes: reclaimedCache,
                methodUsed: "purge",
                usedElevation: true,
                note: "Demo simulation: flushed inactive file cache pages via /usr/sbin/purge without modifying host memory."
            )
        } else {
            let delta: UInt64 = min(before.cachedFilesBytes, 402_653_184)
            let newCached = before.cachedFilesBytes &- delta
            let newFree = before.freeBytes &+ delta
            let after = MemorySnapshot(
                capturedAt: Self.referenceDate.addingTimeInterval(2),
                totalBytes: before.totalBytes,
                activeBytes: before.activeBytes,
                inactiveBytes: before.inactiveBytes > delta ? before.inactiveBytes &- delta : 0,
                wiredBytes: before.wiredBytes,
                compressedBytes: before.compressedBytes,
                cachedFilesBytes: newCached,
                appMemoryBytes: before.appMemoryBytes,
                freeBytes: newFree,
                swapUsedBytes: before.swapUsedBytes,
                swapTotalBytes: before.swapTotalBytes,
                pageSizeBytes: before.pageSizeBytes,
                pressureLevel: before.pressureLevel
            )
            return MemoryReleaseResult(
                before: before,
                after: after,
                reclaimedEstimateBytes: delta,
                methodUsed: "standard_pressure_relief",
                usedElevation: false,
                note: "Demo simulation: non-privileged pressure relief advisory completed with transparent delta."
            )
        }
    }

    public func pathExists(_ path: String) -> Bool {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        let norm = Self.normalizedKey(std)
        if Self.lookupNormalized(in: browserDirectories, standardizedPath: std, normalizedPath: norm) != nil
            || Self.lookupNormalized(in: filePreviews, standardizedPath: std, normalizedPath: norm) != nil
            || Self.lookupNormalized(in: plistPreviews, standardizedPath: std, normalizedPath: norm) != nil {
            return true
        }
        if defaultPreferences.protectedPaths.contains(where: { Self.normalizedKey($0) == norm }) {
            return true
        }
        if applications.contains(where: { Self.normalizedKey($0.url.path) == norm }) {
            return true
        }
        if findDiskNode(in: diskTree, normalizedPath: norm) != nil
            || findDiskNode(in: applicationsDiskTree, normalizedPath: norm) != nil {
            return true
        }
        return false
    }

    public func isDirectory(at targetURL: URL) -> Bool {
        let stdPath = targetURL.standardizedFileURL.path
        let norm = Self.normalizedKey(stdPath)
        if Self.lookupNormalized(in: browserDirectories, standardizedPath: stdPath, normalizedPath: norm) != nil {
            return true
        }
        if let found = Self.lookupNormalized(in: filePreviews, standardizedPath: stdPath, normalizedPath: norm) {
            return found.metadata.isDirectory && !found.metadata.isSymbolicLink
        }
        if let node = findDiskNode(in: diskTree, normalizedPath: norm)
            ?? findDiskNode(in: applicationsDiskTree, normalizedPath: norm) {
            return node.isDirectory && !node.isSymlink
        }
        return false
    }

    // MARK: - Private Builders

    private static func normalizedKey(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func lookupNormalized<Value>(
        in dictionary: [String: Value],
        standardizedPath: String,
        normalizedPath: String
    ) -> Value? {
        if let exact = dictionary[standardizedPath] {
            return exact
        }
        return dictionary.first(where: { normalizedKey($0.key) == normalizedPath })?.value
    }

    private func findDiskNode(in node: DiskTreeNode, normalizedPath: String) -> DiskTreeNode? {
        if Self.normalizedKey(node.url.path) == normalizedPath {
            return node
        }
        for child in node.children {
            if let hit = findDiskNode(in: child, normalizedPath: normalizedPath) {
                return hit
            }
        }
        return nil
    }

    private static func daysAgo(_ days: Int) -> Date {
        referenceDate.addingTimeInterval(-TimeInterval(days) * 86_400)
    }

    private static func url(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func parentPath(of targetURL: URL) -> String {
        let parent = targetURL.standardizedFileURL.deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private static func sf(
        _ path: String,
        _ category: ServiceFileCategory,
        _ size: Int64,
        files: Int,
        folders: Int,
        isDir: Bool,
        selected: Bool = true,
        requiresAdmin: Bool = false,
        requiresReboot: Bool = false,
        systemScope: Bool = false,
        confidence: LeftoverConfidence? = nil,
        reason: String
    ) -> ServiceFile {
        let target = url(path)
        return ServiceFile(
            url: target,
            category: category,
            size: size,
            fileCount: files,
            folderCount: folders,
            isDirectory: isDir,
            isSymbolicLink: false,
            isSelected: selected,
            requiresAdmin: requiresAdmin,
            requiresReboot: requiresReboot,
            isSystemScope: systemScope,
            confidence: confidence,
            matchReason: reason,
            expectedCanonicalParent: parentPath(of: target)
        )
    }

    private static func fbDir(
        _ path: String,
        size: Int64,
        modDays: Int,
        hidden: Bool = false,
        isProtected: Bool = false,
        protectionReason: String? = nil,
        parent: String
    ) -> FileBrowserEntry {
        let target = url(path)
        return FileBrowserEntry(
            url: target,
            name: target.lastPathComponent,
            kind: .directory,
            sizeBytes: size,
            modificationDate: daysAgo(modDays),
            createdDate: daysAgo(modDays + 15),
            isDirectory: true,
            isPackage: false,
            isSymbolicLink: false,
            isSymlinkBroken: false,
            isHidden: hidden,
            isDataless: false,
            isUserImmutable: false,
            isSIPRestricted: false,
            isProtected: isProtected,
            protectionReason: protectionReason,
            requiresAdmin: false,
            utiIdentifier: "public.folder",
            kindDescription: "Folder",
            expectedCanonicalParent: parent
        )
    }

    private static func fbFile(
        _ path: String,
        size: Int64,
        modDays: Int,
        hidden: Bool = false,
        isProtected: Bool = false,
        protectionReason: String? = nil,
        isImmutable: Bool = false,
        uti: String,
        kindDesc: String,
        parent: String
    ) -> FileBrowserEntry {
        let target = url(path)
        return FileBrowserEntry(
            url: target,
            name: target.lastPathComponent,
            kind: .regularFile,
            sizeBytes: size,
            modificationDate: daysAgo(modDays),
            createdDate: daysAgo(modDays + 10),
            isDirectory: false,
            isPackage: false,
            isSymbolicLink: false,
            isSymlinkBroken: false,
            isHidden: hidden,
            isDataless: false,
            isUserImmutable: isImmutable,
            isSIPRestricted: false,
            isProtected: isProtected,
            protectionReason: protectionReason,
            requiresAdmin: false,
            utiIdentifier: uti,
            kindDescription: kindDesc,
            expectedCanonicalParent: parent
        )
    }

    private static func fbSymlink(
        _ path: String,
        modDays: Int,
        parent: String
    ) -> FileBrowserEntry {
        let target = url(path)
        return FileBrowserEntry(
            url: target,
            name: target.lastPathComponent,
            kind: .symbolicLink,
            sizeBytes: 38,
            modificationDate: daysAgo(modDays),
            createdDate: daysAgo(modDays),
            isDirectory: false,
            isPackage: false,
            isSymbolicLink: true,
            isSymlinkBroken: false,
            isHidden: false,
            isDataless: false,
            isUserImmutable: false,
            isSIPRestricted: false,
            isProtected: false,
            protectionReason: nil,
            requiresAdmin: false,
            utiIdentifier: "public.symlink",
            kindDescription: "Symbolic Link",
            expectedCanonicalParent: parent
        )
    }

    private static func makeMetadata(from entry: FileBrowserEntry) -> FileMetadataInfo {
        FileMetadataInfo(
            url: entry.url,
            name: entry.name,
            kind: entry.kind,
            sizeBytes: entry.sizeBytes,
            allocatedSizeBytes: entry.sizeBytes,
            createdDate: entry.createdDate,
            modifiedDate: entry.modificationDate,
            accessedDate: entry.modificationDate,
            posixPermissions: entry.isDirectory ? 0o755 : (entry.isUserImmutable ? 0o444 : 0o644),
            ownerUID: 501,
            groupGID: 20,
            isDirectory: entry.isDirectory,
            isPackage: entry.isPackage,
            isSymbolicLink: entry.isSymbolicLink,
            isSymlinkBroken: entry.isSymlinkBroken,
            symlinkTarget: entry.isSymbolicLink ? "/Users/alex/Documents/Architecture-RFCs" : nil,
            resolvedTargetPath: entry.isSymbolicLink ? "/Users/alex/Documents/Architecture-RFCs" : nil,
            isUserImmutable: entry.isUserImmutable,
            isSIPRestricted: entry.isSIPRestricted,
            isHidden: entry.isHidden,
            isDataless: entry.isDataless,
            utiIdentifier: entry.utiIdentifier,
            kindDescription: entry.kindDescription,
            expectedCanonicalParent: entry.expectedCanonicalParent
        )
    }

    private static func makeLaunchPlistXML(
        label: String,
        programArguments: [String],
        runAtLoad: Bool,
        keepAlive: Bool
    ) -> String {
        let argsXML = programArguments
            .map { "        <string>\($0)</string>" }
            .joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
        \(argsXML)
            </array>
            <key>RunAtLoad</key>
            <\(runAtLoad ? "true" : "false")/>
            <key>KeepAlive</key>
            <\(keepAlive ? "true" : "false")/>
        </dict>
        </plist>
        """
    }
}

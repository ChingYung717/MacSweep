import Darwin
import Foundation
import Security

public enum RemovalValidationResult: Sendable, Equatable {
    case allowed
    case blocked(reason: String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

public struct SafetyGuard: Sendable {
    public let homeDirectoryPath: String
    public let selfBundlePath: String?
    public let selfResolvedBundlePath: String?
    public let selfDataPaths: [String]
    public let protectedPaths: Set<String>
    public let protectedBundleIDs: Set<String>
    /// Precomputed once (avoid rebuilding on every `validateForRemoval` call).
    private let selfBundlePathsLower: [String]
    private let selfDataPathsLower: [String]
    private let criticalExactPaths: Set<String>
    private let criticalExactPathsLower: Set<String>
    /// Trailing-slash-stripped immutable prefixes checked via bidirectional `pathsOverlap`.
    private let immutableBarePrefixesLower: [String]
    private let protectedPathsLower: Set<String>
    private let homePrefixesLower: [String]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        selfBundlePath: String? = Bundle.main.bundlePath,
        protectedPaths: [String] = [],
        protectedBundleIDs: [String] = []
    ) {
        let stdHome = homeDirectory.standardizedFileURL.path
        let resHome = homeDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let realHome = Self.posixRealpath(stdHome)
        let homeVariants = Array(Set([stdHome, resHome, realHome].compactMap { $0 }))

        func makeSelfDataPaths(for homePath: String) -> [String] {
            let homeURL = URL(fileURLWithPath: homePath)
            return [
                homeURL.appendingPathComponent("Library/Application Support/MacSweep").standardizedFileURL.path,
                homeURL.appendingPathComponent("Library/Preferences/local.macsweep.plist").standardizedFileURL.path,
                homeURL.appendingPathComponent("Library/Caches/local.macsweep").standardizedFileURL.path,
                homeURL.appendingPathComponent("Library/Saved Application State/local.macsweep.savedState").standardizedFileURL.path,
                homeURL.appendingPathComponent("Library/HTTPStorages/local.macsweep").standardizedFileURL.path,
                homeURL.appendingPathComponent("Library/WebKit/local.macsweep").standardizedFileURL.path,
            ]
        }

        let primaryDataPaths = makeSelfDataPaths(for: stdHome)
        let allDataPaths = Array(Set(homeVariants.flatMap(makeSelfDataPaths(for:))))

        self.homeDirectoryPath = stdHome
        if let rawSelf = selfBundlePath {
            let url = URL(fileURLWithPath: rawSelf)
            let stdSelf = url.standardizedFileURL.path
            let resSelf = url.resolvingSymlinksInPath().standardizedFileURL.path
            let realSelf = Self.posixRealpath(stdSelf)
            self.selfBundlePath = stdSelf
            self.selfResolvedBundlePath = resSelf
            self.selfBundlePathsLower = Array(Set([stdSelf, resSelf, realSelf].compactMap { $0 }.map(Self.normalizedForCompare)))
        } else {
            self.selfBundlePath = nil
            self.selfResolvedBundlePath = nil
            self.selfBundlePathsLower = []
        }
        self.selfDataPaths = primaryDataPaths
        self.selfDataPathsLower = allDataPaths.map(Self.normalizedForCompare)

        var allProtectedStd = Set<String>()
        var allProtectedLower = Set<String>()
        for rawProtected in protectedPaths {
            let url = URL(fileURLWithPath: rawProtected)
            let std = url.standardizedFileURL.path
            let res = url.resolvingSymlinksInPath().standardizedFileURL.path
            allProtectedStd.insert(std)
            allProtectedLower.insert(Self.normalizedForCompare(std))
            allProtectedLower.insert(Self.normalizedForCompare(res))
            if let real = Self.posixRealpath(std) {
                allProtectedLower.insert(Self.normalizedForCompare(real))
            }
        }
        self.protectedPaths = allProtectedStd
        self.protectedPathsLower = allProtectedLower
        self.protectedBundleIDs = Set(
            protectedBundleIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )

        var exact = Set<String>()
        for h in homeVariants {
            exact.formUnion(Self.makeCriticalExactPaths(home: h, selfDataPaths: allDataPaths))
        }
        self.criticalExactPaths = exact
        self.criticalExactPathsLower = Set(exact.map(Self.normalizedForCompare))

        var userPrefixes: [String] = []
        for h in homeVariants {
            userPrefixes.append(contentsOf: [
                "\(h)/Library/Keychains/",
                "\(h)/Library/Safari/",
                "\(h)/Library/Mail/",
                "\(h)/Library/Messages/",
                "\(h)/Library/Mobile Documents/",
                "\(h)/Library/Application Support/com.apple.TCC/",
                "\(h)/Library/Application Support/AddressBook/",
                "\(h)/Library/Application Support/CallHistoryDB/",
                "\(h)/Library/Application Support/CallHistoryTransactions/",
                "\(h)/Library/Application Support/MobileSync/",
                "\(h)/Library/Application Support/CloudDocs/",
                "\(h)/Library/Application Support/FileProvider/",
                "\(h)/Library/Application Support/iCloud/",
                "\(h)/Library/Application Support/FaceTime/",
                "\(h)/Library/Application Support/Knowledge/",
                "\(h)/Library/Application Support/Apple/",
                "\(h)/Library/Calendars/",
                "\(h)/Library/Reminders/",
                "\(h)/Library/Contacts/",
                "\(h)/Library/Accounts/",
                "\(h)/Library/Biome/",
                "\(h)/Library/Photos/",
                "\(h)/Library/HomeKit/",
                "\(h)/Library/IdentityServices/",
                "\(h)/Library/Passes/",
                "\(h)/Library/Finance/",
                "\(h)/Library/Shortcuts/",
                "\(h)/Library/Suggestions/",
                "\(h)/Library/CloudStorage/",
                "\(h)/Library/Daemon Containers/",
                "\(h)/Pictures/Photos Library.photoslibrary/",
                "\(h)/.ssh/",
                "\(h)/.gnupg/",
            ])
        }
        self.homePrefixesLower = Array(Set(homeVariants.map { raw -> String in
            var p = Self.normalizedForCompare(raw)
            while p.count > 1 && p.hasSuffix("/") {
                p.removeLast()
            }
            return p
        }))
        self.immutableBarePrefixesLower = Array(Set(
            (Self.immutableSystemPrefixes + userPrefixes).map { raw -> String in
                var p = Self.normalizedForCompare(raw)
                while p.count > 1 && p.hasSuffix("/") {
                    p.removeLast()
                }
                return p
            }
        ))
    }

    private static func normalizedForCompare(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func pathsOverlap(_ candidate: String, with target: String) -> Bool {
        candidate == target || candidate.hasPrefix(target + "/") || target.hasPrefix(candidate + "/")
    }

    /// Resolves `path` via POSIX `realpath(3)` (preserves `/private` on macOS, unlike Foundation's
    /// `resolvingSymlinksInPath`). Returns `nil` if the path or an ancestor cannot be resolved.
    internal static func posixRealpath(_ path: String) -> String? {
        guard !path.isEmpty, !path.contains("\0") else { return nil }
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return nil
    }

    private static func candidatePaths(for url: URL) -> [(raw: String, normalized: String)] {
        let rawPath = url.standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        var results: [(String, String)] = [(rawPath, normalizedForCompare(rawPath))]
        var seen = Set([results[0].1])

        let normResolved = normalizedForCompare(resolvedPath)
        if seen.insert(normResolved).inserted {
            results.append((resolvedPath, normResolved))
        }
        if let realPath = posixRealpath(rawPath) {
            let normReal = normalizedForCompare(realPath)
            if seen.insert(normReal).inserted {
                results.append((realPath, normReal))
            }
        } else {
            // Also resolve existing parent via realpath(3) so non-existent leaves under `/var/db/...`
            // still see their `/private/var/db/...` canonical path.
            let stdURL = url.standardizedFileURL
            let parentPath = stdURL.deletingLastPathComponent().path
            if let realParent = posixRealpath(parentPath) {
                let combined = URL(fileURLWithPath: realParent)
                    .appendingPathComponent(stdURL.lastPathComponent)
                    .standardizedFileURL.path
                let normCombined = normalizedForCompare(combined)
                if seen.insert(normCombined).inserted {
                    results.append((combined, normCombined))
                }
            }
        }
        return results
    }

    /// Library / Launch directory names under which `protectedBundleIDs` are enforced by `validateForRemoval`.
    private static let protectedBundleEnforcedParents: Set<String> = [
        "launchagents",
        "launchdaemons",
        "privilegedhelpertools",
        "preferences",
        "byhost",
        "caches",
        "containers",
        "group containers",
        "application support",
        "application scripts",
        "saved application state",
        "httpstorages",
        "webkit",
        "cookies",
        "logs",
        "diagnosticreports",
        "preferencepanes",
        "quicklook",
        "spotlight",
        "screen savers",
        "internet plug-ins",
        "components",
        "vst",
        "vst3",
        "hal",
    ]

    // Directories that must NEVER be deleted themselves (neither directly nor via pkgutil/leftovers).
    private static func makeCriticalExactPaths(home h: String, selfDataPaths: [String]) -> Set<String> {
        var set: Set<String> = [
            "/",
            "/System",
            "/Volumes",
            "/dev",
            "/usr",
            "/usr/bin",
            "/usr/sbin",
            "/usr/lib",
            "/usr/share",
            "/usr/libexec",
            "/usr/local",
            "/usr/local/bin",
            "/usr/local/lib",
            "/usr/local/share",
            "/usr/local/share/man",
            "/bin",
            "/sbin",
            "/etc",
            "/etc/paths.d",
            "/var",
            "/var/db",
            "/var/db/receipts",
            "/var/root",
            "/var/folders",
            "/var/tmp",
            "/tmp",
            "/private",
            "/private/etc",
            "/private/etc/paths.d",
            "/private/tmp",
            "/private/var",
            "/private/var/db",
            "/private/var/db/receipts",
            "/private/var/root",
            "/private/var/folders",
            "/private/var/tmp",
            "/opt",
            "/opt/homebrew",
            "/Applications",
            "/Applications/Utilities",
            "/Users",
            "/Library",
            "/Library/Apple",
            "/Library/Application Support",
            "/Library/Application Support/Apple",
            "/Library/Caches",
            "/Library/ColorSync",
            "/Library/Desktop Pictures",
            "/Library/Preferences",
            "/Library/Preferences/org.cups.printers.plist",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            "/Library/PrivilegedHelperTools",
            "/Library/PreferencePanes",
            "/Library/Printers",
            "/Library/StartupItems",
            "/Library/Logs",
            "/Library/Logs/DiagnosticReports",
            "/Library/Java",
            "/Library/Java/JavaVirtualMachines",
            "/Library/Keychains",
            "/Library/Application Support/com.apple.TCC",
            "/Library/Preferences/SystemConfiguration",
            "/var/db/dslocal",
            "/private/var/db/dslocal",
            "/Library/Security",
            "/Library/SystemExtensions",
            "/Library/QuickLook",
            "/Library/Screen Savers",
            "/Library/Spotlight",
            "/Library/Internet Plug-Ins",
            "/Library/Audio",
            "/Library/Audio/Plug-Ins",
            "/Library/Audio/Plug-Ins/Components",
            "/Library/Audio/Plug-Ins/VST",
            "/Library/Audio/Plug-Ins/VST3",
            "/Library/Audio/Plug-Ins/HAL",
            "/Library/Frameworks",
            "/Library/Extensions",
            h,
            "\(h)/Applications",
            "\(h)/Desktop",
            "\(h)/Documents",
            "\(h)/Downloads",
            "\(h)/Pictures",
            "\(h)/Movies",
            "\(h)/Music",
            "\(h)/Library",
            "\(h)/Library/Application Support",
            "\(h)/Library/Application Support/Apple",
            "\(h)/Library/Application Support/com.apple.TCC",
            "\(h)/Library/Application Scripts",
            "\(h)/Library/Caches",
            "\(h)/Library/Preferences",
            "\(h)/Library/Preferences/org.cups.PrintingPrefs.plist",
            "\(h)/Library/Containers",
            "\(h)/Library/Group Containers",
            "\(h)/Library/Saved Application State",
            "\(h)/Library/HTTPStorages",
            "\(h)/Library/WebKit",
            "\(h)/Library/Cookies",
            "\(h)/Library/Logs",
            "\(h)/Library/Logs/DiagnosticReports",
            "\(h)/Library/LaunchAgents",
            "\(h)/Library/PreferencePanes",
            "\(h)/Library/QuickLook",
            "\(h)/Library/Screen Savers",
            "\(h)/Library/Spotlight",
            "\(h)/Library/Internet Plug-Ins",
            "\(h)/Library/Audio",
            "\(h)/Library/Audio/Plug-Ins",
            "\(h)/Library/Audio/Plug-Ins/Components",
            "\(h)/Library/Audio/Plug-Ins/VST",
            "\(h)/Library/Audio/Plug-Ins/VST3",
            "\(h)/Library/Audio/Plug-Ins/HAL",
            "\(h)/Library/Safari",
            "\(h)/Library/Mail",
            "\(h)/Library/Messages",
            "\(h)/Library/Keychains",
            "\(h)/.ssh",
            "\(h)/.gnupg",
            "\(h)/.Trash",
        ]
        for p in selfDataPaths {
            set.insert(p)
        }
        return set
    }

    private static let immutableSystemPrefixes: [String] = [
        "/System/",
        "/Library/Apple/",
        "/Library/Application Support/Apple/",
        "/Library/Application Support/com.apple.TCC/",
        "/Library/Preferences/SystemConfiguration/",
        "/Library/Keychains/",
        "/Library/Security/",
        "/Library/SystemExtensions/",
        "/etc/",
        "/private/etc/",
        "/var/db/",
        "/private/var/db/",
        "/var/root/",
        "/private/var/root/",
        "/usr/bin/",
        "/usr/sbin/",
        "/usr/lib/",
        "/usr/libexec/",
        "/usr/share/",
        "/bin/",
        "/sbin/",
    ]

    /// Lowercased directory/file names never flagged as leftovers or blindly removed.
    public static let leftoverSafeIgnoreNames: Set<String> = [
        // macOS / Apple system data & framework support dirs
        "apple", "applepushservice", "addressbook", "assistant", "bezelservices", "biome", "bird",
        "btserver", "caches", "calendars", "callhistorydb", "callhistorytransactions", "clouddocs",
        "cloudkit", "colorsync", "contacts", "coredata", "coreduet", "coremediaio", "crashreporter",
        "cups", "desktop pictures", "diagnosticreports", "differentialprivacy", "dock", "dprivacyd",
        "embeddedosinstall", "facetime", "familycircle", "familysettings", "fileprovider", "findmy",
        "fontcollections", "geo", "group containers", "homekit", "icloud", "icdd",
        "identityservices", "ilifemediabrowser", "imessage", "intelligenceplatform", "iodbc",
        "keychains", "knowledge", "livefsd", "mail", "mediaanalysis", "messages", "metadata",
        "mobilebackup", "mobilesync", "passkit", "personalizationportrait", "photos", "photossearch",
        "preferences", "printers", "proapps", "proactiveeventtracker", "quicklook", "reminders",
        "remote desktop", "safari", "screentime", "searchparty", "security", "sharing", "siri",
        "siritts", "spotlight", "stagedframeworks", "startupitems", "suggestions", "syncservices",
        "tcc", "tips", "trial", "ubiquity", "voicecontrol", "voicememos", "weather", "webkit",
        "widgets", "workflow",
        // Shared runtimes, system SDKs, active vendor infrastructure & developer tools
        "homebrew", "brew", "npm", "npx", "pnpm", "yarn", "bun", "deno", "node", "nvm",
        "fnm", "volta", "cargo", "rustup", "pip", "pipx", "poetry", "uv", "pyenv",
        "conda", "miniconda", "anaconda", "venv", "virtualenv", "go", "gopath", "gradle",
        "maven", "m2", "sbt", "ivy2", "cocoapods", "carthage", "swiftpm", "org.swift.swiftpm",
        "java", "openjdk", "jdk", "jre",
        "xcode", "developer", "coresimulator", "instruments", "docker", "colima", "orbstack",
        "lima", "podman", "kubectl", "kube", "helm", "terraform", "gcloud", "google-cloud-sdk",
        "aws", "azure", "gh", "git", "ssh", "gnupg", "gpg", "1password", "bitwarden",
        "antigravity", "gemini", "claude", "codex", "cursor", "windsurf", "vscode", "code",
        "jetbrains", "sublime text", "neovim", "nvim", "vim", "tmux", "zsh", "oh-my-zsh",
        "fish", "starship", "iterm2", "warp", "ghostty", "alacritty", "kitty",
        // Active shared vendor infra subfolders
        "mau2.0", "microsoft autoupdate", "drivefs",
        // MacSweep itself
        "macsweep", "local.macsweep",
    ]

    /// Reverse-DNS prefixes that belong to macOS core infrastructure, shared SDKs, or installed runtimes.
    private static let leftoverProtectedBundlePrefixes: [String] = [
        "com.apple.",
        "group.com.apple.",
        "apple.",
        "org.cups.",
        "net.java.openjdk",
        "com.plausiblelabs.crashreporter",
        "local.macsweep",
    ]

    /// Shared vendor parent folders whose contents belong to multiple independent apps.
    /// Note: `"apple"` is intentionally excluded from vendor expansion (see `LibraryIndex`) so Apple
    /// system support subdirectories are never exposed as third-party app data.
    public static let sharedVendorFolderNames: Set<String> = [
        "microsoft", "google", "adobe", "jetbrains", "tencent", "bytedance",
        "mozilla", "bravesoftware", "oracle", "logitech", "logi", "brother", "oray",
        "nektony", "setapp", "paragon", "parallels", "vmware", "autodesk", "wacom",
        "razer", "corsair", "steelseries", "elgato", "dropbox", "atlassian", "meta",
        "alibaba", "dingtalk", "feishu", "lark", "wps", "kingsoft", "baidu", "netease",
        "sogou", "youdao", "xiaomi", "huawei", "oppo", "vivo", "canon", "epson", "hp",
    ]

    /// Explicit lowercased Apple Group Container names that do not carry a `com.apple.` prefix
    /// (plus legacy/shared Apple containers present on macOS).
    public static let appleGroupContainerExactDenylist: Set<String> = [
        "74j34u3r6x.com.apple.iwork",
        "k36bkf7t3d.group.com.apple.configurator",
        ".siritodayviewextension",
        "airport",
        "cookies",
        "com.apple",
        "group.is.workflow",
        "is.workflow",
        "group.tvappservices",
        "tvappservices",
    ]

    /// Best-effort cached set of `com.apple.security.application-groups` /
    /// `com.apple.security.restricted-application-groups` declared by Apple-signed apps in
    /// `/System/Applications` and `/System/Library/CoreServices` (never touches `containermanagerd`
    /// metadata plists which return `EPERM` without Full Disk Access).
    public static let systemAppleApplicationGroups: Set<String> = harvestSystemAppleApplicationGroups()

    private static func harvestSystemAppleApplicationGroups() -> Set<String> {
        let roots = [
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices"),
        ]
        var appleReq: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, SecCSFlags(), &appleReq) == errSecSuccess,
              let req = appleReq else {
            return []
        }

        let fm = FileManager.default
        let checkFlags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        var groups = Set<String>()

        func inspectBundle(_ appURL: URL) {
            var st = stat()
            guard lstat(appURL.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFLNK else { return }
            var staticCode: SecStaticCode?
            guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
                  let code = staticCode,
                  SecStaticCodeCheckValidity(code, checkFlags, req) == errSecSuccess else {
                return
            }
            var infoRef: CFDictionary?
            guard SecCodeCopySigningInformation(code, infoFlags, &infoRef) == errSecSuccess,
                  let dict = infoRef as? [String: Any],
                  let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
                return
            }
            for key in ["com.apple.security.application-groups", "com.apple.security.restricted-application-groups"] {
                if let entries = entitlements[key] as? [String] {
                    for raw in entries {
                        let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if !norm.isEmpty {
                            groups.insert(norm)
                        }
                    }
                }
            }
        }

        func scan(_ dir: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                return
            }
            for item in items {
                if item.pathExtension.lowercased() == "app" {
                    inspectBundle(item)
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

        for root in roots {
            scan(root, depth: 0)
        }
        return groups
    }

    /// True if `name` identifies an Apple-owned Group Container (including `com.apple.*`,
    /// `group.com.apple.*`, `*.groups.com.apple.*`, `group.is.workflow.*`, `group.tvappservices.*`,
    /// legacy non-`com.apple` Apple containers, and dynamically harvested system app groups).
    public static func isAppleGroupContainerName(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return false }

        if appleGroupContainerExactDenylist.contains(lower) {
            return true
        }
        if systemAppleApplicationGroups.contains(lower) {
            return true
        }
        if lower.hasPrefix("com.apple.")
            || lower.hasPrefix("group.com.apple.")
            || lower.hasPrefix("groups.com.apple.")
            || lower.contains(".groups.com.apple.")
            || lower.contains(".group.com.apple.")
            || lower.hasPrefix("group.is.workflow.")
            || lower.hasPrefix("is.workflow.")
            || lower.hasPrefix("group.tvappservices.")
            || lower.hasPrefix("tvappservices.") {
            return true
        }
        let stripped = InstalledAppInventory.stripContainerPrefixes(lower)
        if stripped == "com.apple"
            || stripped.hasPrefix("com.apple.")
            || stripped == "is.workflow"
            || stripped.hasPrefix("is.workflow.")
            || stripped == "tvappservices"
            || stripped.hasPrefix("tvappservices.") {
            return true
        }
        return false
    }

    /// Checks POSIX `lstat` flags for kernel/SIP immutability flags (`SF_RESTRICTED`, `SF_IMMUTABLE`,
    /// `SF_NOUNLINK`) without following symlinks. User-set `UF_IMMUTABLE` (`uchg`) is intentionally
    /// excluded so user-locked non-system apps/LaunchAgents are not misclassified as SIP-protected.
    public func isSIPRestricted(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        let mask = UInt32(SF_RESTRICTED) | UInt32(SF_IMMUTABLE) | UInt32(SF_NOUNLINK)
        return (st.st_flags & mask) != 0
    }

    /// Checks POSIX `lstat` flags for user-set immutability (`UF_IMMUTABLE` / `chflags uchg`)
    /// without following symlinks.
    public func isUserImmutable(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_flags & UInt32(UF_IMMUTABLE)) != 0
    }

    /// Returns true if `url` is a symbolic link without following it.
    public func isSymbolicLink(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Returns true if `url` is a symlink whose target resolves inside `/System/` or `/Library/Apple/`
    /// (case- and Unicode-normalization-safe).
    public func pointsToSystemVolume(_ url: URL) -> Bool {
        guard isSymbolicLink(url) else { return false }
        let resolved = Self.normalizedForCompare(url.resolvingSymlinksInPath().standardizedFileURL.path)
        let real = Self.posixRealpath(url.standardizedFileURL.path).map(Self.normalizedForCompare)
        for candidate in [resolved, real].compactMap({ $0 }) {
            if candidate == "/system" || candidate.hasPrefix("/system/")
                || candidate == "/library/apple" || candidate.hasPrefix("/library/apple/") {
                return true
            }
        }
        return false
    }

    /// True for macOS built-in system apps (under `/System`, `/Library/Apple`, SIP-restricted, or symlink to system volume).
    /// Returns false for App Store Apple apps in `/Applications` such as Pages/Numbers/Keynote/TestFlight.
    public func isSystemProtectedApp(at url: URL) -> Bool {
        for entry in Self.candidatePaths(for: url) {
            let norm = entry.normalized
            if norm == "/system" || norm.hasPrefix("/system/")
                || norm == "/library/apple" || norm.hasPrefix("/library/apple/") {
                return true
            }
        }
        if isSIPRestricted(url) || pointsToSystemVolume(url) {
            return true
        }
        return false
    }

    /// True if `url` or `bundleID` refers to MacSweep itself (case- and Unicode-normalization-safe).
    public func isSelfApp(bundleID: String?, url: URL) -> Bool {
        if let bundleID, bundleID.lowercased() == "local.macsweep" {
            return true
        }
        let candidates = Self.candidatePaths(for: url).map(\.normalized)
        for selfPath in selfBundlePathsLower where selfPath.hasSuffix(".app") {
            for candidate in candidates {
                if candidate == selfPath || candidate.hasPrefix(selfPath + "/") {
                    return true
                }
            }
        }
        return false
    }

    /// True if the bundle ID belongs to an Apple app (e.g. `com.apple.iWork.Pages`).
    /// Rejects bare `"com.apple"` without a product segment.
    public func isAppleBundleID(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        guard lower.hasPrefix("com.apple.") else { return false }
        let suffix = lower.dropFirst("com.apple.".count)
        return !suffix.isEmpty && !suffix.hasPrefix(".")
    }

    /// True if `bundleID` matches any user-protected bundle ID (exact or boundary sub-identifier,
    /// including after stripping `group.` / `<10-char TeamID>.` container prefixes).
    public func matchesProtectedBundleID(_ bundleID: String) -> Bool {
        guard !protectedBundleIDs.isEmpty else { return false }
        let lower = bundleID.lowercased()
        let stripped = InstalledAppInventory.stripContainerPrefixes(lower)
        for protectedID in protectedBundleIDs where !protectedID.isEmpty {
            if ServiceFileMatcher.isBoundaryPrefixMatch(candidate: lower, prefix: protectedID)
                || ServiceFileMatcher.isBoundaryPrefixMatch(candidate: stripped, prefix: protectedID) {
                return true
            }
        }
        return false
    }

    /// True if a bundle ID or path is explicitly marked protected by the user
    /// (case-, Unicode-normalization-, and symlink-safe, including descendants/ancestors).
    public func isUserProtected(bundleID: String?, url: URL) -> Bool {
        if let bundleID, matchesProtectedBundleID(bundleID) {
            return true
        }
        guard !protectedPathsLower.isEmpty else { return false }
        let candidates = Self.candidatePaths(for: url).map(\.normalized)
        for candidate in candidates {
            for protected in protectedPathsLower {
                if Self.pathsOverlap(candidate, with: protected) {
                    return true
                }
            }
        }
        return false
    }

    /// True if removing/modifying `url` requires elevated privileges (or Finder admin prompt).
    public func requiresAdmin(for url: URL) -> Bool {
        let stdURL = url.standardizedFileURL
        let parentPath = stdURL.deletingLastPathComponent().path

        // Deleting an entry requires write permission on its parent directory.
        if access(parentPath, W_OK) != 0 {
            return true
        }

        let currentUID = geteuid()
        var parentStat = stat()
        var itemStat = stat()
        let hasParentStat = lstat(parentPath, &parentStat) == 0
        let hasItemStat = lstat(stdURL.path, &itemStat) == 0

        if hasParentStat && hasItemStat {
            let sticky = (parentStat.st_mode & S_ISVTX) != 0
            if sticky && itemStat.st_uid != currentUID && parentStat.st_uid != currentUID {
                return true
            }
        }

        // Root-owned bundles/directories aren't directly writable by non-root.
        if hasItemStat && itemStat.st_uid == 0 && currentUID != 0 {
            if access(stdURL.path, W_OK) != 0 {
                return true
            }
        }

        return false
    }

    /// True if a path is a critical exact system/user root directory or shared vendor folder
    /// (used for filtering pkgutil, leftovers, and final removal validation).
    public func isCriticalSharedDirectory(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let std = url.standardizedFileURL.path
        if criticalExactPathsLower.contains(Self.normalizedForCompare(std)) {
            return true
        }
        if let real = Self.posixRealpath(std),
           criticalExactPathsLower.contains(Self.normalizedForCompare(real)) {
            return true
        }
        let last = url.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        let parent = url.deletingLastPathComponent().lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        if ["application support", "caches", "preferences", "logs"].contains(parent),
           (Self.sharedVendorFolderNames.contains(last) || last == "apple") {
            return true
        }
        return false
    }

    /// Validates raw standardized path, Foundation symlink-resolved path, AND POSIX `realpath(3)` before any deletion.
    /// Note: Deletion itself always targets the raw URL (never following symlinks).
    public func validateForRemoval(_ url: URL) -> RemovalValidationResult {
        let rawPath = url.standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path

        if !url.isFileURL || rawPath.isEmpty || rawPath == "/"
            || rawPath.contains("\0") || resolvedPath.contains("\0")
            || url.absoluteString.lowercased().contains("%00") {
            return .blocked(reason: "Cannot remove root or invalid filesystem path")
        }

        let candidates = Self.candidatePaths(for: url)

        for selfPath in selfBundlePathsLower where selfPath.hasSuffix(".app") {
            for entry in candidates where Self.pathsOverlap(entry.normalized, with: selfPath) {
                return .blocked(reason: "Cannot remove MacSweep itself")
            }
        }

        for normData in selfDataPathsLower {
            for entry in candidates where Self.pathsOverlap(entry.normalized, with: normData) {
                return .blocked(reason: "Cannot remove MacSweep application data")
            }
        }

        if isSIPRestricted(url) {
            return .blocked(reason: "Protected by macOS System Integrity Protection (SIP)")
        }

        if pointsToSystemVolume(url) {
            return .blocked(reason: "Symbolic link points to protected macOS system volume")
        }

        for (candidate, normCandidate) in candidates {
            if criticalExactPathsLower.contains(normCandidate) {
                return .blocked(reason: "Critical system or user directory: \(candidate)")
            }
            if isCriticalSharedDirectory(candidate) {
                return .blocked(reason: "Critical shared vendor directory: \(candidate)")
            }
            for barePrefix in immutableBarePrefixesLower {
                if Self.pathsOverlap(normCandidate, with: barePrefix) {
                    return .blocked(reason: "Protected macOS system or credential path: \(candidate)")
                }
            }
            if let reason = protectedSensitiveLibraryOrPhotosReason(candidate: candidate, normalizedPath: normCandidate) {
                return .blocked(reason: reason)
            }
            for protected in protectedPathsLower {
                if Self.pathsOverlap(normCandidate, with: protected) {
                    return .blocked(reason: "Protected by user skip list")
                }
            }
            if !protectedBundleIDs.isEmpty && matchesProtectedBundleInLibraryPath(candidate, normalizedPath: normCandidate, url: url) {
                return .blocked(reason: "Protected by user bundle ID skip list")
            }
        }

        if matchesProtectedAppBundle(at: url) {
            return .blocked(reason: "Protected by user bundle ID skip list")
        }

        return .allowed
    }

    private func firstChild(under prefixWithSlash: String, in normalizedPath: String) -> String? {
        guard normalizedPath.hasPrefix(prefixWithSlash) else { return nil }
        let remainder = normalizedPath.dropFirst(prefixWithSlash.count)
        guard !remainder.isEmpty else { return nil }
        if let slash = remainder.firstIndex(of: "/") {
            return String(remainder[..<slash])
        }
        return String(remainder)
    }

    private func protectedSensitiveLibraryOrPhotosReason(candidate: String, normalizedPath: String) -> String? {
        // Protect any Photos Library bundle (*.photoslibrary) and all of its contents anywhere on disk.
        let comps = URL(fileURLWithPath: normalizedPath).pathComponents
        if comps.contains(where: { $0.hasSuffix(".photoslibrary") && $0.count > ".photoslibrary".count }) {
            return "Protected Photos library: \(candidate)"
        }

        // System `/Library/Application Support/com.apple.*`
        if let sysAppSuppChild = firstChild(under: "/library/application support/", in: normalizedPath),
           (sysAppSuppChild == "com.apple" || sysAppSuppChild.hasPrefix("com.apple.")) {
            return "Protected Apple system support data: \(candidate)"
        }

        for homePrefix in homePrefixesLower {
            if let appSuppChild = firstChild(under: "\(homePrefix)/library/application support/", in: normalizedPath),
               (appSuppChild == "com.apple" || appSuppChild.hasPrefix("com.apple.")) {
                return "Protected Apple application support data: \(candidate)"
            }
            if let containerChild = firstChild(under: "\(homePrefix)/library/containers/", in: normalizedPath),
               (containerChild == "com.apple" || containerChild.hasPrefix("com.apple.")) {
                return "Protected Apple sandbox container: \(candidate)"
            }
            if let groupChild = firstChild(under: "\(homePrefix)/library/group containers/", in: normalizedPath),
               Self.isAppleGroupContainerName(groupChild) {
                return "Protected Apple group container: \(candidate)"
            }
            if let cookieChild = firstChild(under: "\(homePrefix)/library/cookies/", in: normalizedPath),
               (cookieChild == "cookies.binarycookies" || cookieChild == "hsts.plist"
                || cookieChild == "com.apple" || cookieChild.hasPrefix("com.apple.")) {
                return "Protected Apple cookies data: \(candidate)"
            }
        }
        return nil
    }

    private func matchesProtectedBundleInLibraryPath(_ path: String, normalizedPath: String, url: URL) -> Bool {
        let candidateURL = URL(fileURLWithPath: path)
        let parentName = candidateURL.deletingLastPathComponent().lastPathComponent
            .precomposedStringWithCanonicalMapping.lowercased()
        let isInLibraryOrLaunch = normalizedPath.contains("/library/")
            || Self.protectedBundleEnforcedParents.contains(parentName)
        guard isInLibraryOrLaunch else { return false }

        // Check leaf name, stripped stem/UUID, and (for nested files inside a protected container) ancestor
        // components directly under `/Library/...`.
        let components = candidateURL.pathComponents
        let startIndex: Int
        if let libIdx = components.lastIndex(where: { $0.precomposedStringWithCanonicalMapping.lowercased() == "library" }),
           libIdx + 2 < components.count {
            startIndex = libIdx + 2
        } else {
            startIndex = max(0, components.count - 1)
        }
        for idx in startIndex..<components.count {
            let comp = components[idx]
            let stem = LibraryEntry.stripKnownSuffixes(from: comp)
            let noUUID = InstalledAppInventory.stripUUIDSuffix(stem)
            if matchesProtectedBundleID(comp) || matchesProtectedBundleID(stem) || matchesProtectedBundleID(noUUID) {
                return true
            }
        }

        if (parentName == "launchagents" || parentName == "launchdaemons"),
           candidateURL.pathExtension.lowercased() == "plist",
           !isSymbolicLink(url),
           let label = LibraryIndex.parseLaunchPlistMetadata(at: url).label,
           matchesProtectedBundleID(label) {
            return true
        }
        return false
    }

    private func matchesProtectedAppBundle(at url: URL) -> Bool {
        guard !protectedBundleIDs.isEmpty,
              url.pathExtension.lowercased() == "app",
              !isSymbolicLink(url) else {
            return false
        }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = SafeFileReader.readBoundedRegularFile(at: infoURL),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = raw as? [String: Any],
              let bid = dict["CFBundleIdentifier"] as? String else {
            return false
        }
        return matchesProtectedBundleID(bid)
    }

    /// True if a Library entry name/identifier should never be flagged as an orphaned leftover.
    public func isProtectedFromLeftoverScan(
        name: String,
        bundleID: String?,
        parentVendorName: String? = nil
    ) -> Bool {
        if let parentVendor = parentVendorName?.lowercased(), parentVendor == "apple" {
            return true
        }
        let lowerName = name.lowercased()
        let strippedName = InstalledAppInventory.stripContainerPrefixes(lowerName)
        if lowerName == "com.apple" || strippedName == "com.apple" || strippedName.hasPrefix("com.apple.")
            || Self.isAppleGroupContainerName(lowerName) {
            return true
        }
        for prefix in Self.leftoverProtectedBundlePrefixes {
            if lowerName.hasPrefix(prefix) {
                return true
            }
        }
        if matchesProtectedBundleID(lowerName) {
            return true
        }
        if let bundleID {
            let lowerID = bundleID.lowercased()
            let strippedID = InstalledAppInventory.stripContainerPrefixes(lowerID)
            if lowerID == "com.apple" || strippedID == "com.apple" || strippedID.hasPrefix("com.apple.")
                || Self.isAppleGroupContainerName(lowerID) {
                return true
            }
            for prefix in Self.leftoverProtectedBundlePrefixes {
                if lowerID.hasPrefix(prefix) {
                    return true
                }
            }
            if matchesProtectedBundleID(lowerID) {
                return true
            }
        }
        if Self.leftoverSafeIgnoreNames.contains(lowerName) {
            return true
        }
        if Self.sharedVendorFolderNames.contains(lowerName) {
            return true
        }
        return false
    }
}

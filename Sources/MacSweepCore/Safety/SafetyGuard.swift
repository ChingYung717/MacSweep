import Darwin
import Foundation

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
    private let criticalExactPaths: Set<String>

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        selfBundlePath: String? = Bundle.main.bundlePath,
        protectedPaths: [String] = [],
        protectedBundleIDs: [String] = []
    ) {
        let stdHome = homeDirectory.standardizedFileURL.path
        let homeURL = URL(fileURLWithPath: stdHome)
        let dataPaths = [
            homeURL.appendingPathComponent("Library/Application Support/MacSweep").standardizedFileURL.path,
            homeURL.appendingPathComponent("Library/Preferences/local.macsweep.plist").standardizedFileURL.path,
            homeURL.appendingPathComponent("Library/Caches/local.macsweep").standardizedFileURL.path,
            homeURL.appendingPathComponent("Library/Saved Application State/local.macsweep.savedState").standardizedFileURL.path,
            homeURL.appendingPathComponent("Library/HTTPStorages/local.macsweep").standardizedFileURL.path,
            homeURL.appendingPathComponent("Library/WebKit/local.macsweep").standardizedFileURL.path,
        ]
        self.homeDirectoryPath = stdHome
        if let rawSelf = selfBundlePath {
            let url = URL(fileURLWithPath: rawSelf)
            self.selfBundlePath = url.standardizedFileURL.path
            self.selfResolvedBundlePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        } else {
            self.selfBundlePath = nil
            self.selfResolvedBundlePath = nil
        }
        self.selfDataPaths = dataPaths
        self.protectedPaths = Set(protectedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        self.protectedBundleIDs = Set(protectedBundleIDs.map { $0.lowercased() })
        self.criticalExactPaths = Self.makeCriticalExactPaths(home: stdHome, selfDataPaths: dataPaths)
    }

    // Directories that must NEVER be deleted themselves (neither directly nor via pkgutil/leftovers).
    private static func makeCriticalExactPaths(home h: String, selfDataPaths: [String]) -> Set<String> {
        var set: Set<String> = [
            "/",
            "/System",
            "/usr",
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
            "/tmp",
            "/private",
            "/private/etc",
            "/private/etc/paths.d",
            "/private/tmp",
            "/private/var",
            "/private/var/db",
            "/private/var/db/receipts",
            "/opt",
            "/opt/homebrew",
            "/Applications",
            "/Applications/Utilities",
            "/Users",
            "/Library",
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
            "/Library/Security",
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
        "/usr/bin/",
        "/usr/sbin/",
        "/usr/lib/",
        "/usr/libexec/",
        "/usr/share/",
        "/bin/",
        "/sbin/",
        "/private/var/db/receipts/",
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

    /// Checks POSIX `lstat` flags for SIP `SF_RESTRICTED` or `SF_IMMUTABLE` without following symlinks.
    public func isSIPRestricted(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        let restricted = (st.st_flags & UInt32(SF_RESTRICTED)) != 0
        let immutable = (st.st_flags & UInt32(SF_IMMUTABLE)) != 0
        return restricted || immutable
    }

    /// Returns true if `url` is a symbolic link without following it.
    public func isSymbolicLink(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// Returns true if `url` is a symlink whose target resolves inside `/System/` or `/Library/Apple/`.
    public func pointsToSystemVolume(_ url: URL) -> Bool {
        guard isSymbolicLink(url) else { return false }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix("/System/") || resolved == "/System" || resolved.hasPrefix("/Library/Apple/")
    }

    /// True for macOS built-in system apps (under `/System`, SIP-restricted, or symlink to system Cryptex/volume).
    /// Returns false for App Store Apple apps in `/Applications` such as Pages/Numbers/Keynote/TestFlight.
    public func isSystemProtectedApp(at url: URL) -> Bool {
        let stdPath = url.standardizedFileURL.path
        if stdPath.hasPrefix("/System/") || stdPath.hasPrefix("/Library/Apple/") {
            return true
        }
        if isSIPRestricted(url) || pointsToSystemVolume(url) {
            return true
        }
        return false
    }

    /// True if `url` or `bundleID` refers to MacSweep itself.
    public func isSelfApp(bundleID: String?, url: URL) -> Bool {
        if let bundleID, bundleID.lowercased() == "local.macsweep" {
            return true
        }
        let rawPath = url.standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        for selfPath in [selfBundlePath, selfResolvedBundlePath].compactMap({ $0 }) where selfPath.hasSuffix(".app") {
            if rawPath == selfPath || rawPath.hasPrefix(selfPath + "/")
                || resolvedPath == selfPath || resolvedPath.hasPrefix(selfPath + "/") {
                return true
            }
        }
        return false
    }

    /// True if the bundle ID belongs to an Apple app (e.g. `com.apple.iWork.Pages`).
    public func isAppleBundleID(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return lower.hasPrefix("com.apple.") || lower == "com.apple"
    }

    /// True if `bundleID` matches any user-protected bundle ID (exact or boundary sub-identifier).
    public func matchesProtectedBundleID(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        for protectedID in protectedBundleIDs {
            if ServiceFileMatcher.isBoundaryPrefixMatch(candidate: lower, prefix: protectedID) {
                return true
            }
        }
        return false
    }

    /// True if a bundle ID or path is explicitly marked protected by the user.
    public func isUserProtected(bundleID: String?, url: URL) -> Bool {
        if let bundleID, matchesProtectedBundleID(bundleID) {
            return true
        }
        let std = url.standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return protectedPaths.contains(std) || protectedPaths.contains(resolved)
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

    /// True if a path is a critical exact system/user root directory (used for filtering pkgutil & leftovers).
    public func isCriticalSharedDirectory(_ path: String) -> Bool {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        if criticalExactPaths.contains(std) {
            return true
        }
        let last = URL(fileURLWithPath: std).lastPathComponent.lowercased()
        let parent = URL(fileURLWithPath: std).deletingLastPathComponent().lastPathComponent.lowercased()
        if ["application support", "caches", "preferences", "logs"].contains(parent),
           (Self.sharedVendorFolderNames.contains(last) || last == "apple") {
            return true
        }
        return false
    }

    /// Validates both the raw standardized path AND symlink-resolved path before any deletion.
    /// Note: Deletion itself always targets the raw URL (never following symlinks).
    public func validateForRemoval(_ url: URL) -> RemovalValidationResult {
        let rawPath = url.standardizedFileURL.path
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path

        if rawPath.isEmpty || rawPath == "/" {
            return .blocked(reason: "Cannot remove root filesystem")
        }

        for selfPath in [selfBundlePath, selfResolvedBundlePath].compactMap({ $0 }) where selfPath.hasSuffix(".app") {
            if rawPath == selfPath || rawPath.hasPrefix(selfPath + "/")
                || resolvedPath == selfPath || resolvedPath.hasPrefix(selfPath + "/") {
                return .blocked(reason: "Cannot remove MacSweep itself")
            }
        }

        for selfData in selfDataPaths {
            if rawPath == selfData || rawPath.hasPrefix(selfData + "/")
                || resolvedPath == selfData || resolvedPath.hasPrefix(selfData + "/") {
                return .blocked(reason: "Cannot remove MacSweep application data")
            }
        }

        if isSIPRestricted(url) {
            return .blocked(reason: "Protected by macOS System Integrity Protection (SIP)")
        }

        if pointsToSystemVolume(url) {
            return .blocked(reason: "Symbolic link points to protected macOS system volume")
        }

        for candidate in [rawPath, resolvedPath] {
            if criticalExactPaths.contains(candidate) {
                return .blocked(reason: "Critical system or user directory: \(candidate)")
            }
            for prefix in Self.immutableSystemPrefixes {
                if candidate.hasPrefix(prefix) {
                    return .blocked(reason: "Protected macOS system path: \(candidate)")
                }
            }
            if protectedPaths.contains(candidate) {
                return .blocked(reason: "Protected by user skip list")
            }
        }

        return .allowed
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
        if lowerName == "com.apple" {
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

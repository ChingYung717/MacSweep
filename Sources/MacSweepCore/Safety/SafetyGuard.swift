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
    public let selfSupportPath: String
    public let protectedPaths: Set<String>
    public let protectedBundleIDs: Set<String>
    /// Precomputed once (was a computed property rebuilt on every `validateForRemoval` call).
    private let criticalExactPaths: Set<String>

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        selfBundlePath: String? = Bundle.main.bundlePath,
        protectedPaths: [String] = [],
        protectedBundleIDs: [String] = []
    ) {
        let stdHome = homeDirectory.standardizedFileURL.path
        let supportPath = URL(fileURLWithPath: stdHome)
            .appendingPathComponent("Library/Application Support/MacSweep")
            .standardizedFileURL.path
        self.homeDirectoryPath = stdHome
        self.selfBundlePath = selfBundlePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        self.selfSupportPath = supportPath
        self.protectedPaths = Set(protectedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        self.protectedBundleIDs = Set(protectedBundleIDs.map { $0.lowercased() })
        self.criticalExactPaths = Self.makeCriticalExactPaths(home: stdHome, selfSupportPath: supportPath)
    }

    // Directories that must NEVER be deleted themselves (neither directly nor via pkgutil/leftovers).
    private static func makeCriticalExactPaths(home h: String, selfSupportPath: String) -> Set<String> {
        return [
            "/",
            "/System",
            "/usr",
            "/usr/local",
            "/usr/local/bin",
            "/usr/local/lib",
            "/usr/local/share",
            "/bin",
            "/sbin",
            "/etc",
            "/var",
            "/private",
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
            "/Library/Caches",
            "/Library/Preferences",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons",
            "/Library/PrivilegedHelperTools",
            "/Library/PreferencePanes",
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
            "\(h)/Library/Application Scripts",
            "\(h)/Library/Caches",
            "\(h)/Library/Preferences",
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
            selfSupportPath,
        ]
    }

    private static let immutableSystemPrefixes: [String] = [
        "/System/",
        "/Library/Apple/",
        "/usr/bin/",
        "/usr/sbin/",
        "/usr/lib/",
        "/bin/",
        "/sbin/",
        "/private/var/db/receipts/",
    ]

    /// Lowercased directory/file names never flagged as leftovers or blindly removed.
    public static let leftoverSafeIgnoreNames: Set<String> = [
        // macOS / Apple system data
        "apple", "addressbook", "assistant", "biome", "bird", "caches", "calendars",
        "callhistorydb", "callhistorytransactions", "clouddocs", "cloudkit", "contacts",
        "coredata", "coreduet", "coremediaio", "crashreporter", "differentialprivacy",
        "dock", "dprivacyd", "facetime", "familycircle", "fileprovider", "findmy",
        "fontcollections", "geo", "group containers", "homekit", "icloud", "icdd",
        "identityservices", "imessage", "intelligenceplatform", "keychains", "knowledge",
        "mail", "mediaanalysis", "messages", "metadata", "mobilebackup", "mobilesync",
        "passkit", "personalizationportrait", "photos", "preferences", "proactiveeventtracker",
        "quicklook", "reminders", "safari", "screentime", "searchparty", "security",
        "sharing", "siri", "siritts", "spotlight", "stagedframeworks", "suggestions",
        "syncservices", "tcc", "tips", "trial", "ubiquity", "voicecontrol", "voicememos",
        "weather", "webkit", "widgets", "workflow",
        // Developer tools, CLI runtimes & AI agents
        "homebrew", "brew", "npm", "npx", "pnpm", "yarn", "bun", "deno", "node", "nvm",
        "fnm", "volta", "cargo", "rustup", "pip", "pipx", "poetry", "uv", "pyenv",
        "conda", "miniconda", "anaconda", "venv", "virtualenv", "go", "gopath", "gradle",
        "maven", "m2", "sbt", "ivy2", "cocoapods", "carthage", "swiftpm", "org.swift.swiftpm",
        "xcode", "developer", "coresimulator", "instruments", "docker", "colima", "orbstack",
        "lima", "podman", "kubectl", "kube", "helm", "terraform", "gcloud", "google-cloud-sdk",
        "aws", "azure", "gh", "git", "ssh", "gnupg", "gpg", "1password", "bitwarden",
        "antigravity", "gemini", "claude", "codex", "cursor", "windsurf", "vscode", "code",
        "jetbrains", "sublime text", "neovim", "nvim", "vim", "tmux", "zsh", "oh-my-zsh",
        "fish", "starship", "iterm2", "warp", "ghostty", "alacritty", "kitty",
        // MacSweep itself
        "macsweep", "local.macsweep",
    ]

    /// Shared vendor parent folders whose contents belong to multiple independent apps.
    public static let sharedVendorFolderNames: Set<String> = [
        "microsoft", "google", "adobe", "jetbrains", "apple", "tencent", "bytedance",
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

    /// True if the bundle ID belongs to an Apple app (e.g. `com.apple.iWork.Pages`).
    public func isAppleBundleID(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        return lower.hasPrefix("com.apple.") || lower == "com.apple"
    }

    /// True if a bundle ID or path is explicitly marked protected by the user.
    public func isUserProtected(bundleID: String?, url: URL) -> Bool {
        if let bundleID, protectedBundleIDs.contains(bundleID.lowercased()) {
            return true
        }
        let std = url.standardizedFileURL.path
        return protectedPaths.contains(std)
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
            // Sticky bit on parent (e.g., /tmp) requires owning the file or parent.
            let sticky = (parentStat.st_mode & S_ISVTX) != 0
            if sticky && itemStat.st_uid != currentUID && parentStat.st_uid != currentUID {
                return true
            }
        }

        // Root-owned bundles/directories (e.g. App Store apps in /Applications) aren't directly writable by non-root.
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
        // Also guard shared vendor parent directories directly under Application Support / Caches / etc.
        let last = URL(fileURLWithPath: std).lastPathComponent.lowercased()
        let parent = URL(fileURLWithPath: std).deletingLastPathComponent().lastPathComponent.lowercased()
        if ["application support", "caches", "preferences", "logs"].contains(parent),
           Self.sharedVendorFolderNames.contains(last) {
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

        if let selfBundle = selfBundlePath, selfBundle.hasSuffix(".app") {
            if rawPath == selfBundle || rawPath.hasPrefix(selfBundle + "/")
                || resolvedPath == selfBundle || resolvedPath.hasPrefix(selfBundle + "/") {
                return .blocked(reason: "Cannot remove MacSweep itself")
            }
        }

        if rawPath == selfSupportPath || rawPath.hasPrefix(selfSupportPath + "/")
            || resolvedPath == selfSupportPath || resolvedPath.hasPrefix(selfSupportPath + "/") {
            return .blocked(reason: "Cannot remove MacSweep application data")
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
    public func isProtectedFromLeftoverScan(name: String, bundleID: String?) -> Bool {
        let lowerName = name.lowercased()
        if lowerName.hasPrefix("com.apple.") || lowerName == "com.apple" || lowerName.hasPrefix("apple.") {
            return true
        }
        if let bundleID {
            let lowerID = bundleID.lowercased()
            if lowerID.hasPrefix("com.apple.") || lowerID.hasPrefix("group.com.apple.") || protectedBundleIDs.contains(lowerID) {
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

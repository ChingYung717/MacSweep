import Foundation

public struct LibraryEntry: Hashable, Sendable {
    public let url: URL
    public let name: String
    public let normalizedName: String
    public let stem: String
    public let category: ServiceFileCategory
    public let isSystemScope: Bool
    public let isInsideVendorFolder: Bool
    public let parentVendorName: String?
    public let launchLabel: String?
    public let launchProgramPaths: [String]
    public let associatedBundleIDs: [String]
    public let isHomeDotEntry: Bool
    public let requiresAdmin: Bool
    /// Result of `SafetyGuard.validateForRemoval` computed ONCE at index time, so per-app matching
    /// stays a pure in-memory pass (previously ~450k filesystem-touching validations ≈ 26 s).
    public let isRemovable: Bool
    /// Canonical POSIX parent directory captured at scan / index time for TOCTOU verification.
    public let expectedCanonicalParent: String

    public init(
        url: URL,
        category: ServiceFileCategory,
        isSystemScope: Bool,
        isInsideVendorFolder: Bool = false,
        parentVendorName: String? = nil,
        launchLabel: String? = nil,
        launchProgramPaths: [String] = [],
        associatedBundleIDs: [String] = [],
        isHomeDotEntry: Bool = false,
        requiresAdmin: Bool = false,
        isRemovable: Bool = true,
        expectedCanonicalParent: String? = nil
    ) {
        self.url = url
        self.name = url.lastPathComponent
        self.normalizedName = url.lastPathComponent.lowercased()
        self.stem = Self.stripKnownSuffixes(from: url.lastPathComponent)
        self.category = category
        self.isSystemScope = isSystemScope
        self.isInsideVendorFolder = isInsideVendorFolder
        self.parentVendorName = parentVendorName
        self.launchLabel = launchLabel
        self.launchProgramPaths = launchProgramPaths
        self.associatedBundleIDs = associatedBundleIDs
        self.isHomeDotEntry = isHomeDotEntry
        self.requiresAdmin = requiresAdmin
        self.isRemovable = isRemovable
        self.expectedCanonicalParent = expectedCanonicalParent
            ?? PrivilegedExecutor.canonicalParentPath(forTargetURL: url)
    }

    public static func stripKnownSuffixes(from name: String) -> String {
        let lower = name.lowercased()
        let suffixes = [
            ".plist",
            ".savedstate",
            ".binarycookies",
            ".app",
            ".helper",
            ".log",
            ".crash",
            ".ips",
            ".diag",
        ]
        for suffix in suffixes where lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }
}

/// Single-pass in-memory index of user and system Library locations.
/// Shared by `ServiceFileMatcher` and `LeftoverScanner` to avoid redundant directory traversals.
public struct LibraryIndex: Sendable {
    public let entries: [LibraryEntry]
    public let userLibraryURL: URL
    public let systemLibraryURL: URL
    public let createdAt: Date

    public init(
        entries: [LibraryEntry],
        userLibraryURL: URL,
        systemLibraryURL: URL,
        createdAt: Date = Date()
    ) {
        self.entries = entries
        self.userLibraryURL = userLibraryURL
        self.systemLibraryURL = systemLibraryURL
        self.createdAt = createdAt
    }

    /// Returns a new index with any entries matching `paths` (or nested under them) pruned.
    public func removing(paths: Set<String>) -> LibraryIndex {
        guard !paths.isEmpty else { return self }
        let normRemoved = Set(paths.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        })
        let filtered = entries.filter { entry in
            let p = entry.url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
            if normRemoved.contains(p) { return false }
            for removed in normRemoved where p.hasPrefix(removed + "/") {
                return false
            }
            return true
        }
        return LibraryIndex(
            entries: filtered,
            userLibraryURL: userLibraryURL,
            systemLibraryURL: systemLibraryURL,
            createdAt: createdAt
        )
    }

    public static func build(
        userLibraryURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library"),
        systemLibraryURL: URL = URL(fileURLWithPath: "/Library"),
        safetyGuard: SafetyGuard = SafetyGuard()
    ) -> LibraryIndex {
        let userSpecs: [(String, ServiceFileCategory, Bool)] = [
            ("Application Support", .applicationSupport, true),
            ("Caches", .caches, true),
            ("Preferences", .preferences, false),
            ("Preferences/ByHost", .preferences, false),
            ("Containers", .containers, false),
            ("Group Containers", .groupContainers, false),
            ("Application Scripts", .containers, false),
            ("Saved Application State", .savedState, false),
            ("HTTPStorages", .webData, false),
            ("WebKit", .webData, false),
            ("Cookies", .webData, false),
            ("Logs", .logs, true),
            ("Logs/DiagnosticReports", .logs, false),
            ("Application Support/CrashReporter", .logs, false),
            ("LaunchAgents", .launchAgents, false),
        ]

        let systemSpecs: [(String, ServiceFileCategory, Bool)] = [
            ("Application Support", .applicationSupport, true),
            ("Caches", .caches, true),
            ("Preferences", .preferences, false),
            ("Logs", .logs, true),
            ("LaunchAgents", .launchAgents, false),
            ("LaunchDaemons", .launchDaemons, false),
            ("PrivilegedHelperTools", .launchDaemons, false),
        ]

        var collected: [LibraryEntry] = []
        let fm = FileManager.default

        func scanDirectory(
            base: URL,
            relPath: String,
            category: ServiceFileCategory,
            expandVendors: Bool,
            isSystemScope: Bool
        ) {
            guard safetyGuard.isContainedCanonicalSubpath(relativePath: relPath, under: base) else {
                return
            }
            let dirURL = base.appendingPathComponent(relPath).standardizedFileURL
            guard let children = try? fm.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                return
            }
            let dirCanonicalParent = PrivilegedExecutor.canonicalParentPath(for: dirURL.path)

            for child in children {
                let childName = child.lastPathComponent
                let lowerName = childName.lowercased()

                // Skip CrashReporter inside Application Support since it has its own spec.
                if relPath == "Application Support" && lowerName == "crashreporter" {
                    continue
                }
                // Skip ByHost inside Preferences since it has its own spec.
                if relPath == "Preferences" && lowerName == "byhost" {
                    continue
                }

                // Never index or expand macOS's own `Apple` support/caches directories
                // (e.g. `/Library/Application Support/Apple/{BezelServices,Remote Desktop,EmbeddedOSInstall}`).
                if lowerName == "apple" {
                    continue
                }

                // Expand shared vendor folders 1 level deeper instead of treating the entire vendor dir as one app.
                if expandVendors && SafetyGuard.sharedVendorFolderNames.contains(lowerName) {
                    if safetyGuard.isContainedCanonicalSubpath(relativePath: childName, under: dirURL),
                       let subItems = try? fm.contentsOfDirectory(
                        at: child,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                       ) {
                        let vendorCanonicalParent = PrivilegedExecutor.canonicalParentPath(for: child.standardizedFileURL.path)
                        for sub in subItems {
                            let admin = safetyGuard.requiresAdmin(for: sub)
                            collected.append(LibraryEntry(
                                url: sub,
                                category: category,
                                isSystemScope: isSystemScope,
                                isInsideVendorFolder: true,
                                parentVendorName: childName,
                                requiresAdmin: admin,
                                isRemovable: safetyGuard.validateForRemoval(sub).isAllowed,
                                expectedCanonicalParent: vendorCanonicalParent
                            ))
                        }
                    }
                    continue
                }

                var launchLabel: String?
                var launchPrograms: [String] = []
                var associatedIDs: [String] = []
                if (category == .launchAgents || category == .launchDaemons),
                   child.pathExtension.lowercased() == "plist" {
                    let parsed = Self.parseLaunchPlistMetadata(at: child)
                    launchLabel = parsed.label
                    launchPrograms = parsed.programs
                    associatedIDs = parsed.associatedBundleIDs
                }

                let admin = safetyGuard.requiresAdmin(for: child)
                collected.append(LibraryEntry(
                    url: child,
                    category: category,
                    isSystemScope: isSystemScope,
                    launchLabel: launchLabel,
                    launchProgramPaths: launchPrograms,
                    associatedBundleIDs: associatedIDs,
                    requiresAdmin: admin,
                    isRemovable: safetyGuard.validateForRemoval(child).isAllowed,
                    expectedCanonicalParent: dirCanonicalParent
                ))
            }
        }

        if safetyGuard.isContainedDirectory(userLibraryURL) {
            for (rel, cat, expand) in userSpecs {
                scanDirectory(base: userLibraryURL, relPath: rel, category: cat, expandVendors: expand, isSystemScope: false)
            }
        }
        if safetyGuard.isContainedDirectory(systemLibraryURL) {
            for (rel, cat, expand) in systemSpecs {
                scanDirectory(base: systemLibraryURL, relPath: rel, category: cat, expandVendors: expand, isSystemScope: true)
            }
        }

        // Index safe app-specific home dot-folders (e.g. `~/.docker`) for installed app detail matching only.
        // Strictly excludes symlinks, shell/credential/developer tool dotfiles, and any path rejected by SafetyGuard.
        let homeURL = userLibraryURL.deletingLastPathComponent()
        if safetyGuard.isContainedDirectory(homeURL),
           let homeItems = try? fm.contentsOfDirectory(
            at: homeURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
           ) {
            let homeCanonicalParent = PrivilegedExecutor.canonicalParentPath(for: homeURL.standardizedFileURL.path)
            for child in homeItems {
                let name = child.lastPathComponent
                guard name.hasPrefix("."), name.count >= 6 else { continue }
                let lower = name.lowercased()
                let dotBody = String(lower.dropFirst())
                guard !Self.protectedHomeDotNames.contains(dotBody),
                      !dotBody.hasPrefix("zsh"),
                      !dotBody.hasPrefix("bash"),
                      !dotBody.hasPrefix("git"),
                      !dotBody.hasPrefix("vim"),
                      !dotBody.hasPrefix("ssh"),
                      !dotBody.hasPrefix("apple") else {
                    continue
                }
                guard !safetyGuard.isSymbolicLink(child) else { continue }
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                guard safetyGuard.validateForRemoval(child).isAllowed else { continue }
                let admin = safetyGuard.requiresAdmin(for: child)
                collected.append(LibraryEntry(
                    url: child,
                    category: .applicationSupport,
                    isSystemScope: false,
                    isHomeDotEntry: true,
                    requiresAdmin: admin,
                    isRemovable: true,
                    expectedCanonicalParent: homeCanonicalParent
                ))
            }
        }

        return LibraryIndex(
            entries: collected,
            userLibraryURL: userLibraryURL,
            systemLibraryURL: systemLibraryURL
        )
    }

    /// Shell, credential, package-manager, and general developer dot-folders under `~` that must
    /// never be associated with or removed alongside an app bundle.
    public static let protectedHomeDotNames: Set<String> = [
        "ssh", "gnupg", "gpg", "config", "local", "cache", "trash", "cups",
        "aws", "azure", "gcloud", "kube", "helm", "terraform", "ansible",
        "npm", "pnpm", "yarn", "bun", "nvm", "fnm", "volta", "deno",
        "cargo", "rustup", "go", "pyenv", "conda", "miniconda", "anaconda",
        "pip", "poetry", "rye", "uv", "rbenv", "rvm", "gem", "bundle",
        "gradle", "m2", "maven", "sbt", "ivy2", "sdkman", "jenv", "composer",
        "nvim", "emacs", "tmux", "profile", "zprofile", "zshrc", "bashrc",
        "gemini", "claude", "codex", "cursor", "vscode", "vscode-insiders",
        "android", "flutter", "pub-cache", "cocoapods", "swiftpm", "mint",
        "ds_store", "cfusertextencoding", "localized", "subversion", "netrc",
    ]

    public static func parseLaunchPlistMetadata(
        at url: URL
    ) -> (label: String?, programs: [String], associatedBundleIDs: [String]) {
        guard let data = SafeFileReader.readBoundedRegularFile(at: url),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = raw as? [String: Any] else {
            return (nil, [], [])
        }
        let label = dict["Label"] as? String
        var paths: [String] = []
        if let program = dict["Program"] as? String, !program.isEmpty {
            paths.append(program)
        }
        if let args = dict["ProgramArguments"] as? [String] {
            for arg in args where arg.hasPrefix("/") {
                if !paths.contains(arg) {
                    paths.append(arg)
                }
            }
        }
        var associated: [String] = []
        if let list = dict["AssociatedBundleIdentifiers"] as? [String] {
            for item in list {
                let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !associated.contains(trimmed) {
                    associated.append(trimmed)
                }
            }
        } else if let single = dict["AssociatedBundleIdentifiers"] as? String {
            let trimmed = single.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                associated.append(trimmed)
            }
        }
        return (label, paths, associated)
    }
}

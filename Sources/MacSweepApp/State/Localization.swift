import Foundation
import MacSweepCore

public struct L10n {
    public let isChinese: Bool

    public init(language: AppLanguage) {
        switch language {
        case .zhHans:
            self.isChinese = true
        case .en:
            self.isChinese = false
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            self.isChinese = preferred.hasPrefix("zh")
        }
    }

    func t(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }

    // Navigation Tabs
    var tabApplications: String { t("应用程序", "Applications") }
    var tabStartup: String { t("启动程序", "Startup") }
    var tabExtensions: String { t("扩展", "Extensions") }
    var tabLeftovers: String { t("残留文件", "Leftovers") }
    var tabFileManager: String { t("文件管理", "File Manager") }
    var tabJunkCleaner: String { t("垃圾清理", "Junk Cleaner") }
    var tabResourceRelease: String { t("资源释放", "Resources") }
    var resourceReleaseTitle: String { t("资源释放", "Resource Release") }
    public var settings: String { t("设置", "Settings") }

    // Common Actions
    var searchPlaceholder: String { t("搜索...", "Search...") }
    var refresh: String { t("刷新", "Refresh") }
    var remove: String { t("移除", "Remove") }
    var resetApp: String { t("重置", "Reset") }
    var cancel: String { t("取消", "Cancel") }
    var confirm: String { t("确认", "Confirm") }
    var close: String { t("关闭", "Close") }
    var selectAll: String { t("全选", "Select All") }
    var deselectAll: String { t("取消全选", "Clear") }
    var revealInFinder: String { t("在 Finder 中显示", "Reveal in Finder") }
    var openSettings: String { t("前往系统设置", "Open System Settings") }

    // Sort Options
    var sortBySize: String { t("大小", "Size") }
    var sortByName: String { t("名称", "Name") }
    var sortByLastUsed: String { t("最近使用", "Last Used") }
    var sortByModified: String { t("修改日期", "Modified") }

    // Size Buckets
    func bucketTitle(_ bucket: AppSizeBucket) -> String {
        switch bucket {
        case .over1GB: return t("大于 1 GB", "Over 1 GB")
        case .mb100To1GB: return t("100 MB - 1 GB", "100 MB - 1 GB")
        case .mb10To100: return t("10 MB - 100 MB", "10 MB - 100 MB")
        case .kb100To10MB: return t("100 KB - 10 MB", "100 KB - 10 MB")
        case .under100KB: return t("小于 100 KB", "Under 100 KB")
        case .calculating: return t("正在计算大小...", "Calculating size...")
        }
    }

    // Service File Categories
    func categoryTitle(_ category: ServiceFileCategory) -> String {
        switch category {
        case .application: return t("应用程序本体", "Application Bundle")
        case .applicationSupport: return t("应用支持数据", "Application Support")
        case .containers: return t("沙盒容器与脚本", "Containers & Scripts")
        case .groupContainers: return t("共享容器组", "Group Containers")
        case .caches: return t("缓存文件", "Caches")
        case .preferences: return t("偏好设置", "Preferences")
        case .launchAgents: return t("用户启动代理", "Launch Agents")
        case .launchDaemons: return t("系统守护进程与助手", "Launch Daemons & Helpers")
        case .savedState: return t("窗口恢复状态", "Saved Application State")
        case .webData: return t("网络与 Cookie 数据", "WebKit & HTTP Storage")
        case .logs: return t("日志与崩溃报告", "Logs & Crash Reports")
        case .plugins: return t("插件与驱动", "Plugins & Drivers")
        case .receipts: return t("安装包组件", "Package Components")
        case .other: return t("其他关联文件", "Other Related Files")
        }
    }

    // Startup Scopes
    func startupScopeTitle(_ scope: StartupScope) -> String {
        switch scope {
        case .userAgent: return t("用户启动代理", "User Launch Agents")
        case .systemAgent: return t("系统启动代理", "System Launch Agents")
        case .systemDaemon: return t("系统守护进程", "System Launch Daemons")
        case .appLoginItem: return t("应用登录项", "App Login Items")
        }
    }

    // Extension Categories
    func extensionCategoryTitle(_ cat: ExtensionCategory) -> String {
        switch cat {
        case .browserChrome: return "Google Chrome"
        case .browserEdge: return "Microsoft Edge"
        case .browserBrave: return "Brave"
        case .browserArc: return "Arc"
        case .browserFirefox: return "Firefox"
        case .browserSafari: return t("Safari 扩展", "Safari Extensions")
        case .appExtension: return t("macOS 应用扩展", "App Extensions")
        case .preferencePane: return t("偏好设置面板", "Preference Panes")
        case .quickLook: return t("快速查看插件", "QuickLook Generators")
        case .spotlight: return t("聚焦搜索插件", "Spotlight Importers")
        case .screenSaver: return t("屏幕保护程序", "Screen Savers")
        case .internetPlugin: return t("互联网插件", "Internet Plug-Ins")
        case .audioPlugin: return t("音频插件", "Audio Plug-Ins")
        }
    }

    // Applications View
    var scanningServiceFiles: String { t("正在扫描服务文件...", "Scanning service files...") }
    var scanningSubtitle: String { t("请稍候，正在索引应用与关联数据", "Please wait while indexing applications and related files") }
    var selectAppPromptTitle: String { t("选择一个应用程序", "Select an Application") }
    var selectAppPromptSubtitle: String { t("点击左侧应用查看所有服务文件，支持彻底卸载或仅重置数据", "Select an app on the left to inspect its service files for uninstall or reset") }
    var dropZoneTitle: String { t("拖放应用程序以快速卸载", "Drop an application here for quick uninstall") }
    var dropZoneActive: String { t("松开鼠标立即扫描关联文件", "Release to scan associated service files") }
    var uninstallMode: String { t("彻底卸载", "Uninstall") }
    var resetMode: String { t("仅重置数据", "Reset Data") }
    var runningBadge: String { t("运行中", "Running") }
    var quitApp: String { t("退出应用", "Quit App") }
    var protectedBadge: String { t("已保护", "Protected") }
    var systemProtectedBadge: String { t("系统保护", "SIP Protected") }
    var appleStoreWarning: String { t("Apple App Store 应用：可卸载并随时从 App Store 重新下载", "Apple App Store app: removable and can be redownloaded anytime from the App Store") }
    var protectApp: String { t("保护此应用", "Protect") }
    var unprotectApp: String { t("取消保护", "Unprotect") }
    var adminBadge: String { t("需管理员权限", "Admin") }
    var rebootBadge: String { t("需重启生效", "Reboot Required") }
    var noServiceFiles: String { t("未发现额外的服务文件", "No additional service files found") }
    var pkgReceiptsNote: String { t("同时清理安装包回执", "Will also forget installer receipts") }
    var expertMode: String { t("专家模式", "Expert Mode") }
    var appFilesAndFoldersLabel: String { t("应用程序文件和文件夹", "Application Files and Folders") }
    var developerLabel: String { t("开发人员", "Developer") }
    var appVerificationLabel: String { t("App 验证", "App Verification") }
    var unknownDeveloper: String { t("未知开发者", "Unknown Developer") }
    var moreInfo: String { t("更多信息", "More Info") }
    var hideInfo: String { t("收起信息", "Less Info") }
    var architectureLabel: String { t("架构", "Architecture") }
    var teamIDLabel: String { t("团队 ID", "Team ID") }
    var minSystemLabel: String { t("最低系统版本", "Minimum macOS") }
    var lastUsedLabel: String { t("上次使用", "Last Used") }
    var modifiedLabel: String { t("修改日期", "Modified") }
    var installPathLabel: String { t("安装路径", "Location") }
    var versionLabel: String { t("版本", "Version") }

    func verificationStatusTitle(_ status: AppVerificationStatus) -> String {
        switch status {
        case .appleSystem: return t("Apple 系统签名", "Apple System")
        case .appStore: return t("App Store 已验证", "Mac App Store")
        case .notarized: return t("已公证", "Notarized")
        case .developerSigned: return t("已签名", "Signed")
        case .adHocOrUnsigned: return t("未签名 / 临时签名", "Unsigned / Ad-hoc")
        }
    }

    func itemCountLabel(_ count: Int) -> String {
        isChinese ? "\(count) 个项目" : "\(count) items"
    }

    func filesAndFoldersSummary(files: Int, folders: Int) -> String {
        if isChinese {
            if folders > 0 && files > 0 {
                return "\(files) 个文件和 \(folders) 个文件夹"
            } else if folders > 0 {
                return "\(folders) 个文件夹"
            } else {
                return "\(files) 个文件"
            }
        } else {
            if folders > 0 && files > 0 {
                return "\(files) files and \(folders) folders"
            } else if folders > 0 {
                return "\(folders) folders"
            } else {
                return "\(files) files"
            }
        }
    }

    // Permissions
    var fdaGranted: String { t("完全磁盘访问已授权", "Full Disk Access Granted") }
    var fdaMissing: String { t("未授予完全磁盘访问权限", "Full Disk Access Not Granted") }
    var fdaBannerText: String { t("授予「完全磁盘访问」后可完整扫描受保护容器与浏览器扩展", "Grant Full Disk Access to scan protected containers and browser extensions") }
    var appManagementTip: String { t("若卸载应用提示无权限，请在「系统设置 → 隐私与安全性 → App 管理」中允许 MacSweep。若列表尚未显示 MacSweep，可点击左下角「+」手动添加，或将 Finder 中的 MacSweep.app 直接拖入列表。", "If uninstalling an app fails with permission denied, allow MacSweep in Privacy & Security → App Management. If MacSweep is not listed yet, click '+' at the bottom-left or drag MacSweep.app from Finder into the list.") }

    // Settings — Skip List (Protected Paths)
    var protectedPathsTitle: String { t("受保护的路径", "Protected Paths") }
    var protectedPathsDescription: String { t("以下路径及其子内容受保护，不会被扫描清理、移动、重命名或删除。", "Paths listed here (and their contents) are protected from cleanup, move, rename, or removal.") }
    var protectedPathsEmpty: String { t("暂无受保护路径。可手动输入路径或点击「选择路径」添加。", "No protected paths. Enter a path or click Browse to add one.") }
    var protectedPathPlaceholder: String { t("输入绝对路径，例如 ~/Documents/Vault", "Enter absolute path, e.g. ~/Documents/Vault") }
    var browsePath: String { t("选择路径...", "Browse...") }
    var addPath: String { t("添加", "Add") }
    var invalidPathError: String { t("请输入有效的绝对路径（支持以 ~ 开头）。", "Please enter a valid absolute path (or start with ~).") }
    var duplicatePathError: String { t("该路径已在保护名单中。", "This path is already in the Skip List.") }
    var pathMissingOnDisk: String { t("路径当前不存在", "Not found on disk") }
    var preferencesSaveFailedWarning: String {
        t(
            "设置已在当前会话生效，但未能写入偏好设置文件（可能因配置文件损坏或只读），重启后将不会保留。",
            "Updated for this session, but failed to save preferences (file may be corrupted or read-only); changes will not persist after restart."
        )
    }

    // Confirmation Sheet
    var confirmUninstallTitle: String { t("确认移除所选项目", "Confirm Removal") }
    public var confirmResetTitle: String { t("确认重置应用数据", "Confirm App Reset") }

    public func confirmRemovalTitle(for tab: MainTab, isReset: Bool) -> String {
        if isReset {
            return confirmResetTitle
        }
        switch tab {
        case .applications:
            return t("确认卸载应用", "Confirm App Uninstall")
        case .startup:
            return t("确认移除启动项", "Confirm Startup Item Removal")
        case .extensions:
            return t("确认移除扩展", "Confirm Extension Removal")
        case .leftovers:
            return t("确认清理残留文件", "Confirm Leftover Cleanup")
        case .fileManager:
            return t("确认移除所选文件", "Confirm File Removal")
        case .junkCleaner:
            return t("确认清理垃圾与缓存", "Confirm Junk Cleanup")
        case .resourceRelease:
            return t("确认清理所选资源", "Confirm Resource Cleanup")
        }
    }
    var moveToTrashOption: String { t("移至废纸篓（推荐 · 可放回原处）", "Move to Trash (Recommended · Recoverable)") }
    var permanentDeleteOption: String { t("永久删除（不可恢复）", "Delete Permanently (Irreversible)") }
    var runningAppsWarning: String { t("以下应用正在运行，操作前将先自动退出：", "The following apps are running and will be quit first:") }
    var resetForceQuitNote: String { t("重置前必须退出应用，以防系统偏好缓存（cfprefsd）回写旧配置。", "Apps must quit before resetting so macOS preference cache (cfprefsd) does not write stale data back.") }
    var adminAuthNote: String { t("包含系统/受限目录项，确认后将弹出系统授权（优先委托 Finder 保留「放回原处」）。", "Includes root/protected paths. System authorization will be requested (delegating to Finder first to preserve Put Back).") }
    var userLockedItemsNote: String { t("部分所选项目已被用户锁定（uchg），确认后将自动解锁并移除。", "Some selected items are locked by the user (uchg) and will be unlocked before removal.") }
    var chromiumSyncNote: String { t("提示：若浏览器开启了账号云同步，移除的扩展可能会在下次同步时自动恢复。", "Note: If browser account sync is enabled, removed extensions may be restored automatically on next sync.") }

    @MainActor
    private static let zhDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.dateFormat = "yyyy年M月d日"
        return df
    }()

    @MainActor
    private static let enDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US")
        df.dateFormat = "MMM d, yyyy"
        return df
    }()

    @MainActor
    func formatDate(_ date: Date?) -> String {
        guard let date else { return t("未知日期", "Unknown") }
        return isChinese ? Self.zhDateFormatter.string(from: date) : Self.enDateFormatter.string(from: date)
    }

    @MainActor
    func selectedSummary(count: Int, bytes: Int64) -> String {
        if isChinese {
            return "已选 \(count) 项 · \(ByteFormatter.format(bytes))"
        } else {
            return "\(count) selected · \(ByteFormatter.format(bytes))"
        }
    }

    func totalAppsCount(_ count: Int) -> String {
        isChinese ? "共 \(count) 个应用" : "\(count) apps"
    }

    // MARK: - File Manager (M2)

    var fileManagerSpaceAnalyzer: String { t("空间分析", "Space Analyzer") }
    var fileManagerFileBrowser: String { t("文件浏览", "File Browser") }

    // Space Analyzer
    var homeFolder: String { t("主目录", "Home") }
    var applicationsFolder: String { t("应用程序", "Applications") }
    var volumesSection: String { t("磁盘卷", "Volumes") }
    var chooseFolder: String { t("自选目录...", "Choose Folder...") }
    var volumeTotalLabel: String { t("总容量", "Total") }
    var volumeUsedLabel: String { t("已用", "Used") }
    var volumeAvailableLabel: String { t("可用", "Available") }
    var analyzedFolderLabel: String { t("当前分析", "Analyzed") }
    var analyzingSpace: String { t("正在分析磁盘空间...", "Analyzing disk space...") }
    var startAnalysis: String { t("开始分析", "Analyze") }
    var stopScan: String { t("停止扫描", "Stop") }
    var filterAll: String { t("全部", "All") }
    var filterOver50MB: String { t("≥ 50 MB", "≥ 50 MB") }
    var filterOver100MB: String { t("≥ 100 MB", "≥ 100 MB") }
    var filterOver500MB: String { t("≥ 500 MB", "≥ 500 MB") }
    var filterOver1GB: String { t("≥ 1 GB", "≥ 1 GB") }
    var filterOlder90Days: String { t("> 90 天", "> 90 Days") }
    var filterOlder180Days: String { t("> 180 天", "> 180 Days") }
    var filterOlder365Days: String { t("> 365 天", "> 365 Days") }
    var ageBasisModified: String { t("按修改日期", "By Modified") }
    var ageBasisAccessed: String { t("按访问日期", "By Accessed") }
    var truncatedTreeNote: String { t("部分子目录已截断（完整体积已计入父项）", "Partially truncated (exact roll-up included)") }
    var reanalyzeHere: String { t("以此为根扫描", "Analyze Here") }
    var cleanSelected: String { t("清理所选", "Clean Selected") }
    var emptyAnalyzerTitle: String { t("选择目录分析磁盘占用", "Select a Folder to Analyze") }
    var emptyAnalyzerSubtitle: String { t("快速定位大体积目录与陈旧文件，遵循安全边界与废纸篓优先清理", "Locate space hogs and stale files safely with Trash-first cleanup") }
    var noFilteredResults: String { t("没有符合当前筛选条件的项目", "No items match the active filters") }
    var deepFilterActive: String { t("正在深度检索子树...", "Searching deeper subtree...") }

    func scannedItemsCount(_ files: Int, folders: Int) -> String {
        isChinese ? "已扫描 \(files) 个文件 · \(folders) 个文件夹" : "\(files) files · \(folders) folders scanned"
    }

    @MainActor
    func truncatedRemainderLabel(_ count: Int, bytes: UInt64) -> String {
        let formatted = ByteFormatter.format(bytes)
        return isChinese
            ? "另有 \(count) 个较小子项未展开（共 \(formatted)）"
            : "\(count) smaller items omitted (\(formatted) total)"
    }

    // File Browser
    var favoritesTitle: String { t("常用位置", "Favorites") }
    var desktopFolder: String { t("桌面", "Desktop") }
    var documentsFolder: String { t("文稿", "Documents") }
    var downloadsFolder: String { t("下载", "Downloads") }
    var userCachesFolder: String { t("用户缓存", "User Caches") }
    var navBack: String { t("后退", "Back") }
    var navForward: String { t("前进", "Forward") }
    var navUp: String { t("上级目录", "Enclosing Folder") }
    var showHiddenFiles: String { t("显示隐藏文件", "Show Hidden Files") }
    var hideHiddenFiles: String { t("隐藏点文件", "Hide Hidden Files") }
    var hiddenFilesChipLabel: String { t("隐藏文件", "Hidden Files") }
    var hiddenBadge: String { t("隐藏", "Hidden") }
    var includeHiddenFilesHelp: String {
        t(
            "扫描并显示隐藏文件与文件夹（如 .git、.cache、~/Library）",
            "Scan and display hidden files and folders (e.g. .git, .cache, ~/Library)"
        )
    }
    var junkHiddenFilesHelp: String {
        t(
            "显示或隐藏缓存、日志与废纸篓中的隐藏项目（以 . 开头或带隐藏标志）",
            "Show or hide hidden items (dot-files or UF_HIDDEN) in caches, logs, and Trash"
        )
    }
    var newFolder: String { t("新建文件夹", "New Folder") }
    var renameItem: String { t("重命名", "Rename") }
    var moveTo: String { t("移动到...", "Move To...") }
    var moveToTrash: String { t("移至废纸篓", "Move to Trash") }
    var deletePermanently: String { t("永久删除", "Delete Permanently") }
    var quickLook: String { t("快速查看", "Quick Look") }
    var protectPath: String { t("加入保护名单", "Protect") }
    var toggleInspector: String { t("检查器", "Inspector") }
    var sortByKind: String { t("类型", "Kind") }
    var sortAscending: String { t("升序", "Ascending") }
    var sortDescending: String { t("降序", "Descending") }
    var emptyDirectoryLabel: String { t("此文件夹为空", "This folder is empty") }
    var newFolderPrompt: String { t("输入新文件夹名称", "Enter new folder name") }
    var folderNamePlaceholder: String { t("未命名文件夹", "Untitled Folder") }
    var createAction: String { t("创建", "Create") }
    var renamePrompt: String { t("重命名项目", "Rename Item") }
    var renameAction: String { t("重命名", "Rename") }
    var chooseMoveDestination: String { t("选择目标文件夹", "Choose Destination Folder") }

    // Inspector & Preview
    var inspectorTitle: String { t("文件检查器", "Inspector") }
    var contentPreviewTitle: String { t("内容预览", "Preview") }
    var kindLabel: String { t("类型", "Kind") }
    var sizeLabel: String { t("大小", "Size") }
    var allocatedSizeLabel: String { t("占用空间", "On Disk") }
    var createdLabel: String { t("创建时间", "Created") }
    var accessedLabel: String { t("访问时间", "Last Opened") }
    var permissionsLabel: String { t("POSIX 权限", "Permissions") }
    var symbolicLinkTargetLabel: String { t("链接目标", "Symlink Target") }
    var brokenSymlinkBadge: String { t("断链", "Broken Link") }
    var userLockedBadge: String { t("用户锁定 (uchg)", "Locked (uchg)") }
    var datalessBadge: String { t("iCloud 占位", "iCloud Dataless") }
    var packageBadge: String { t("软件包", "Package") }
    var symlinkBadge: String { t("替身/符号链接", "Symlink") }
    var previewUnavailable: String { t("暂不可预览", "Preview Unavailable") }
    var binaryHexPreview: String { t("十六进制摘要", "Hex Summary") }
    var folderPermissionDenied: String { t("无权读取该目录内容", "Permission denied reading this folder") }
    var folderFDAAction: String { t("授予完全磁盘访问权限", "Grant Full Disk Access") }
    var selectItemToInspect: String { t("选择一个文件或文件夹查看详情", "Select a file or folder to inspect") }

    @MainActor
    func previewTruncated(_ shownBytes: Int, total: Int64?) -> String {
        let shownStr = ByteFormatter.format(Int64(shownBytes))
        if let total {
            let totalStr = ByteFormatter.format(total)
            return isChinese
                ? "已截断预览前 \(shownStr)（文件总计 \(totalStr)）"
                : "Showing first \(shownStr) of \(totalStr)"
        }
        return isChinese ? "已截断预览前 \(shownStr)" : "Showing first \(shownStr)"
    }

    @MainActor
    func previewUnavailableReasonText(_ reason: FilePreviewUnavailableReason) -> String {
        switch reason {
        case .directory:
            return t("文件夹不支持内容文本预览，可双击进入或在 Finder 中打开。", "Folders do not have inline text preview.")
        case .symbolicLink:
            return t("为防止越权跟随，符号链接不直接读取目标内容。", "Symlinks are not dereferenced for inline preview.")
        case .specialFile:
            return t("设备节点或命名管道等特殊文件已跳过读取，避免阻塞。", "Special files (FIFO/device/socket) are skipped to prevent blocking.")
        case .datalessCloudFile:
            return t("此文件仅在 iCloud 云端占位（SF_DATALESS），已跳过读取以避免触发自动下载。", "iCloud dataless placeholder (SF_DATALESS) skipped to avoid implicit download.")
        case .emptyFile:
            return t("空文件（0 字节）。", "Empty file (0 bytes).")
        case let .imageTooLarge(actual, maxBytes):
            let maxStr = ByteFormatter.format(Int64(maxBytes))
            if let actual {
                return t("图片体积（\(ByteFormatter.format(actual))）超出安全预览上限（\(maxStr)）。", "Image (\(ByteFormatter.format(actual))) exceeds safe preview limit (\(maxStr)).")
            }
            return t("图片体积超出安全预览上限（\(maxStr)）。", "Image exceeds safe preview limit (\(maxStr)).")
        case .permissionDenied:
            return t("没有读取此文件的权限。", "Permission denied reading this file.")
        case .notFound:
            return t("文件已不存在。", "File no longer exists.")
        case let .unreadable(errno):
            return t("无法读取文件内容（POSIX 错误 \(errno)）。", "Unable to read file content (POSIX error \(errno)).")
        }
    }

    // Status & Errors
    func folderCreatedMessage(_ name: String) -> String {
        isChinese ? "已创建文件夹：\(name)" : "Created folder: \(name)"
    }

    func itemRenamedMessage(_ name: String) -> String {
        isChinese ? "已重命名为：\(name)" : "Renamed to: \(name)"
    }

    func itemsMovedMessage(count: Int, destination: String) -> String {
        isChinese ? "已移动 \(count) 个项目至 \(destination)" : "Moved \(count) item(s) to \(destination)"
    }

    func protectedAddedMessage(_ name: String) -> String {
        isChinese ? "已加入保护名单：\(name)" : "Added to Skip List: \(name)"
    }

    func invalidFileNameError(_ name: String) -> String {
        if name.isEmpty {
            return t("名称不能为空。", "Name cannot be empty.")
        }
        return t("名称包含非法字符（如 /、NUL）或为保留名（. / ..）。", "Invalid name (cannot be '.', '..', or contain '/' / NUL).")
    }

    var fileOperationBlockedTitle: String { t("受安全策略保护，无法执行该操作", "Blocked by Safety Policy") }

    // MARK: - Junk Cleaner & Resource Release (M3)

    // Junk Cleaner
    var junkScanAction: String { t("扫描垃圾", "Scan Junk") }
    var junkSafeSelect: String { t("安全全选", "Safe Select") }
    var junkClearAll: String { t("全部取消", "Clear All") }
    var junkAllCleanTitle: String { t("当前分类非常干净", "This Category Is Clean") }
    var junkAllCleanSubtitle: String { t("未发现可清理的缓存、日志或废纸篓残留项。", "No cleanable caches, logs, or Trash items were found.") }
    var junkEmptyPromptTitle: String { t("点击扫描垃圾与缓存", "Scan for Junk & Caches") }
    var junkEmptyPromptSubtitle: String { t("安全扫描应用缓存、日志与崩溃报告、浏览器缓存、开发缓存及废纸篓内容。", "Safely scan app caches, logs, browser caches, developer caches, and Trash contents.") }
    var junkSafetyNoteTitle: String { t("安全保护说明", "Safety Boundary") }
    var junkRunningAppBlocked: String { t("应用运行中", "App Running") }
    var junkCleanAction: String { t("清理所选", "Clean Selected") }
    var junkQuitBrowsersFirst: String { t("所选浏览器缓存对应的浏览器正在运行，请先退出浏览器后再清理。", "A selected browser is currently running. Quit the browser before clearing its cache.") }
    var junkTrashPermanentNote: String { t("所选项目均为废纸篓内容，清空废纸篓仅支持永久删除。", "All selected items are inside Trash; emptying Trash requires permanent deletion.") }
    var junkMixedTrashWarning: String { t("所选项目包含废纸篓内容：废纸篓内的项目将永久删除，其余项目将按下方所选方式处理（默认移至废纸篓）。", "Selection includes Trash items: items inside Trash will be permanently deleted, while all other items will follow the mode selected below (Move to Trash by default).") }

    func junkCategoryTitle(_ category: JunkCategory) -> String {
        switch category {
        case .userCaches: return t("用户与应用缓存", "User & App Caches")
        case .logs: return t("日志与崩溃报告", "Logs & Crash Reports")
        case .browserCaches: return t("浏览器缓存", "Browser Caches")
        case .developerCaches: return t("开发者缓存", "Developer Caches")
        case .trash: return t("废纸篓内容", "Trash Contents")
        }
    }

    func junkCategoryDescription(_ category: JunkCategory) -> String {
        switch category {
        case .userCaches:
            return t("~/Library/Caches 下可安全重建的应用缓存（自动跳过系统与共享厂商根目录）。", "Reclaimable application caches under ~/Library/Caches (Apple & bare vendor roots excluded).")
        case .logs:
            return t("用户与系统诊断日志及崩溃报告（系统日志默认不勾选且需管理员权限）。", "Diagnostic logs and crash reports (system logs stay unchecked by default).")
        case .browserCaches:
            return t("主流第三方浏览器缓存目录（绝不触碰书签、Cookie、历史记录或密码）。", "Third-party browser cache subpaths only (never bookmarks, cookies, history, or passwords).")
        case .developerCaches:
            return t("Xcode DerivedData、模拟器缓存及包管理器下载缓存（Archives 默认保留）。", "Xcode DerivedData, Simulator caches, and package caches (Archives unchecked by default).")
        case .trash:
            return t("当前废纸篓内的直接子项（需确认后永久删除以释放空间）。", "Direct items inside ~/.Trash (requires confirmation for permanent deletion).")
        }
    }

    func junkCategorySafetyNote(_ category: JunkCategory) -> String {
        switch category {
        case .userCaches:
            return t("已自动保护 Apple 系统缓存、MacSweep 自身数据及 Google/Microsoft/Adobe 等共享厂商根目录，仅定位到具体应用子目录。", "Apple caches, MacSweep data, and bare shared vendor directories (e.g. Google, Microsoft, Adobe) are strictly protected.")
        case .logs:
            return t("不会删除 Library/Logs 与 DiagnosticReports 根文件夹本身；/Library/Logs 系统项需管理员授权且默认不勾选。", "Parent log directories are never removed; /Library/Logs entries require administrator privileges and stay unchecked.")
        case .browserCaches:
            return t("仅清理缓存子路径。Safari 受 macOS 沙盒系统保护，请在 Safari 内部清理历史与缓存。", "Targets cache folders only. Safari is protected by macOS sandbox; clear Safari caches from within Safari.")
        case .developerCaches:
            return t("Xcode Archives 与 DeviceSupport 默认不勾选，避免误删已签名归档与真机调试符号；绝不触碰工具链二进制文件。", "Xcode Archives and DeviceSupport are unchecked by default to protect signed builds and device symbols.")
        case .trash:
            return t("废纸篓中的项目无法再「移至废纸篓」，确认清理时将直接永久删除。", "Items already inside Trash can only be permanently deleted.")
        }
    }

    // Large Files
    var subTabLargeFiles: String { t("大文件", "Large Files") }
    var largeFilesScanAction: String { t("扫描大文件", "Scan Large Files") }
    var largeFilesEmptyTitle: String { t("未扫描或未发现大文件", "No Large Files Found") }
    var largeFilesEmptySubtitle: String { t("选择目录与体积阈值，快速排查占满磁盘的视频、镜像、安装包与归档文件。", "Select a folder and size threshold to locate oversized videos, disk images, and archives.") }
    var largeFilesCategoryAll: String { t("全部类型", "All Types") }
    var largeFilesCatVideo: String { t("视频", "Videos") }
    var largeFilesCatArchive: String { t("镜像与归档", "Archives & DMG") }
    var largeFilesCatInstaller: String { t("安装包", "Installers") }
    var largeFilesCatAudio: String { t("音频", "Audio") }
    var largeFilesCatDocument: String { t("文档", "Documents") }
    var largeFilesCatOther: String { t("其他", "Other") }
    var largeFilesSortSize: String { t("按大小", "Size") }
    var largeFilesSortModified: String { t("按修改时间", "Modified") }
    var largeFilesSortName: String { t("按名称", "Name") }
    var largeFilesMinSizeLabel: String { t("阈值", "Min Size") }

    func largeFileCategoryTitle(_ category: LargeFileCategory) -> String {
        switch category {
        case .video: return largeFilesCatVideo
        case .diskImageAndArchive: return largeFilesCatArchive
        case .installer: return largeFilesCatInstaller
        case .audio: return largeFilesCatAudio
        case .document: return largeFilesCatDocument
        case .other: return largeFilesCatOther
        }
    }

    // Duplicate Files
    var subTabDuplicates: String { t("重复文件", "Duplicates") }
    var scanDuplicates: String { t("扫描重复文件", "Scan Duplicates") }
    var duplicatesEmptyTitle: String { t("三阶段精准查重", "3-Stage Exact Duplicate Finder") }
    var duplicatesEmptySubtitle: String { t("按精确字节大小 → 头尾局部哈希 → 完整 SHA-256 流式校验识别完全一致的副本，自动跳过硬链接、符号链接、云端占位与软件包内部。", "Matches by exact size -> head/tail partial hash -> full SHA-256, automatically skipping hardlinks, symlinks, dataless placeholders, and app bundles.") }
    var duplicateSmartSelect: String { t("智能勾选", "Smart Select") }
    var duplicateKeepNewest: String { t("保留最新修改", "Keep Newest") }
    var duplicateKeepOldest: String { t("保留最早创建", "Keep Oldest") }
    var duplicateKeepShortestPath: String { t("保留最短路径", "Keep Shortest Path") }
    var duplicatePreferNonDownloads: String { t("优先保留非下载目录", "Prefer Non-Downloads") }
    var duplicateClearSelection: String { t("全部取消", "Clear Selection") }
    var duplicateKeepLabel: String { t("保留", "Keep") }
    var duplicateDeleteLabel: String { t("将清理", "Delete") }
    var duplicateReclaimableLabel: String { t("可释放", "Reclaimable") }
    var duplicateStageSize: String { t("阶段 1/3：按精确文件大小分组", "Stage 1/3: Exact Size Grouping") }
    var duplicateStagePartialHash: String { t("阶段 2/3：头尾局部哈希筛选", "Stage 2/3: Partial Hash Filtering") }
    var duplicateStageFullHash: String { t("阶段 3/3：完整 SHA-256 校验", "Stage 3/3: Full SHA-256 Verification") }
    var duplicateAllCopiesBadge: String { t("已全选所有副本！", "All Copies Selected!") }
    var duplicateAllCopiesWarningTitle: String { t("即将删除所有副本", "All Copies Selected for Deletion") }
    var duplicateKeepOneAndContinue: String { t("每组保留 1 份并继续", "Keep 1 Copy & Continue") }
    var duplicateDeleteAllAnyway: String { t("仍要全部删除", "Delete All Copies Anyway") }
    var keepOnlyThisCopy: String { t("仅保留此副本", "Keep Only This Copy") }

    func duplicateGroupsCount(_ count: Int) -> String {
        isChinese ? "\(count) 组重复" : "\(count) groups"
    }

    func duplicateAllCopiesWarningBody(_ count: Int) -> String {
        isChinese
            ? "有 \(count) 组重复文件的所有副本都被勾选。若全部删除将不留任何备份。建议为每组自动保留 1 份副本后再继续。"
            : "\(count) duplicate group(s) have every copy selected. Deleting all copies leaves no backup. Keeping at least 1 copy per group is recommended."
    }

    // Memory & RAM
    var subTabMemory: String { t("内存释放", "RAM & Memory") }
    var memoryPhysicalTotal: String { t("物理内存", "Physical RAM") }
    var memoryUsedLabel: String { t("已使用", "Used") }
    var memoryAppMemory: String { t("应用内存", "App Memory") }
    var memoryActive: String { t("活跃内存", "Active") }
    var memoryWired: String { t("联动内存", "Wired") }
    var memoryCompressed: String { t("已压缩", "Compressed") }
    var memoryCachedFiles: String { t("文件缓存", "Cached Files") }
    var memoryFree: String { t("可用空闲", "Free") }
    var memorySwap: String { t("交换空间", "Swap") }
    var memoryPressureLabel: String { t("内存压力", "Pressure") }
    var memoryPressureNormal: String { t("正常", "Normal") }
    var memoryPressureWarning: String { t("中等压力", "Warning") }
    var memoryPressureCritical: String { t("高压力", "Critical") }
    var memoryAutoRefresh: String { t("自动刷新 (3s)", "Auto-Refresh (3s)") }
    var memoryStandardRelief: String { t("标准压力释放", "Standard Pressure Relief") }
    var memoryElevatedPurge: String { t("管理员深度清理缓存 (purge)", "Purge Disk Cache (Admin)") }
    var memoryElevatedConfirmTitle: String { t("执行管理员内存缓存清理？", "Run Elevated Disk Cache Purge?") }
    var memoryElevatedConfirmBody: String { t("此操作将通过系统授权执行 /usr/sbin/purge，强制清空内核磁盘缓冲区与非活跃文件缓存（不影响正在运行应用的私有内存）。", "This requests administrator authorization to run /usr/sbin/purge, flushing kernel disk buffers and inactive file caches.") }
    var memoryBeforeLabel: String { t("清理前", "Before") }
    var memoryAfterLabel: String { t("清理后", "After") }
    var memoryReclaimedLabel: String { t("空闲内存变化", "Free RAM Delta") }
    var memoryHonestDisclaimer: String { t("macOS 会自动将空闲内存用于磁盘缓存以提升性能。「标准压力释放」仅释放本应用自身堆与缓存；「管理员清理缓存」调用系统 /usr/sbin/purge，前后对比数值均来自 Mach 内核真实采样，绝不虚构释放量。", "macOS automatically uses spare RAM for disk caching. Standard Relief trims MacSweep's own caches; Elevated Purge runs /usr/sbin/purge. All figures come directly from live Mach VM kernel counters.") }
}

import Foundation
import MacSweepCore

struct L10n {
    let isChinese: Bool

    init(language: AppLanguage) {
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
    var settings: String { t("设置", "Settings") }

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

    // Permissions
    var fdaGranted: String { t("完全磁盘访问已授权", "Full Disk Access Granted") }
    var fdaMissing: String { t("未授予完全磁盘访问权限", "Full Disk Access Not Granted") }
    var fdaBannerText: String { t("授予「完全磁盘访问」后可完整扫描受保护容器与浏览器扩展", "Grant Full Disk Access to scan protected containers and browser extensions") }
    var appManagementTip: String { t("若卸载应用提示无权限，请在「系统设置 → 隐私与安全性 → 应用管理」中允许 MacSweep", "If uninstalling an app fails with permission denied, allow MacSweep in Privacy & Security → App Management") }

    // Confirmation Sheet
    var confirmUninstallTitle: String { t("确认移除所选项目", "Confirm Removal") }
    var confirmResetTitle: String { t("确认重置应用数据", "Confirm App Reset") }
    var moveToTrashOption: String { t("移至废纸篓（推荐 · 可放回原处）", "Move to Trash (Recommended · Recoverable)") }
    var permanentDeleteOption: String { t("永久删除（不可恢复）", "Delete Permanently (Irreversible)") }
    var runningAppsWarning: String { t("以下应用正在运行，操作前将先自动退出：", "The following apps are running and will be quit first:") }
    var resetForceQuitNote: String { t("重置前必须退出应用，以防系统偏好缓存（cfprefsd）回写旧配置。", "Apps must quit before resetting so macOS preference cache (cfprefsd) does not write stale data back.") }
    var adminAuthNote: String { t("包含系统/受限目录项，确认后将弹出系统授权（优先委托 Finder 保留「放回原处」）。", "Includes root/protected paths. System authorization will be requested (delegating to Finder first to preserve Put Back).") }
    var chromiumSyncNote: String { t("提示：若浏览器开启了账号云同步，移除的扩展可能会在下次同步时自动恢复。", "Note: If browser account sync is enabled, removed extensions may be restored automatically on next sync.") }

    func formatDate(_ date: Date?) -> String {
        guard let date else { return t("未知日期", "Unknown") }
        let df = DateFormatter()
        df.locale = Locale(identifier: isChinese ? "zh_CN" : "en_US")
        df.dateFormat = isChinese ? "yyyy年M月d日" : "MMM d, yyyy"
        return df.string(from: date)
    }

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
}

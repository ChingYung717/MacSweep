import MacSweepCore
import SwiftUI

struct ExtensionsView: View {
    @ObservedObject var state: AppState
    let palette: AppPalette

    @StateObject private var selectedIDBox = LocalState<String?>(nil)
    @StateObject private var filterBox = LocalState<ExtFilter>(.all)
    @StateObject private var collapsedCatsBox = LocalState<Set<ExtensionCategory>>([])

    enum ExtFilter: String, CaseIterable, Identifiable {
        case all
        case browser
        case system
        var id: String { rawValue }
    }

    private var l10n: L10n { state.l10n }

    private var filteredItems: [ExtensionItem] {
        let q = state.extensionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return state.extensionItems.filter { item in
            switch filterBox.value {
            case .all: break
            case .browser: if !item.category.isBrowser { return false }
            case .system: if item.category.isBrowser { return false }
            }
            if q.isEmpty { return true }
            return item.name.lowercased().contains(q)
                || item.identifier.lowercased().contains(q)
                || (item.profileName?.lowercased().contains(q) ?? false)
        }
    }

    private var selectedItem: ExtensionItem? {
        guard let id = selectedIDBox.value else { return nil }
        return state.extensionItems.first(where: { $0.id == id })
    }

    var body: some View {
        HStack(spacing: 0) {
            listPane
                .frame(width: 365)
                .background(palette.listBackground)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(palette.border).frame(width: 1)
                }

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.detailBackground)
        }
        .task {
            await state.loadExtensionsIfNeeded()
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text(l10n.tabExtensions)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Button {
                    Task { await state.scanExtensions() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                }
                .buttonStyle(.plain)
                .help(l10n.refresh)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // FDA degradation callout when browser directories are TCC-denied
            if state.extensionsNeedFDAForBrowsers {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(palette.warning)
                        Text(l10n.t("部分浏览器扩展需完全磁盘访问权限", "Browser extensions require Full Disk Access"))
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                    }
                    if !state.blockedBrowserNames.isEmpty {
                        Text(l10n.isChinese
                             ? "受限：\(state.blockedBrowserNames.joined(separator: "、"))"
                             : "Restricted: \(state.blockedBrowserNames.joined(separator: ", "))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.secondaryText)
                    }
                    HStack(spacing: 8) {
                        Button(l10n.openSettings) {
                            state.openSystemSettings(PermissionChecker.fullDiskAccessSettingsURL)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)

                        Button(l10n.t("已授权，重扫", "Rescan")) {
                            state.refreshPermissionStatus()
                            Task { await state.scanExtensions() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(palette.warning.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(palette.warning.opacity(0.35), lineWidth: 1))
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            // Search box
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.tertiaryText)
                TextField(l10n.searchPlaceholder, text: $state.extensionSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.primaryText)
                if !state.extensionSearchText.isEmpty {
                    Button { state.extensionSearchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.cardBackground.opacity(0.65))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Filter pills
            HStack(spacing: 6) {
                filterPill(.all, title: l10n.t("全部", "All"), count: state.extensionItems.count)
                filterPill(.browser, title: l10n.t("浏览器", "Browsers"), count: state.extensionItems.filter { $0.category.isBrowser }.count)
                filterPill(.system, title: l10n.t("系统插件", "System"), count: state.extensionItems.filter { !$0.category.isBrowser }.count)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            if state.isScanningExtensions && state.extensionItems.isEmpty {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(groupedByCategory(filteredItems), id: \.category) { group in
                            categoryHeader(category: group.category, count: group.items.count)
                            if !collapsedCatsBox.value.contains(group.category) {
                                ForEach(group.items) { item in
                                    extensionRow(item)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }

            HStack {
                Text(l10n.isChinese ? "共 \(filteredItems.count) 个扩展" : "\(filteredItems.count) extensions")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.tertiaryText)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay(alignment: .top) {
                Rectangle().fill(palette.border).frame(height: 1)
            }
        }
    }

    private func filterPill(_ filter: ExtFilter, title: String, count: Int) -> some View {
        let active = filterBox.value == filter
        return Button {
            filterBox.value = filter
        } label: {
            Text("\(title) \(count)")
                .font(.system(size: 11, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Color.white : palette.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(active ? palette.accent : palette.cardBackground.opacity(0.6)))
        }
        .buttonStyle(.plain)
    }

    private func categoryHeader(category: ExtensionCategory, count: Int) -> some View {
        let collapsed = collapsedCatsBox.value.contains(category)
        return Button {
            if collapsed { collapsedCatsBox.value.remove(category) }
            else { collapsedCatsBox.value.insert(category) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 12)
                Text(l10n.extensionCategoryTitle(category))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(palette.tertiaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.cardBackground.opacity(0.45))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    private func extensionRow(_ item: ExtensionItem) -> some View {
        let isSelected = selectedIDBox.value == item.id
        let isToggling = state.togglingExtensionIDs.contains(item.id)
        return HStack(spacing: 10) {
            if let host = item.hostAppPath, item.hostAppExists {
                AppIconView(path: host.path, size: 28)
            } else if item.pathExists && !item.category.isBrowser {
                AppIconView(path: item.path.path, size: 28)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(palette.cardHoverBackground)
                        .frame(width: 28, height: 28)
                    Image(systemName: item.category.isBrowser ? "globe" : "puzzlepiece.extension.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.accent)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if let profile = item.profileName, !profile.isEmpty {
                        Text(profile)
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.tertiaryText)
                            .lineLimit(1)
                    }
                    if !item.version.isEmpty {
                        Text("v\(item.version)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.tertiaryText)
                    }
                }
            }

            Spacer(minLength: 4)

            if item.canToggle {
                Toggle("", isOn: Binding(
                    get: { item.isEnabled },
                    set: { newVal in
                        Task { await state.toggleExtensionItem(item, enable: newVal) }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(isToggling)
            } else if item.size > 0 {
                Text(ByteFormatter.format(item.size))
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? palette.cardSelectedBackground : palette.cardBackground.opacity(0.62))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? palette.activeBorder : palette.border, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedIDBox.value = item.id
        }
    }

    // MARK: - Detail Pane

    @ViewBuilder
    private var detailPane: some View {
        if let item = selectedItem {
            let browserRunning = state.isBrowserRunning(for: item)
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        if let host = item.hostAppPath {
                            AppIconView(path: host.path, size: 46)
                        } else if !item.category.isBrowser {
                            AppIconView(path: item.path.path, size: 46)
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(palette.cardBackground)
                                    .frame(width: 46, height: 46)
                                Image(systemName: "puzzlepiece.extension.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(palette.accent)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(item.name)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(palette.primaryText)
                                if !item.version.isEmpty {
                                    Text("v\(item.version)")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(palette.secondaryText)
                                }
                            }
                            Text(item.identifier)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(palette.secondaryText)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        if item.size > 0 {
                            Text(ByteFormatter.format(item.size))
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(palette.primaryText)
                        }
                    }

                    HStack(spacing: 8) {
                        pill(l10n.extensionCategoryTitle(item.category), color: palette.accent)
                        if let profile = item.profileName {
                            pill(profile, color: palette.secondaryText)
                        }
                        if item.requiresAdmin {
                            pill(l10n.adminBadge, color: palette.warning)
                        }
                        if item.requiresReboot {
                            pill(l10n.rebootBadge, color: palette.accent)
                        }
                    }
                }
                .padding(18)
                .background(palette.cardBackground.opacity(0.45))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(palette.border).frame(height: 1)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // .appex signature protection explanation
                        if !item.canRemove && item.hostAppPath != nil {
                            noticeBox(
                                icon: "lock.shield.fill",
                                color: palette.accent,
                                text: l10n.t(
                                    "该扩展内嵌于宿主应用包内部，单独删除会破坏宿主应用的代码签名。你可以直接开关禁用它，或跳转至宿主应用完整卸载。",
                                    "This extension is embedded inside its host app bundle; deleting it alone would break the host app's code signature. You can toggle it off here or jump to the host app to uninstall it."
                                )
                            )
                        }

                        // Running browser notice (applies to Chromium AND Firefox removable extensions)
                        if item.canRemove && item.category.isBrowser && browserRunning {
                            noticeBox(
                                icon: "exclamationmark.triangle.fill",
                                color: palette.warning,
                                text: l10n.t(
                                    "对应浏览器正在运行。为避免破坏浏览器扩展配置，请先退出浏览器后再移除该扩展。",
                                    "The host browser is currently running. Quit the browser first before removing this extension to avoid profile corruption."
                                )
                            )
                        }

                        // HAL reboot notice
                        if item.requiresReboot {
                            noticeBox(
                                icon: "arrow.triangle.2.circlepath.circle.fill",
                                color: palette.accent,
                                text: l10n.t(
                                    "此项属于 macOS HAL 虚拟音频驱动，移除后通常需要重启电脑或重启 coreaudiod 服务才能完全生效。",
                                    "This is a macOS HAL audio driver. After removal, restart your Mac or coreaudiod for changes to take full effect."
                                )
                            )
                        }

                        // Path card
                        VStack(alignment: .leading, spacing: 8) {
                            Text(l10n.t("扩展路径", "Extension Path"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(palette.secondaryText)
                            HStack {
                                Text(item.path.path)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(palette.primaryText)
                                    .textSelection(.enabled)
                                Spacer()
                                Button(l10n.revealInFinder) {
                                    state.revealInFinder(item.path)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(palette.cardBackground.opacity(0.55))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
                        )

                        if let hostURL = item.hostAppPath {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(l10n.t("宿主应用程序", "Host Application"))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(palette.secondaryText)
                                HStack {
                                    AppIconView(path: hostURL.path, size: 24)
                                    Text(hostURL.path)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(palette.primaryText)
                                    Spacer()
                                    Button(l10n.t("转到应用卸载", "Inspect Host App")) {
                                        state.inspectDroppedApp(at: hostURL)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(palette.cardBackground.opacity(0.55))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
                            )
                        }
                    }
                    .padding(18)
                }

                // Bottom bar
                HStack {
                    let isBusy = state.togglingExtensionIDs.contains(item.id) || state.isPerformingRemoval
                    if item.canToggle {
                        Button(item.isEnabled ? l10n.t("禁用扩展", "Disable Extension") : l10n.t("启用扩展", "Enable Extension")) {
                            Task { await state.toggleExtensionItem(item, enable: !item.isEnabled) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                    }

                    Spacer()

                    if item.canRemove {
                        if item.category.isBrowser && browserRunning {
                            Button(l10n.t("先退出浏览器", "Quit Browser First")) {
                                Task { await state.quitBrowser(for: item) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(palette.warning)
                            .disabled(isBusy)
                        } else {
                            Button {
                                state.prepareRemovalForExtension(item)
                            } label: {
                                Text(l10n.remove)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(minWidth: 126, minHeight: 36)
                                    .background(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .fill(LinearGradient(colors: [palette.buttonTop, palette.buttonBottom], startPoint: .top, endPoint: .bottom))
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(isBusy)
                            .opacity(isBusy ? 0.55 : 1)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(palette.sidebarBackground.opacity(0.55))
                .overlay(alignment: .top) {
                    Rectangle().fill(palette.border).frame(height: 1)
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(palette.accent.opacity(0.85))
                Text(l10n.t("选择一个扩展或插件", "Select an Extension or Plugin"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Text(l10n.t("统一管理 Safari/Chrome/Edge/Brave/Arc/Firefox 浏览器扩展及 macOS 偏好面板、QuickLook、音频插件等系统组件", "Manage Safari, Chrome, Edge, Brave, Arc & Firefox extensions alongside macOS Preference Panes, QuickLook, and Audio plugins"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            .padding(28)
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    private func noticeBox(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(palette.primaryText)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.14))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 1))
        )
    }

    private func groupedByCategory(_ list: [ExtensionItem]) -> [(category: ExtensionCategory, items: [ExtensionItem])] {
        let dict = Dictionary(grouping: list, by: \.category)
        return ExtensionCategory.allCases.compactMap { cat in
            guard let items = dict[cat], !items.isEmpty else { return nil }
            return (cat, items)
        }
    }
}

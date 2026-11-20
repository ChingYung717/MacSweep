import MacSweepCore
import SwiftUI

struct StartupProgramsView: View {
    @ObservedObject var state: AppState
    let palette: AppPalette

    @StateObject private var selectedIDBox = LocalState<String?>(nil)
    @StateObject private var filterBox = LocalState<StartupFilter>(.all)
    @StateObject private var collapsedScopesBox = LocalState<Set<StartupScope>>([])

    enum StartupFilter: String, CaseIterable, Identifiable {
        case all
        case enabled
        case orphaned
        var id: String { rawValue }
    }

    private var l10n: L10n { state.l10n }

    private var filteredItems: [StartupItem] {
        let query = state.startupSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return state.startupItems.filter { item in
            switch filterBox.value {
            case .all: break
            case .enabled: if !item.isEnabled { return false }
            case .orphaned: if !item.isOrphanedBinary { return false }
            }
            if query.isEmpty { return true }
            return item.label.lowercased().contains(query)
                || (item.associatedAppName?.lowercased().contains(query) ?? false)
                || (item.programPath?.lowercased().contains(query) ?? false)
        }
    }

    private var selectedItem: StartupItem? {
        guard let id = selectedIDBox.value else { return nil }
        return state.startupItems.first(where: { $0.id == id })
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
            await state.loadStartupIfNeeded()
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text(l10n.tabStartup)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Button {
                    Task { await state.scanStartupItems() }
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

            // Search box
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.tertiaryText)
                TextField(l10n.searchPlaceholder, text: $state.startupSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.primaryText)
                if !state.startupSearchText.isEmpty {
                    Button { state.startupSearchText = "" } label: {
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

            // Filter Pills
            HStack(spacing: 6) {
                filterPill(.all, title: l10n.t("全部", "All"), count: state.startupItems.count)
                filterPill(.enabled, title: l10n.t("已启用", "Enabled"), count: state.startupItems.filter(\.isEnabled).count)
                filterPill(.orphaned, title: l10n.t("目标缺失", "Broken"), count: state.startupItems.filter(\.isOrphanedBinary).count)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            if state.isScanningStartup && state.startupItems.isEmpty {
                VStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(groupedByScope(filteredItems), id: \.scope) { group in
                            scopeHeader(scope: group.scope, count: group.items.count)
                            if !collapsedScopesBox.value.contains(group.scope) {
                                ForEach(group.items) { item in
                                    startupRow(item)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }

            // Footer
            HStack {
                Text(l10n.isChinese ? "共 \(filteredItems.count) 个启动项" : "\(filteredItems.count) startup items")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.tertiaryText)
                Spacer()
                Button(l10n.t("系统登录项", "Login Items")) {
                    state.openSystemSettings(PermissionChecker.loginItemsSettingsURL)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(palette.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay(alignment: .top) {
                Rectangle().fill(palette.border).frame(height: 1)
            }
        }
    }

    private func filterPill(_ filter: StartupFilter, title: String, count: Int) -> some View {
        let active = filterBox.value == filter
        return Button {
            filterBox.value = filter
        } label: {
            Text("\(title) \(count)")
                .font(.system(size: 11, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Color.white : palette.secondaryText)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(active ? palette.accent : palette.cardBackground.opacity(0.6))
                )
        }
        .buttonStyle(.plain)
    }

    private func scopeHeader(scope: StartupScope, count: Int) -> some View {
        let collapsed = collapsedScopesBox.value.contains(scope)
        return Button {
            if collapsed { collapsedScopesBox.value.remove(scope) }
            else { collapsedScopesBox.value.insert(scope) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 12)
                Text(l10n.startupScopeTitle(scope))
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

    private func startupRow(_ item: StartupItem) -> some View {
        let isSelected = selectedIDBox.value == item.id
        return HStack(spacing: 10) {
            if let appPath = item.associatedAppPath, FileManager.default.fileExists(atPath: appPath) {
                AppIconView(path: appPath, size: 30)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(palette.cardHoverBackground)
                        .frame(width: 30, height: 30)
                    Image(systemName: item.scope == .systemDaemon ? "gearshape.2.fill" : "paperplane.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(item.isOrphanedBinary ? palette.warning : palette.accent)
                }
            }

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 5) {
                    Text(item.associatedAppName ?? item.label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)

                    if item.isOrphanedBinary {
                        Text(l10n.t("目标缺失", "Missing"))
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(palette.danger)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(palette.danger.opacity(0.18)))
                    }
                }

                Text(item.label)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            if item.canToggle {
                Toggle("", isOn: Binding(
                    get: { item.isEnabled },
                    set: { newValue in
                        Task { await state.toggleStartupItem(item, enable: newValue) }
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            } else {
                Text(l10n.t("系统管理", "System"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.tertiaryText)
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

    // MARK: - Right Detail Pane

    @ViewBuilder
    private var detailPane: some View {
        if let item = selectedItem {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        if let appPath = item.associatedAppPath, FileManager.default.fileExists(atPath: appPath) {
                            AppIconView(path: appPath, size: 46)
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(palette.cardBackground)
                                    .frame(width: 46, height: 46)
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(palette.accent)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.associatedAppName ?? item.label)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(palette.primaryText)
                            Text(item.label)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(palette.secondaryText)
                                .textSelection(.enabled)
                        }
                        Spacer()
                    }

                    HStack(spacing: 8) {
                        badge(l10n.startupScopeTitle(item.scope), color: palette.accent)
                        badge(
                            item.isEnabled ? l10n.t("已启用", "Enabled") : l10n.t("已禁用", "Disabled"),
                            color: item.isEnabled ? palette.success : palette.tertiaryText
                        )
                        if item.runAtLoad {
                            badge("RunAtLoad", color: palette.secondaryText)
                        }
                        if item.keepAlive {
                            badge("KeepAlive", color: palette.warning)
                        }
                        if item.requiresAdmin {
                            badge(l10n.adminBadge, color: palette.warning)
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
                        if item.isOrphanedBinary {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(palette.danger)
                                Text(l10n.t("此启动项指向的可执行程序已不存在，通常是已卸载应用遗留的僵尸启动配置，建议移除。", "The executable referenced by this item no longer exists. It is likely a leftover from an uninstalled app and safe to remove."))
                                    .font(.system(size: 12))
                                    .foregroundStyle(palette.primaryText)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10).fill(palette.danger.opacity(0.15))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.danger.opacity(0.35), lineWidth: 1))
                            )
                        }

                        infoCard(title: l10n.t("配置文件位置", "Configuration File")) {
                            HStack {
                                Text(item.plistURL.path)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(palette.primaryText)
                                    .textSelection(.enabled)
                                Spacer()
                                Button(l10n.revealInFinder) {
                                    state.revealInFinder(item.plistURL)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        if let prog = item.programPath {
                            infoCard(title: l10n.t("执行程序路径", "Executable Path")) {
                                HStack(spacing: 6) {
                                    Image(systemName: item.isOrphanedBinary ? "xmark.circle.fill" : "checkmark.circle.fill")
                                        .foregroundStyle(item.isOrphanedBinary ? palette.danger : palette.success)
                                    Text(prog)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(palette.primaryText)
                                        .textSelection(.enabled)
                                }
                                if item.programArguments.count > 1 {
                                    Text(item.programArguments.joined(separator: " "))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(palette.tertiaryText)
                                        .textSelection(.enabled)
                                }
                            }
                        }

                        if item.plistURL.pathExtension.lowercased() == "plist",
                           let preview = loadPlistText(item.plistURL) {
                            infoCard(title: "Plist XML") {
                                ScrollView(.horizontal) {
                                    Text(preview)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(palette.secondaryText)
                                        .textSelection(.enabled)
                                }
                                .frame(maxHeight: 220)
                            }
                        }
                    }
                    .padding(18)
                }

                // Bottom Action Bar
                HStack {
                    if item.scope == .appLoginItem {
                        Text(l10n.t("macOS 要求应用内嵌登录项在「系统设置 → 通用 → 登录项」中管理。", "macOS manages embedded app login items in System Settings → Login Items."))
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondaryText)
                        Spacer()
                        Button(l10n.openSettings) {
                            state.openSystemSettings(PermissionChecker.loginItemsSettingsURL)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(item.isEnabled ? l10n.t("禁用此启动项", "Disable Item") : l10n.t("启用此启动项", "Enable Item")) {
                            Task { await state.toggleStartupItem(item, enable: !item.isEnabled) }
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button {
                            state.prepareRemovalForStartupItem(item)
                        } label: {
                            Text(l10n.t("移除配置文件", "Remove Plist"))
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(LinearGradient(colors: [palette.buttonTop, palette.buttonBottom], startPoint: .top, endPoint: .bottom))
                                )
                        }
                        .buttonStyle(.plain)
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
                Image(systemName: "paperplane.circle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(palette.accent.opacity(0.85))
                Text(l10n.t("选择一个启动项查看详情", "Select a Startup Item"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Text(l10n.t("支持一键禁用/启用 LaunchAgents 与 LaunchDaemons，并可排查目标已缺失的僵尸启动项", "Enable/disable LaunchAgents & LaunchDaemons and clean up orphaned launch plists"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .padding(28)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    private func infoCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.secondaryText)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.cardBackground.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
        )
    }

    private func groupedByScope(_ list: [StartupItem]) -> [(scope: StartupScope, items: [StartupItem])] {
        let dict = Dictionary(grouping: list, by: \.scope)
        return StartupScope.allCases.compactMap { scope in
            guard let items = dict[scope], !items.isEmpty else { return nil }
            return (scope, items)
        }
    }

    private func loadPlistText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let str = String(data: data, encoding: .utf8), str.contains("<?xml") {
            return String(str.prefix(6000))
        }
        // Convert binary plist to XML for readable preview
        if let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0),
           let str = String(data: xml, encoding: .utf8) {
            return String(str.prefix(6000))
        }
        return nil
    }
}

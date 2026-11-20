import MacSweepCore
import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var state: AppState
    let palette: AppPalette
    @Environment(\.dismiss) private var dismiss

    @StateObject private var selectedTabBox = LocalState(SettingsTab.general)

    enum SettingsTab: String, CaseIterable, Identifiable {
        case general
        case permissions
        case protection
        case history
        var id: String { rawValue }
    }

    private var l10n: L10n { state.l10n }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(l10n.settings)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Button(l10n.close) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) {
                Rectangle().fill(palette.border).frame(height: 1)
            }

            // Tab Strip
            Picker("", selection: $selectedTabBox.value) {
                Text(l10n.t("通用与外观", "General")).tag(SettingsTab.general)
                Text(l10n.t("系统权限", "Permissions")).tag(SettingsTab.permissions)
                Text(l10n.t("保护名单", "Skip List")).tag(SettingsTab.protection)
                Text(l10n.t("清理历史", "History")).tag(SettingsTab.history)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch selectedTabBox.value {
                    case .general:
                        generalSection
                    case .permissions:
                        permissionsSection
                    case .protection:
                        protectionSection
                    case .history:
                        historySection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 560, height: 470)
        .background(palette.detailBackground)
        .preferredColorScheme(palette.isDeepOcean ? .dark : nil)
        .onAppear {
            state.refreshPermissionStatus()
        }
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingCard(title: l10n.t("视觉主题", "Appearance")) {
                Picker(l10n.t("主题风格", "Theme"), selection: Binding(
                    get: { state.preferences.themeMode },
                    set: { state.preferences.themeMode = $0; state.savePreferences() }
                )) {
                    Text(l10n.t("深海蓝暗色（默认）", "Deep Ocean Dark (Default)")).tag(ThemeMode.deepOcean)
                    Text(l10n.t("跟随系统浅色/深色", "Follow System Light/Dark")).tag(ThemeMode.system)
                }
                .pickerStyle(.radioGroup)
            }

            settingCard(title: l10n.t("界面语言", "Language")) {
                Picker(l10n.t("语言", "Language"), selection: Binding(
                    get: { state.preferences.language },
                    set: { state.preferences.language = $0; state.savePreferences() }
                )) {
                    Text(l10n.t("跟随系统", "System Default")).tag(AppLanguage.system)
                    Text("简体中文").tag(AppLanguage.zhHans)
                    Text("English").tag(AppLanguage.en)
                }
                .pickerStyle(.segmented)
            }

            settingCard(title: l10n.t("默认删除方式", "Default Removal Mode")) {
                Picker("", selection: Binding(
                    get: { state.preferences.defaultRemovalMode },
                    set: { state.preferences.defaultRemovalMode = $0; state.savePreferences() }
                )) {
                    Text(l10n.moveToTrashOption).tag(RemovalMode.trash)
                    Text(l10n.permanentDeleteOption).tag(RemovalMode.permanent)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            settingCard(title: l10n.t("扫描范围", "Scan Scope")) {
                Toggle(l10n.t("包含 /Applications/Utilities 实用工具目录", "Include /Applications/Utilities"), isOn: Binding(
                    get: { state.preferences.includeUtilitiesFolder },
                    set: {
                        state.preferences.includeUtilitiesFolder = $0
                        state.savePreferences()
                        Task { await state.scanApplications() }
                    }
                ))
                Toggle(l10n.t("在列表中显示受 SIP 保护的内置系统应用（只读）", "Show SIP-protected system apps (read-only)"), isOn: Binding(
                    get: { state.preferences.showSystemApps },
                    set: {
                        state.preferences.showSystemApps = $0
                        state.savePreferences()
                        Task { await state.scanApplications() }
                    }
                ))
            }
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingCard(title: l10n.t("完全磁盘访问权限 (Full Disk Access)", "Full Disk Access")) {
                HStack(spacing: 10) {
                    Image(systemName: state.hasFullDiskAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(state.hasFullDiskAccess ? palette.success : palette.warning)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(state.hasFullDiskAccess ? l10n.fdaGranted : l10n.fdaMissing)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(palette.primaryText)
                        Text(l10n.fdaBannerText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.secondaryText)
                    }
                    Spacer()
                }

                HStack {
                    Button(l10n.openSettings) {
                        state.openSystemSettings(PermissionChecker.fullDiskAccessSettingsURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(l10n.t("重新检测", "Re-check")) {
                        state.refreshPermissionStatus()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            settingCard(title: l10n.t("应用管理权限 (App Management)", "App Management")) {
                Text(l10n.appManagementTip)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondaryText)
                Button(l10n.t("打开「应用管理」设置", "Open App Management Settings")) {
                    state.openSystemSettings(PermissionChecker.appManagementSettingsURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            settingCard(title: l10n.t("自动化 → Finder 权限", "Automation → Finder")) {
                Text(l10n.t(
                    "移除 root 权限项到废纸篓时，MacSweep 会优先委托 Finder 处理以保留「放回原处」功能。若曾拒绝授权，可在此重新开启。",
                    "When moving root-owned items to Trash, MacSweep delegates to Finder to preserve Put Back. You can re-enable Automation permission here."
                ))
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryText)
                Button(l10n.t("打开「自动化」设置", "Open Automation Settings")) {
                    state.openSystemSettings(PermissionChecker.automationSettingsURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Protection / Skip List

    private var protectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingCard(title: l10n.t("受保护的应用 Bundle ID", "Protected App Bundle IDs")) {
                if state.preferences.protectedBundleIDs.isEmpty {
                    Text(l10n.t("暂无受保护应用。可在应用详情页点击「保护此应用」添加。", "No protected apps. Click 'Protect' on any app detail header to add."))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.tertiaryText)
                } else {
                    ForEach(state.preferences.protectedBundleIDs, id: \.self) { bid in
                        HStack {
                            Text(bid)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(palette.primaryText)
                            Spacer()
                            Button {
                                state.preferences.protectedBundleIDs.removeAll { $0 == bid }
                                state.savePreferences()
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(palette.danger)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            settingCard(title: l10n.t("已忽略的残留项目", "Ignored Leftover Entries")) {
                if state.preferences.ignoredLeftoverIDs.isEmpty {
                    Text(l10n.t("暂无已忽略残留项。", "No ignored leftovers."))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.tertiaryText)
                } else {
                    ForEach(state.preferences.ignoredLeftoverIDs, id: \.self) { lid in
                        HStack {
                            Text(lid)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(palette.primaryText)
                            Spacer()
                            Button {
                                state.preferences.ignoredLeftoverIDs.removeAll { $0 == lid }
                                state.savePreferences()
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(palette.danger)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: - Cleanup History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(l10n.t("最近清理记录", "Recent Cleanup History"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                if !state.cleanupHistory.isEmpty {
                    Button(l10n.t("清空历史", "Clear History")) {
                        state.clearHistory()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if state.cleanupHistory.isEmpty {
                Text(l10n.t("暂无清理记录。", "No cleanup history yet."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
            } else {
                ForEach(state.cleanupHistory) { rec in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(rec.actionTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(palette.primaryText)
                            Spacer()
                            Text(ByteFormatter.format(rec.freedBytes))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(palette.success)
                        }
                        HStack {
                            Text(l10n.formatDate(rec.date))
                            Text("·")
                            Text(l10n.isChinese ? "\(rec.itemCount) 项" : "\(rec.itemCount) items")
                            Text("·")
                            Text(rec.mode == .trash ? l10n.t("移至废纸篓", "Moved to Trash") : l10n.t("永久删除", "Deleted Permanently"))
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiaryText)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(palette.cardBackground.opacity(0.65))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(palette.border, lineWidth: 1)
                            )
                    )
                }
            }
        }
    }

    private func settingCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.primaryText)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.cardBackground.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.border, lineWidth: 1)
                )
        )
    }
}

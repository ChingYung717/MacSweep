import MacSweepCore
import SwiftUI

struct LeftoversView: View {
    @ObservedObject var state: AppState
    let palette: AppPalette

    @StateObject private var filterBox = LocalState<LeftoverFilter>(.all)

    enum LeftoverFilter: String, CaseIterable, Identifiable {
        case all
        case high
        case medium
        var id: String { rawValue }
    }

    private var l10n: L10n { state.l10n }

    private var filteredGroups: [LeftoverGroup] {
        let q = state.leftoverSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return state.leftoverGroups.filter { group in
            switch filterBox.value {
            case .all: break
            case .high: if group.confidence != .high { return false }
            case .medium: if group.confidence != .medium { return false }
            }
            if q.isEmpty { return true }
            return group.groupName.lowercased().contains(q)
                || (group.suspectedBundleID?.lowercased().contains(q) ?? false)
                || group.files.contains(where: { $0.displayName.lowercased().contains(q) })
        }
    }

    private var selectedGroup: LeftoverGroup? {
        guard let id = state.selectedLeftoverGroupID else { return nil }
        return state.leftoverGroups.first(where: { $0.id == id })
    }

    private var totalSelectedFiles: [ServiceFile] {
        state.leftoverGroups
            .filter(\.isChecked)
            .flatMap { $0.files.filter(\.isSelected) }
    }

    private var totalSelectedBytes: Int64 {
        totalSelectedFiles.reduce(0) { $0 + ($1.size ?? 0) }
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
            await state.loadLeftoversIfNeeded()
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text(l10n.tabLeftovers)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Button {
                    Task { await state.scanLeftovers() }
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
                TextField(l10n.searchPlaceholder, text: $state.leftoverSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.primaryText)
                if !state.leftoverSearchText.isEmpty {
                    Button { state.leftoverSearchText = "" } label: {
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

            // Confidence filter pills
            HStack(spacing: 6) {
                filterPill(.all, title: l10n.t("全部", "All"), count: state.leftoverGroups.count)
                filterPill(.high, title: l10n.t("高置信度", "High"), count: state.leftoverGroups.filter { $0.confidence == .high }.count)
                filterPill(.medium, title: l10n.t("建议核对", "Review"), count: state.leftoverGroups.filter { $0.confidence == .medium }.count)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            if state.isScanningLeftovers && state.leftoverGroups.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                    Text(l10n.t("正在比对全机应用指纹并查找残留...", "Comparing against installed apps to find leftovers..."))
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                }
                .padding()
            } else if filteredGroups.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.system(size: 32))
                        .foregroundStyle(palette.success)
                    Text(l10n.t("非常干净，未发现残留文件", "All clean — no leftover files found"))
                        .font(.system(size: 13))
                        .foregroundStyle(palette.secondaryText)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(filteredGroups) { group in
                            leftoverGroupRow(group)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }

            // Footer
            HStack {
                Text(l10n.isChinese
                     ? "共 \(filteredGroups.count) 组残留"
                     : "\(filteredGroups.count) leftover groups")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.tertiaryText)
                Spacer()
                Button(l10n.t("仅选高置信度", "High Only")) {
                    state.selectHighConfidenceLeftoversOnly()
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

    private func filterPill(_ filter: LeftoverFilter, title: String, count: Int) -> some View {
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

    private func leftoverGroupRow(_ group: LeftoverGroup) -> some View {
        let isSelected = state.selectedLeftoverGroupID == group.id
        let isSystemOnly = !group.hasUserScopeFiles
        return HStack(spacing: 10) {
            SweepCheckbox(
                isChecked: group.isChecked,
                isDisabled: isSystemOnly && !group.isChecked,
                palette: palette
            ) {
                state.toggleLeftoverGroupChecked(group.id)
            }
            .help(isSystemOnly
                  ? l10n.t("仅含 /Library 系统级文件，请点击分组后在右侧逐项手动勾选", "System-scope (/Library) items only — open this group to opt in per file")
                  : "")

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((group.confidence == .high ? palette.accent : palette.warning).opacity(0.18))
                    .frame(width: 30, height: 30)
                Image(systemName: group.confidence == .high ? "doc.badge.clock" : "questionmark.folder.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(group.confidence == .high ? palette.accent : palette.warning)
            }

            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 5) {
                    Text(group.groupName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)

                    confidenceBadge(group.confidence)

                    if group.hasSystemScopeFiles {
                        Text(l10n.t("含系统级", "System"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(palette.warning)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(palette.warning.opacity(0.16)))
                    }
                }

                Text(l10n.isChinese
                     ? "\(group.files.count) 个文件 · \(group.suspectedBundleID ?? group.id)"
                     : "\(group.files.count) files · \(group.suspectedBundleID ?? group.id)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Text(ByteFormatter.format(group.totalSize))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(palette.secondaryText)
                .monospacedDigit()
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
            state.selectedLeftoverGroupID = group.id
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        VStack(spacing: 0) {
            if let group = selectedGroup {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(group.groupName)
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(palette.primaryText)
                                confidenceBadge(group.confidence)
                            }
                            if let bid = group.suspectedBundleID {
                                Text(bid)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(palette.secondaryText)
                            }
                        }
                        Spacer()
                        Button {
                            state.ignoreLeftoverGroup(group)
                            if state.selectedLeftoverGroupID == group.id {
                                state.selectedLeftoverGroupID = nil
                            }
                        } label: {
                            Label(l10n.t("永久忽略", "Ignore Forever"), systemImage: "eye.slash")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if group.hasSystemScopeFiles {
                        HStack(spacing: 6) {
                            Image(systemName: "shield.lefthalf.filled")
                                .foregroundStyle(palette.warning)
                            Text(l10n.isChinese
                                 ? "包含 \(group.systemScopeFileCount) 项 /Library 系统级文件，受安全策略保护不会随分组或「仅选高置信度」自动勾选；如需清理请在下方逐项手动勾选。"
                                 : "Contains \(group.systemScopeFileCount) system-scope (/Library) item(s). They are never auto-checked by group or High Only selection; opt in per file below if needed.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(palette.secondaryText)
                        }
                    }

                    if group.confidence == .medium {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(palette.warning)
                            Text(l10n.t("此目录无标准反向域名标识，可能属于命令行工具或自定义数据，默认未勾选，请核对后再清理。", "This directory has no reverse-DNS bundle ID and may belong to a CLI tool or custom data. Unchecked by default — please verify before removing."))
                                .font(.system(size: 11.5))
                                .foregroundStyle(palette.secondaryText)
                        }
                    }
                }
                .padding(18)
                .background(palette.cardBackground.opacity(0.45))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(palette.border).frame(height: 1)
                }

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(group.files) { file in
                            FileRowView(
                                file: file,
                                palette: palette,
                                l10n: l10n,
                                onToggle: {
                                    state.toggleLeftoverFile(groupID: group.id, fileID: file.id)
                                },
                                onReveal: {
                                    state.revealInFinder(file.url)
                                }
                            )
                        }
                    }
                    .padding(16)
                }
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 46))
                        .foregroundStyle(palette.accent.opacity(0.85))
                    Text(l10n.t("残留文件扫描", "Remaining Leftover Files"))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    Text(l10n.t("已自动排除所有 Apple 系统组件与常见开发工具目录。点击左侧任意分组核对路径，或直接清理勾选的高置信度残留。", "Apple system files and developer toolchains are automatically protected. Inspect any group on the left or clean checked high-confidence leftovers."))
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                    Spacer()
                }
                .padding(28)
            }

            // Sticky Bottom Bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.selectedSummary(count: totalSelectedFiles.count, bytes: totalSelectedBytes))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    Text(l10n.t("清理所选残留文件（移至废纸篓可随时恢复）", "Clean selected leftover files (recoverable in Trash)"))
                        .font(.system(size: 11))
                        .foregroundStyle(palette.tertiaryText)
                }
                Spacer()
                Button {
                    state.prepareRemovalForCheckedLeftovers()
                } label: {
                    Text(l10n.t("清理残留", "Clean Leftovers"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 136, minHeight: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: totalSelectedFiles.isEmpty
                                            ? [palette.cardBackground, palette.cardBackground]
                                            : [palette.buttonTop, palette.buttonBottom],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(totalSelectedFiles.isEmpty || state.isPerformingRemoval)
                .opacity(totalSelectedFiles.isEmpty ? 0.55 : 1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(palette.sidebarBackground.opacity(0.55))
            .overlay(alignment: .top) {
                Rectangle().fill(palette.border).frame(height: 1)
            }
        }
    }

    private func confidenceBadge(_ confidence: LeftoverConfidence) -> some View {
        let isHigh = confidence == .high
        let color = isHigh ? palette.success : palette.warning
        return Text(isHigh ? l10n.t("高置信度", "High") : l10n.t("建议核对", "Review"))
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.16)))
    }
}

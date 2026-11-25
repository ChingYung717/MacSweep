import SwiftUI

struct SidebarRail: View {
    @ObservedObject var state: AppState
    @ObservedObject var cleanupStore: CleanupCenterStore
    let palette: AppPalette

    var body: some View {
        VStack(spacing: 5) {
            // Room for macOS traffic-light window buttons
            Spacer().frame(height: 34)

            ForEach(MainTab.allCases) { tab in
                SidebarTabButton(
                    tab: tab,
                    title: tabTitle(tab),
                    helpTitle: fullTabTitle(tab),
                    badgeCount: badgeCount(for: tab),
                    isSelected: state.activeTab == tab,
                    palette: palette
                ) {
                    state.activeTab = tab
                }
            }

            Spacer(minLength: 8)

            // Permission indicator pill
            Button {
                state.refreshPermissionStatus()
                state.showSettingsSheet = true
            } label: {
                VStack(spacing: 3) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: state.hasFullDiskAccess ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(state.hasFullDiskAccess ? palette.success : palette.warning)
                        Circle()
                            .fill(state.hasFullDiskAccess ? palette.success : palette.warning)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -2)
                    }
                    Text(state.l10n.t("权限", "Access"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                }
                .frame(width: 62, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(palette.cardBackground.opacity(0.45))
                )
            }
            .buttonStyle(.plain)
            .help(state.hasFullDiskAccess ? state.l10n.fdaGranted : state.l10n.fdaMissing)

            // Settings button
            Button {
                state.showSettingsSheet = true
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                    Text(state.l10n.settings)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                }
                .frame(width: 62, height: 38)
            }
            .buttonStyle(.plain)

            // Subtle Brand mark
            Text("MacSweep")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.tertiaryText)
                .padding(.bottom, 10)
        }
        .frame(width: 82)
        .background(palette.sidebarBackground)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(palette.border)
                .frame(width: 1)
        }
    }

    private func tabTitle(_ tab: MainTab) -> String {
        switch tab {
        case .applications: return state.l10n.tabApplications
        case .startup: return state.l10n.tabStartup
        case .extensions: return state.l10n.tabExtensions
        case .leftovers: return state.l10n.tabLeftovers
        case .fileManager: return state.l10n.tabFileManager
        case .junkCleaner: return state.l10n.tabJunkCleaner
        case .resourceRelease: return state.l10n.tabResourceRelease
        }
    }

    private func fullTabTitle(_ tab: MainTab) -> String {
        switch tab {
        case .resourceRelease: return state.l10n.resourceReleaseTitle
        default: return tabTitle(tab)
        }
    }

    private func badgeCount(for tab: MainTab) -> Int? {
        switch tab {
        case .applications:
            let checked = state.checkedApps.count
            return checked > 0 ? checked : nil
        case .leftovers:
            return state.leftoverGroups.isEmpty ? nil : state.leftoverGroups.count
        case .junkCleaner:
            let selected = cleanupStore.selectedJunkCount
            return selected > 0 ? selected : nil
        default:
            return nil
        }
    }
}

private struct SidebarTabButton: View {
    let tab: MainTab
    let title: String
    let helpTitle: String
    let badgeCount: Int?
    let isSelected: Bool
    let palette: AppPalette
    let action: () -> Void

    @StateObject private var hoverState = LocalState(false)

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 3) {
                    Image(systemName: tab.symbolName)
                        .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? palette.sidebarActiveForeground : palette.secondaryText)
                        .shadow(color: (isSelected && palette.isDark) ? palette.accentGlow : .clear, radius: 6)

                    Text(title)
                        .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? palette.sidebarActiveForeground : palette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                        .padding(.horizontal, 3)
                }
                .frame(width: 68, height: 48)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [palette.sidebarActiveTop, palette.sidebarActiveBottom],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(palette.activeBorder, lineWidth: 1)
                            )
                            .shadow(color: palette.isDark ? palette.accentGlow : Color.black.opacity(0.06), radius: palette.isDark ? 10 : 4, x: 0, y: 2)
                    } else if hoverState.value {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(palette.cardBackground.opacity(0.65))
                    }
                }

                if let count = badgeCount {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(palette.accent))
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .help(helpTitle)
        .onHover { hovering in
            hoverState.value = hovering
        }
    }
}

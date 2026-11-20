import SwiftUI

struct SidebarRail: View {
    @ObservedObject var state: AppState
    let palette: AppPalette

    var body: some View {
        VStack(spacing: 10) {
            // Room for macOS traffic-light window buttons
            Spacer().frame(height: 36)

            ForEach(MainTab.allCases) { tab in
                SidebarTabButton(
                    tab: tab,
                    title: tabTitle(tab),
                    badgeCount: badgeCount(for: tab),
                    isSelected: state.activeTab == tab,
                    palette: palette
                ) {
                    state.activeTab = tab
                }
            }

            Spacer()

            // Permission indicator pill
            Button {
                state.refreshPermissionStatus()
                state.showSettingsSheet = true
            } label: {
                VStack(spacing: 4) {
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
                .frame(width: 62, height: 42)
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
                .frame(width: 62, height: 40)
            }
            .buttonStyle(.plain)

            // Subtle Brand mark
            Text("MacSweep")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.tertiaryText)
                .padding(.bottom, 12)
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
        }
    }

    private func badgeCount(for tab: MainTab) -> Int? {
        switch tab {
        case .applications:
            let checked = state.checkedApps.count
            return checked > 0 ? checked : nil
        case .leftovers:
            return state.leftoverGroups.isEmpty ? nil : state.leftoverGroups.count
        default:
            return nil
        }
    }
}

private struct SidebarTabButton: View {
    let tab: MainTab
    let title: String
    let badgeCount: Int?
    let isSelected: Bool
    let palette: AppPalette
    let action: () -> Void

    @StateObject private var hoverState = LocalState(false)

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 5) {
                    Image(systemName: tab.symbolName)
                        .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : palette.secondaryText)
                        .shadow(color: isSelected ? palette.accentGlow : .clear, radius: 6)

                    Text(title)
                        .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.white : palette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(width: 66, height: 58)
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
                            .shadow(color: palette.accentGlow, radius: 10, x: 0, y: 2)
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
        .onHover { hovering in
            hoverState.value = hovering
        }
    }
}

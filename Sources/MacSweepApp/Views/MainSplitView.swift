import MacSweepCore
import SwiftUI

struct MainSplitView: View {
    @ObservedObject var state: AppState
    @Environment(\.colorScheme) private var systemScheme

    private var palette: AppPalette {
        AppPalette.resolve(mode: state.preferences.themeMode, systemScheme: systemScheme)
    }

    var body: some View {
        ZStack(alignment: .top) {
            HStack(spacing: 0) {
                SidebarRail(state: state, palette: palette)

                Group {
                    switch state.activeTab {
                    case .applications:
                        ApplicationsView(state: state, palette: palette)
                    case .startup:
                        StartupProgramsView(state: state, palette: palette)
                    case .extensions:
                        ExtensionsView(state: state, palette: palette)
                    case .leftovers:
                        LeftoversView(state: state, palette: palette)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(palette.windowBackground)

            // Floating operation feedback banner
            if let banner = state.banner {
                HStack(spacing: 10) {
                    Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(banner.isError ? palette.danger : palette.success)
                    Text(banner.message)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(2)

                    if banner.showAppManagementLink {
                        Button(state.l10n.t("打开应用管理", "App Management")) {
                            state.openSystemSettings(PermissionChecker.appManagementSettingsURL)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }

                    if banner.showFDALink {
                        Button(state.l10n.openSettings) {
                            state.openSystemSettings(PermissionChecker.fullDiskAccessSettingsURL)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }

                    Button {
                        state.banner = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(palette.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(banner.isError ? palette.danger.opacity(0.6) : palette.success.opacity(0.6), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.35), radius: 12, y: 4)
                )
                .padding(.top, 14)
                .padding(.horizontal, 110)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .preferredColorScheme(state.preferences.themeMode == .deepOcean ? .dark : nil)
        .task {
            await state.loadInitialDataIfNeeded()
        }
        .sheet(isPresented: $state.showSettingsSheet) {
            SettingsSheet(state: state, palette: palette)
        }
        .sheet(item: $state.pendingConfirmation) { conf in
            ConfirmationSheet(
                confirmation: conf,
                defaultMode: state.preferences.defaultRemovalMode,
                palette: palette,
                l10n: state.l10n,
                onCancel: {
                    state.pendingConfirmation = nil
                },
                onConfirm: { mode in
                    Task {
                        await state.executePendingConfirmation(mode: mode)
                    }
                }
            )
        }
    }
}

import MacSweepCore
import SwiftUI

struct ConfirmationSheet: View {
    let confirmation: PendingConfirmation
    let defaultMode: RemovalMode
    let palette: AppPalette
    let l10n: L10n
    let onCancel: () -> Void
    let onConfirm: (RemovalMode) -> Void

    @StateObject private var selectedModeBox: LocalState<RemovalMode>

    init(
        confirmation: PendingConfirmation,
        defaultMode: RemovalMode,
        palette: AppPalette,
        l10n: L10n,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (RemovalMode) -> Void
    ) {
        self.confirmation = confirmation
        self.defaultMode = defaultMode
        self.palette = palette
        self.l10n = l10n
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        self._selectedModeBox = StateObject(wrappedValue: LocalState(defaultMode))
    }

    private var selectedMode: RemovalMode { selectedModeBox.value }

    private var totalBytes: Int64 {
        confirmation.targets.reduce(0) { $0 + $1.estimatedSize }
    }

    private var effectivePackageIDs: [String] {
        selectedMode == .permanent ? confirmation.packageIDsToForget : []
    }

    private var hasAdminItems: Bool {
        confirmation.targets.contains(where: \.requiresAdmin) || !effectivePackageIDs.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill((selectedMode == .permanent ? palette.danger : palette.accent).opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: selectedMode == .permanent ? "trash.slash.fill" : "trash.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(selectedMode == .permanent ? palette.danger : palette.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(confirmation.isReset ? l10n.confirmResetTitle : l10n.confirmUninstallTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                    Text(verbatim: "\(SafeFileReader.sanitizeForDisplay(confirmation.title)) · \(l10n.selectedSummary(count: confirmation.targets.count, bytes: totalBytes))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryText)
                }
                Spacer()
            }

            // Contextual Warnings
            if !confirmation.runningAppNames.isEmpty {
                let safeRunningNames = confirmation.runningAppNames
                    .map(SafeFileReader.sanitizeForDisplay)
                    .joined(separator: ", ")
                warningBox(
                    icon: "bolt.circle.fill",
                    color: palette.warning,
                    text: "\(l10n.runningAppsWarning) \(safeRunningNames)"
                        + (confirmation.isReset ? "\n\(l10n.resetForceQuitNote)" : "")
                )
            }

            if confirmation.hasAppleAppStoreApp {
                warningBox(
                    icon: "exclamationmark.triangle.fill",
                    color: palette.warning,
                    text: l10n.appleStoreWarning
                )
            }

            if hasAdminItems {
                warningBox(
                    icon: "lock.shield.fill",
                    color: palette.accent,
                    text: l10n.adminAuthNote
                )
            }

            if confirmation.hasUserLockedItems {
                warningBox(
                    icon: "lock.open.fill",
                    color: palette.warning,
                    text: l10n.userLockedItemsNote
                )
            }

            if confirmation.hasChromiumExtension {
                warningBox(
                    icon: "arrow.triangle.2.circlepath",
                    color: palette.warning,
                    text: l10n.chromiumSyncNote
                )
            }

            // Removal Mode Picker
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $selectedModeBox.value) {
                    Text(l10n.moveToTrashOption).tag(RemovalMode.trash)
                    Text(l10n.permanentDeleteOption).tag(RemovalMode.permanent)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(palette.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selectedMode == .permanent ? palette.danger.opacity(0.6) : palette.border, lineWidth: 1)
                    )
            )

            // Itemized exact path list
            VStack(alignment: .leading, spacing: 6) {
                Text(l10n.t("将处理以下精确路径：", "Exact paths to be removed:"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(confirmation.targets, id: \.url.path) { target in
                            HStack(spacing: 8) {
                                Image(systemName: target.requiresAdmin ? "lock.fill" : "doc")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(target.requiresAdmin ? palette.warning : palette.tertiaryText)
                                    .frame(width: 14)

                                Text(verbatim: SafeFileReader.sanitizeForDisplay(target.url.path))
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(palette.primaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer()

                                if target.estimatedSize > 0 {
                                    Text(ByteFormatter.format(target.estimatedSize))
                                        .font(.system(size: 11, design: .rounded))
                                        .foregroundStyle(palette.secondaryText)
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        if !effectivePackageIDs.isEmpty {
                            Divider().opacity(0.3).padding(.vertical, 4)
                            Text(verbatim: "\(l10n.pkgReceiptsNote): \(effectivePackageIDs.map(SafeFileReader.sanitizeForDisplay).joined(separator: ", "))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(palette.secondaryText)
                        }
                    }
                    .padding(10)
                }
                .frame(minHeight: 130, maxHeight: 210)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(palette.sidebarBackground.opacity(0.75))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(palette.border, lineWidth: 1)
                        )
                )
            }

            // Action Buttons (disable Return-key default action in permanent delete mode to prevent accidental loss)
            HStack {
                Spacer()
                Button(l10n.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                if selectedMode == .permanent {
                    Button {
                        onConfirm(.permanent)
                    } label: {
                        Text(l10n.t("确认永久删除", "Delete Permanently"))
                            .fontWeight(.semibold)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.danger)
                } else {
                    Button {
                        onConfirm(.trash)
                    } label: {
                        Text(l10n.t("移至废纸篓", "Move to Trash"))
                            .fontWeight(.semibold)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(palette.detailBackground)
        .preferredColorScheme(palette.isDeepOcean ? .dark : nil)
    }

    private func warningBox(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .padding(.top, 1)
            Text(verbatim: text)
                .font(.system(size: 12))
                .foregroundStyle(palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(color.opacity(0.35), lineWidth: 1)
                )
        )
    }
}

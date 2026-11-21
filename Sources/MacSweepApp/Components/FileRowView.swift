import MacSweepCore
import SwiftUI

struct FileRowView: View {
    let file: ServiceFile
    let isDisabled: Bool
    let palette: AppPalette
    let l10n: L10n
    let onToggle: () -> Void
    let onReveal: () -> Void

    init(
        file: ServiceFile,
        isDisabled: Bool = false,
        palette: AppPalette,
        l10n: L10n,
        onToggle: @escaping () -> Void,
        onReveal: @escaping () -> Void
    ) {
        self.file = file
        self.isDisabled = isDisabled
        self.palette = palette
        self.l10n = l10n
        self.onToggle = onToggle
        self.onReveal = onReveal
    }

    @StateObject private var hoverState = LocalState(false)

    var body: some View {
        HStack(spacing: 10) {
            SweepCheckbox(
                isChecked: file.isSelected,
                isDisabled: isDisabled,
                palette: palette,
                action: onToggle
            )

            AppIconView(path: file.url.path, size: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.displayName)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if file.requiresAdmin {
                        Label(l10n.adminBadge, systemImage: "lock.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(palette.warning)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(palette.warning.opacity(0.16)))
                    }

                    if file.requiresReboot {
                        Text(l10n.rebootBadge)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(palette.accent.opacity(0.16)))
                    }
                }

                Text(shortenedPath(file.url.path))
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if hoverState.value {
                Button(action: onReveal) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.secondaryText)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(palette.cardHoverBackground))
                }
                .buttonStyle(.plain)
                .help(l10n.revealInFinder)
            }

            if let sz = file.size {
                Text(ByteFormatter.format(sz))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(palette.secondaryText)
                    .monospacedDigit()
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.75)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hoverState.value ? palette.cardHoverBackground.opacity(0.7) : Color.clear)
        )
        .onHover { hoverState.value = $0 }
        .help(file.matchReason.isEmpty ? file.url.path : "\(file.url.path)\n(\(file.matchReason))")
    }

    private func shortenedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

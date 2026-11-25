import MacSweepCore
import SwiftUI

struct VolumeCapacityBarView: View {
    let volume: VolumeStorageInfo
    let analyzedNode: DiskTreeNode?
    let palette: AppPalette
    let l10n: L10n

    private var analyzedFraction: Double {
        guard volume.totalBytes > 0, let node = analyzedNode else { return 0 }
        return min(volume.usedFraction, Double(node.bytes) / Double(volume.totalBytes))
    }

    private var otherUsedFraction: Double {
        max(0, volume.usedFraction - analyzedFraction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            volumeHeaderRow

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    statChip(label: l10n.volumeUsedLabel, value: ByteFormatter.format(volume.usedBytes), color: palette.accent)
                    if let node = analyzedNode {
                        statChip(label: l10n.analyzedFolderLabel, value: ByteFormatter.format(node.bytes), color: palette.warning)
                    }
                    statChip(label: l10n.volumeAvailableLabel, value: ByteFormatter.format(volume.availableBytes), color: palette.success)
                    statChip(label: l10n.volumeTotalLabel, value: ByteFormatter.format(volume.totalBytes), color: palette.secondaryText)
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 14) {
                        statChip(label: l10n.volumeUsedLabel, value: ByteFormatter.format(volume.usedBytes), color: palette.accent)
                        if let node = analyzedNode {
                            statChip(label: l10n.analyzedFolderLabel, value: ByteFormatter.format(node.bytes), color: palette.warning)
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 14) {
                        statChip(label: l10n.volumeAvailableLabel, value: ByteFormatter.format(volume.availableBytes), color: palette.success)
                        statChip(label: l10n.volumeTotalLabel, value: ByteFormatter.format(volume.totalBytes), color: palette.secondaryText)
                        Spacer(minLength: 0)
                    }
                }
            }

            GeometryReader { geo in
                let width = max(0, geo.size.width)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(palette.cardBackground.opacity(0.8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(palette.border, lineWidth: 1)
                        )

                    HStack(spacing: 0) {
                        if otherUsedFraction > 0 {
                            Rectangle()
                                .fill(palette.accent.opacity(0.75))
                                .frame(width: width * CGFloat(otherUsedFraction))
                        }
                        if analyzedFraction > 0 {
                            Rectangle()
                                .fill(palette.warning)
                                .frame(width: max(2, width * CGFloat(analyzedFraction)))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .frame(height: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.cardBackground.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(palette.border, lineWidth: 1)
                )
        )
    }

    private var volumeHeaderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: volume.isRemovable ? "externaldrive.fill" : "internaldrive.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(palette.accent)

            Text(SafeFileReader.sanitizeForDisplay(volume.name))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(palette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)

            if let fs = volume.fileSystemType, !fs.isEmpty {
                Text(SafeFileReader.sanitizeForDisplay(fs))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(palette.tertiaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(palette.cardBackground))
            }

            Spacer(minLength: 0)
        }
    }

    private func statChip(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(palette.tertiaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.primaryText)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct ProportionalSizeBar: View {
    let fraction: Double
    let palette: AppPalette

    private var clamped: Double {
        min(1.0, max(0.0, fraction))
    }

    private var fillColor: Color {
        clamped >= 0.25 ? palette.warning : palette.accent
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(0, geo.size.width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.border.opacity(0.45))
                Capsule()
                    .fill(fillColor)
                    .frame(width: clamped > 0 ? max(3, w * CGFloat(clamped)) : 0)
            }
        }
        .frame(height: 5)
    }
}

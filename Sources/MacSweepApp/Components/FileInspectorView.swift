import AppKit
import MacSweepCore
import SwiftUI

struct FileInspectorView: View {
    let url: URL?
    let metadata: FileMetadataInfo?
    let previewState: InspectorPreviewState
    let isProtected: Bool
    let protectionReason: String?
    var isQuickLookAllowed: Bool = true
    let palette: AppPalette
    let l10n: L10n
    let onQuickLook: (URL) -> Void
    let onReveal: (URL) -> Void
    let onProtect: (URL) -> Void

    @StateObject private var showInlineQuickLookBox = LocalState(false)

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(l10n.inspectorTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                Spacer()
                if let url {
                    HStack(spacing: 6) {
                        Button {
                            onQuickLook(url)
                        } label: {
                            Image(systemName: "eye")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.secondaryText)
                                .padding(5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(palette.cardBackground))
                        }
                        .buttonStyle(.plain)
                        .help("\(l10n.quickLook) (Space)")

                        Button {
                            onReveal(url)
                        } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.secondaryText)
                                .padding(5)
                                .background(RoundedRectangle(cornerRadius: 6).fill(palette.cardBackground))
                        }
                        .buttonStyle(.plain)
                        .help(l10n.revealInFinder)

                        if !isProtected {
                            Button {
                                onProtect(url)
                            } label: {
                                Image(systemName: "shield.lefthalf.filled")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(palette.accent)
                                    .padding(5)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(palette.cardBackground))
                            }
                            .buttonStyle(.plain)
                            .help(l10n.protectPath)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(palette.border).frame(height: 1)
            }

            if let url {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        heroCard(url: url)
                        if let metadata {
                            metadataCard(metadata)
                        }
                        previewCard(url: url)
                    }
                    .padding(14)
                }
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(palette.tertiaryText)
                    Text(l10n.selectItemToInspect)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.secondaryText)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(20)
            }
        }
        .background(palette.detailBackground)
    }

    private func heroCard(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AppIconView(path: url.path, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SafeFileReader.sanitizeForDisplay(metadata?.name ?? url.lastPathComponent))
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(SafeFileReader.sanitizeForDisplay(url.path))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(palette.tertiaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 5) {
                if metadata?.isSIPRestricted == true {
                    badgePill(l10n.systemProtectedBadge, icon: "lock.shield.fill", color: palette.danger)
                } else if isProtected {
                    badgePill(l10n.protectedBadge, icon: "shield.fill", color: palette.accent)
                }
                if metadata?.isUserImmutable == true {
                    badgePill(l10n.userLockedBadge, icon: "lock.fill", color: palette.warning)
                }
                if metadata?.isDataless == true {
                    badgePill(l10n.datalessBadge, icon: "icloud.and.arrow.down", color: palette.warning)
                }
                if metadata?.isSymlinkBroken == true {
                    badgePill(l10n.brokenSymlinkBadge, icon: "link.badge.plus", color: palette.danger)
                } else if metadata?.isSymbolicLink == true {
                    badgePill(l10n.symlinkBadge, icon: "arrowshape.turn.up.right.fill", color: palette.accent)
                }
            }

            if let protectionReason, isProtected {
                Text(SafeFileReader.sanitizeForDisplay(protectionReason))
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
    }

    private func metadataCard(_ meta: FileMetadataInfo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            metaRow(l10n.kindLabel, SafeFileReader.sanitizeForDisplay(meta.kindDescription))
            metaRow(l10n.sizeLabel, ByteFormatter.format(meta.sizeBytes))
            if let alloc = meta.allocatedSizeBytes {
                metaRow(l10n.allocatedSizeLabel, ByteFormatter.format(alloc))
            }
            metaRow(l10n.modifiedLabel, l10n.formatDate(meta.modifiedDate))
            metaRow(l10n.createdLabel, l10n.formatDate(meta.createdDate))
            metaRow(l10n.accessedLabel, l10n.formatDate(meta.accessedDate))
            metaRow(l10n.permissionsLabel, "\(meta.posixPermissionsOctal) (\(symbolicPermissions(meta.posixPermissions)))")
            if let target = meta.symlinkTarget {
                metaRow(l10n.symbolicLinkTargetLabel, SafeFileReader.sanitizeForDisplay(target))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
    }

    private func previewCard(url: URL) -> some View {
        let qlEligible = isQuickLookAllowed && QLPreviewPanelBridge.isEligibleForQuickLook(metadata: metadata)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(l10n.contentPreviewTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                if qlEligible {
                    Button {
                        showInlineQuickLookBox.value.toggle()
                    } label: {
                        Text(showInlineQuickLookBox.value ? l10n.t("安全文本/摘要", "Safe Preview") : "QuickLook")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(palette.accent.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }

            if showInlineQuickLookBox.value && qlEligible {
                QuickLookPreviewView(url: url, isEligible: true)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                switch previewState {
                case .none:
                    EmptyView()
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(l10n.t("正在读取安全预览...", "Loading bounded preview..."))
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.secondaryText)
                    }
                    .padding(.vertical, 12)
                case let .text(text, encoding, isTruncated, totalBytes, shownBytes):
                    VStack(alignment: .leading, spacing: 6) {
                        ScrollView([.vertical, .horizontal]) {
                            Text(verbatim: text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(palette.primaryText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minWidth: 0, idealWidth: 260, maxWidth: .infinity, maxHeight: 220)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(palette.sidebarBackground.opacity(0.65))
                        )

                        HStack {
                            Text(encoding)
                                .font(.system(size: 10))
                                .foregroundStyle(palette.tertiaryText)
                            Spacer()
                            if isTruncated {
                                Text(l10n.previewTruncated(shownBytes, total: totalBytes))
                                    .font(.system(size: 10))
                                    .foregroundStyle(palette.warning)
                            }
                        }
                    }
                case let .hexDump(hex, byteCount, isTruncated, totalBytes):
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l10n.binaryHexPreview)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(palette.accent)
                        ScrollView([.vertical, .horizontal]) {
                            Text(verbatim: hex)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(palette.secondaryText)
                                .textSelection(.enabled)
                        }
                        .frame(minWidth: 0, idealWidth: 260, maxWidth: .infinity, maxHeight: 190)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(palette.sidebarBackground.opacity(0.65))
                        )
                        if isTruncated {
                            Text(l10n.previewTruncated(byteCount, total: totalBytes))
                                .font(.system(size: 10))
                                .foregroundStyle(palette.tertiaryText)
                        }
                    }
                case let .image(nsImage, _, byteCount):
                    VStack(alignment: .leading, spacing: 6) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: 210)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(palette.sidebarBackground.opacity(0.5))
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        HStack {
                            Text("\(Int(nsImage.size.width)) × \(Int(nsImage.size.height)) px")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(palette.tertiaryText)
                            Spacer()
                            Text(ByteFormatter.format(Int64(byteCount)))
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.tertiaryText)
                        }
                    }
                case let .unavailable(reason):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n.previewUnavailable)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(palette.secondaryText)
                        Text(l10n.previewUnavailableReasonText(reason))
                            .font(.system(size: 11))
                            .foregroundStyle(palette.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardSurface)
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(palette.tertiaryText)
                .frame(width: 78, alignment: .leading)
            Text(verbatim: value)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(palette.primaryText)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private func badgePill(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(palette.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(palette.border, lineWidth: 1)
            )
    }

    private func symbolicPermissions(_ mode: UInt16) -> String {
        let flags: [(UInt16, Character)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        return String(flags.map { (mode & $0.0) != 0 ? $0.1 : "-" })
    }
}

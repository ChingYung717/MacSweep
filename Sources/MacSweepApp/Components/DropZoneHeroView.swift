import SwiftUI
import UniformTypeIdentifiers

struct DropZoneHeroView: View {
    let isScanning: Bool
    let palette: AppPalette
    let l10n: L10n
    let onDropAppURL: (URL) -> Void

    @StateObject private var dropTargeted = LocalState(false)

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // Layered stylized macOS Folder + floating mini app tiles illustration
            ZStack {
                // Soft ambient glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [palette.accent.opacity(0.28), Color.clear],
                            center: .center,
                            startRadius: 10,
                            endRadius: 120
                        )
                    )
                    .frame(width: 240, height: 240)

                // Floating mini tiles behind folder
                HStack(spacing: 38) {
                    floatingTile(
                        symbol: "sparkles",
                        colors: [Color(red: 0.25, green: 0.78, blue: 0.48), Color(red: 0.14, green: 0.56, blue: 0.34)],
                        angle: -16
                    )
                    .offset(y: -48)

                    floatingTile(
                        symbol: "slider.horizontal.3",
                        colors: [Color(red: 0.94, green: 0.42, blue: 0.36), Color(red: 0.76, green: 0.24, blue: 0.22)],
                        angle: 14
                    )
                    .offset(y: -62)
                }

                // Back folder tab
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.18, green: 0.50, blue: 0.85), Color(red: 0.10, green: 0.31, blue: 0.60)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 158, height: 108)
                    .offset(y: -12)

                // Front frosted folder body
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.42, green: 0.80, blue: 1.0), Color(red: 0.19, green: 0.58, blue: 0.96)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 170, height: 106)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.32), lineWidth: 1)
                    )
                    .overlay {
                        Image(systemName: "app.badge.checkmark")
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(Color(red: 0.08, green: 0.34, blue: 0.68).opacity(0.55))
                    }
                    .shadow(color: Color.black.opacity(0.32), radius: 18, y: 10)
                    .offset(y: 6)
            }
            .frame(height: 175)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    if isScanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isScanning ? l10n.scanningServiceFiles : l10n.selectAppPromptTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(palette.primaryText)
                }

                Text(isScanning ? l10n.scanningSubtitle : l10n.selectAppPromptSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            // Drag & Drop Quick Uninstall Zone
            VStack(spacing: 10) {
                Image(systemName: dropTargeted.value ? "arrow.down.circle.fill" : "square.and.arrow.down")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(dropTargeted.value ? palette.accent : palette.accent.opacity(0.85))
                    .scaleEffect(dropTargeted.value ? 1.12 : 1.0)
                    .animation(.spring(response: 0.25), value: dropTargeted.value)

                Text(dropTargeted.value ? l10n.dropZoneActive : l10n.dropZoneTitle)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(dropTargeted.value ? palette.primaryText : palette.secondaryText)
            }
            .frame(maxWidth: 440)
            .frame(height: 112)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(dropTargeted.value ? palette.accent.opacity(0.18) : palette.dropZoneFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        dropTargeted.value ? palette.accent : palette.border.opacity(1.5),
                        style: StrokeStyle(lineWidth: dropTargeted.value ? 2 : 1.3, dash: [7, 5])
                    )
            )
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted.value) { providers in
                handleDrop(providers: providers)
            }

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func floatingTile(symbol: String, colors: [Color], angle: Double) -> some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 44, height: 44)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Color.black.opacity(0.3), radius: 8, y: 4)
            .rotationEffect(.degrees(angle))
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let droppedURL: URL?
            if let data = item as? Data {
                droppedURL = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                droppedURL = url
            } else {
                droppedURL = nil
            }
            if let url = droppedURL, url.isFileURL, url.pathExtension.lowercased() == "app" {
                DispatchQueue.main.async {
                    onDropAppURL(url)
                }
            }
        }
        return true
    }
}

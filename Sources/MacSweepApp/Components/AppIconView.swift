import AppKit
import SwiftUI

@MainActor
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 400
    }

    func icon(forPath path: String) -> NSImage {
        let key = path as NSString
        if let existing = cache.object(forKey: key) {
            return existing
        }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(img, forKey: key)
        return img
    }
}

struct AppIconView: View {
    let path: String
    let size: CGFloat

    var body: some View {
        Image(nsImage: IconCache.shared.icon(forPath: path))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

struct SweepCheckbox: View {
    let isChecked: Bool
    let isDisabled: Bool
    let palette: AppPalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isChecked ? palette.accent : Color.clear)
                    .frame(width: 17, height: 17)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(
                                isChecked ? palette.accent : (isDisabled ? palette.tertiaryText.opacity(0.4) : palette.secondaryText.opacity(0.6)),
                                lineWidth: 1.3
                            )
                    )
                if isChecked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .contentShape(Rectangle())
            .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
    }
}

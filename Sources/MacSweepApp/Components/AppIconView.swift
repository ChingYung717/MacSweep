import AppKit
import SwiftUI

@MainActor
final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSString, NSImage>()

    var isDemoMode: Bool = false {
        didSet {
            if isDemoMode != oldValue {
                cache.removeAllObjects()
            }
        }
    }

    private init() {
        cache.countLimit = 400
    }

    func icon(forPath path: String) -> NSImage {
        let key = (isDemoMode ? "demo:" + path : path) as NSString
        if let existing = cache.object(forKey: key) {
            return existing
        }
        let img = isDemoMode ? Self.syntheticDemoIcon(forPath: path) : NSWorkspace.shared.icon(forFile: path)
        cache.setObject(img, forKey: key)
        return img
    }

    private static func fnv1aHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private static func syntheticDemoIcon(forPath path: String) -> NSImage {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        let lower = name.lowercased()

        let palettePairs: [(NSColor, NSColor)] = [
            (NSColor(calibratedRed: 0.14, green: 0.62, blue: 0.98, alpha: 1), NSColor(calibratedRed: 0.08, green: 0.34, blue: 0.78, alpha: 1)),
            (NSColor(calibratedRed: 0.25, green: 0.76, blue: 0.66, alpha: 1), NSColor(calibratedRed: 0.09, green: 0.48, blue: 0.45, alpha: 1)),
            (NSColor(calibratedRed: 0.56, green: 0.42, blue: 0.96, alpha: 1), NSColor(calibratedRed: 0.33, green: 0.20, blue: 0.72, alpha: 1)),
            (NSColor(calibratedRed: 0.98, green: 0.52, blue: 0.30, alpha: 1), NSColor(calibratedRed: 0.78, green: 0.26, blue: 0.18, alpha: 1)),
            (NSColor(calibratedRed: 0.22, green: 0.72, blue: 0.90, alpha: 1), NSColor(calibratedRed: 0.12, green: 0.44, blue: 0.72, alpha: 1)),
            (NSColor(calibratedRed: 0.95, green: 0.66, blue: 0.18, alpha: 1), NSColor(calibratedRed: 0.76, green: 0.41, blue: 0.08, alpha: 1)),
            (NSColor(calibratedRed: 0.90, green: 0.32, blue: 0.58, alpha: 1), NSColor(calibratedRed: 0.62, green: 0.16, blue: 0.42, alpha: 1)),
        ]

        let hash = fnv1aHash(path)
        let pair = palettePairs[Int(hash % UInt64(palettePairs.count))]

        let symbolName: String
        let topColor: NSColor
        let bottomColor: NSColor
        let isFolderLike: Bool

        if ext == "app" {
            isFolderLike = false
            topColor = pair.0
            bottomColor = pair.1
            if lower.contains("novanote") {
                symbolName = "doc.text.fill"
            } else if lower.contains("pixelforge") {
                symbolName = "paintbrush.pointed.fill"
            } else if lower.contains("codepulse") {
                symbolName = "chevron.left.forwardslash.chevron.right"
            } else if lower.contains("cloudsync") {
                symbolName = "icloud.fill"
            } else if lower.contains("audioweave") {
                symbolName = "waveform"
            } else if lower.contains("deckflow") {
                symbolName = "rectangle.stack.fill"
            } else if lower.contains("chrome") || lower.contains("firefox") {
                symbolName = "globe"
            } else {
                symbolName = "app.fill"
            }
        } else if ext == "dmg" || ext == "iso" {
            isFolderLike = false
            topColor = NSColor(calibratedRed: 0.44, green: 0.56, blue: 0.74, alpha: 1)
            bottomColor = NSColor(calibratedRed: 0.24, green: 0.33, blue: 0.48, alpha: 1)
            symbolName = "opticaldiscdrive.fill"
        } else if ext == "zip" || ext == "gz" || ext == "tar" {
            isFolderLike = false
            topColor = NSColor(calibratedRed: 0.88, green: 0.63, blue: 0.24, alpha: 1)
            bottomColor = NSColor(calibratedRed: 0.66, green: 0.40, blue: 0.12, alpha: 1)
            symbolName = "doc.zipper"
        } else if ext == "mov" || ext == "mp4" {
            isFolderLike = false
            topColor = NSColor(calibratedRed: 0.62, green: 0.40, blue: 0.92, alpha: 1)
            bottomColor = NSColor(calibratedRed: 0.38, green: 0.20, blue: 0.68, alpha: 1)
            symbolName = "film.fill"
        } else if ext == "wav" || ext == "mp3" || ext == "driver" {
            isFolderLike = false
            topColor = NSColor(calibratedRed: 0.24, green: 0.72, blue: 0.64, alpha: 1)
            bottomColor = NSColor(calibratedRed: 0.11, green: 0.45, blue: 0.42, alpha: 1)
            symbolName = "waveform"
        } else if ext == "pdf" {
            isFolderLike = false
            topColor = NSColor(calibratedRed: 0.90, green: 0.34, blue: 0.36, alpha: 1)
            bottomColor = NSColor(calibratedRed: 0.66, green: 0.16, blue: 0.20, alpha: 1)
            symbolName = "doc.richtext.fill"
        } else if ext == "plist" || ext == "json" || ext == "md" || ext == "swift" || ext == "ips" || ext == "panic" || ext == "lock" || lower == ".zshrc" {
            isFolderLike = false
            topColor = NSColor(calibratedRed: 0.28, green: 0.58, blue: 0.92, alpha: 1)
            bottomColor = NSColor(calibratedRed: 0.16, green: 0.36, blue: 0.68, alpha: 1)
            symbolName = ext == "json" ? "curlybraces" : (ext == "lock" ? "lock.doc.fill" : "doc.plaintext.fill")
        } else if path.contains("/Library/") && !ext.isEmpty && ext != "caches" {
            isFolderLike = true
            topColor = NSColor(calibratedRed: 0.34, green: 0.68, blue: 0.96, alpha: 1)
            bottomColor = NSColor(calibratedRed: 0.17, green: 0.46, blue: 0.80, alpha: 1)
            symbolName = "folder.badge.gearshape"
        } else {
            isFolderLike = true
            topColor = NSColor(calibratedRed: 0.38, green: 0.72, blue: 0.98, alpha: 1)
            bottomColor = NSColor(calibratedRed: 0.18, green: 0.50, blue: 0.84, alpha: 1)
            symbolName = path.contains("/Caches") ? "folder.badge.gearshape" : "folder.fill"
        }

        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size, flipped: false) { rect in
            let insetRect = rect.insetBy(dx: 4, dy: 4)
            let cornerRadius: CGFloat = isFolderLike ? 11 : insetRect.width * 0.225
            let squircle = NSBezierPath(roundedRect: insetRect, xRadius: cornerRadius, yRadius: cornerRadius)

            if let grad = NSGradient(starting: topColor, ending: bottomColor) {
                grad.draw(in: squircle, angle: -90)
            } else {
                topColor.setFill()
                squircle.fill()
            }

            NSColor.white.withAlphaComponent(0.24).setStroke()
            squircle.lineWidth = 1.5
            squircle.stroke()

            let cfg = NSImage.SymbolConfiguration(pointSize: isFolderLike ? 24 : 25, weight: .semibold)
            if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                let tinted = NSImage(size: sym.size, flipped: false) { sRect in
                    sym.draw(in: sRect)
                    NSColor.white.withAlphaComponent(0.95).set()
                    sRect.fill(using: .sourceAtop)
                    return true
                }
                let symSize = tinted.size
                let drawRect = NSRect(
                    x: (rect.width - symSize.width) / 2.0,
                    y: (rect.height - symSize.height) / 2.0,
                    width: symSize.width,
                    height: symSize.height
                )
                tinted.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        return image
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

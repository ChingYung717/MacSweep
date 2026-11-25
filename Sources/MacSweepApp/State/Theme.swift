import AppKit
import MacSweepCore
import SwiftUI

struct AppPalette {
    let isDark: Bool
    let isDeepOcean: Bool

    let windowBackground: Color
    let sidebarBackground: Color
    let listBackground: Color
    let detailBackground: Color
    let cardBackground: Color
    let cardHoverBackground: Color
    let cardSelectedBackground: Color
    let border: Color
    let activeBorder: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let accent: Color
    let accentGlow: Color
    let danger: Color
    let warning: Color
    let success: Color
    let dropZoneFill: Color
    let buttonTop: Color
    let buttonBottom: Color
    let sidebarActiveTop: Color
    let sidebarActiveBottom: Color
    let sidebarActiveForeground: Color

    static let deepOcean = AppPalette(
        isDark: true,
        isDeepOcean: true,
        windowBackground: Color(red: 0.039, green: 0.106, blue: 0.188),     // #0A1B30
        sidebarBackground: Color(red: 0.028, green: 0.078, blue: 0.145),    // #071425
        listBackground: Color(red: 0.043, green: 0.114, blue: 0.200),       // #0B1D33
        detailBackground: Color(red: 0.055, green: 0.137, blue: 0.235),     // #0E233C
        cardBackground: Color(red: 0.071, green: 0.165, blue: 0.275),       // #122A46
        cardHoverBackground: Color(red: 0.090, green: 0.204, blue: 0.337),  // #173456
        cardSelectedBackground: Color(red: 0.106, green: 0.271, blue: 0.459), // #1B4575
        border: Color(red: 0.48, green: 0.74, blue: 1.0).opacity(0.14),
        activeBorder: Color(red: 0.31, green: 0.68, blue: 1.0).opacity(0.65),
        primaryText: Color(red: 0.945, green: 0.969, blue: 1.0),
        secondaryText: Color(red: 0.565, green: 0.690, blue: 0.835),
        tertiaryText: Color(red: 0.415, green: 0.545, blue: 0.690),
        accent: Color(red: 0.212, green: 0.588, blue: 1.0),                 // #3696FF
        accentGlow: Color(red: 0.20, green: 0.62, blue: 1.0).opacity(0.32),
        danger: Color(red: 0.96, green: 0.35, blue: 0.38),
        warning: Color(red: 0.98, green: 0.72, blue: 0.22),
        success: Color(red: 0.24, green: 0.82, blue: 0.54),
        dropZoneFill: Color(red: 0.08, green: 0.21, blue: 0.36).opacity(0.42),
        buttonTop: Color(red: 0.22, green: 0.57, blue: 0.98),
        buttonBottom: Color(red: 0.13, green: 0.43, blue: 0.84),
        sidebarActiveTop: Color(red: 0.14, green: 0.38, blue: 0.66),
        sidebarActiveBottom: Color(red: 0.08, green: 0.23, blue: 0.44),
        sidebarActiveForeground: Color.white
    )

    static func system(colorScheme: ColorScheme) -> AppPalette {
        let dark = (colorScheme == .dark)
        return AppPalette(
            isDark: dark,
            isDeepOcean: false,
            windowBackground: Color(nsColor: .windowBackgroundColor),
            sidebarBackground: Color(nsColor: .underPageBackgroundColor),
            listBackground: Color(nsColor: .windowBackgroundColor),
            detailBackground: Color(nsColor: .textBackgroundColor).opacity(dark ? 0.45 : 0.7),
            cardBackground: Color(nsColor: .controlBackgroundColor),
            cardHoverBackground: Color(nsColor: .controlColor).opacity(dark ? 0.5 : 0.6),
            cardSelectedBackground: Color.accentColor.opacity(dark ? 0.28 : 0.15),
            border: Color(nsColor: .separatorColor).opacity(0.65),
            activeBorder: Color.accentColor.opacity(0.7),
            primaryText: Color(nsColor: .labelColor),
            secondaryText: Color(nsColor: .secondaryLabelColor),
            tertiaryText: Color(nsColor: .tertiaryLabelColor),
            accent: Color.accentColor,
            accentGlow: Color.accentColor.opacity(0.22),
            danger: Color.red,
            warning: Color.orange,
            success: Color.green,
            dropZoneFill: Color(nsColor: .controlBackgroundColor).opacity(0.6),
            buttonTop: Color.accentColor,
            buttonBottom: Color.accentColor.opacity(0.85),
            sidebarActiveTop: Color.accentColor.opacity(dark ? 0.36 : 0.18),
            sidebarActiveBottom: Color.accentColor.opacity(dark ? 0.24 : 0.12),
            sidebarActiveForeground: dark ? Color.white : Color(nsColor: .labelColor)
        )
    }

    static func resolve(mode: ThemeMode, systemScheme: ColorScheme) -> AppPalette {
        switch mode {
        case .deepOcean:
            return .deepOcean
        case .system:
            return .system(colorScheme: systemScheme)
        }
    }
}

public enum ByteFormatter {
    @MainActor
    private static let shared: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    @MainActor
    private static let memoryShared: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    @MainActor
    public static func format(_ bytes: Int64) -> String {
        shared.string(fromByteCount: max(0, bytes))
    }

    @MainActor
    public static func format(_ bytes: UInt64) -> String {
        format(Int64(min(bytes, UInt64(Int64.max))))
    }

    @MainActor
    public static func formatMemory(_ bytes: Int64) -> String {
        memoryShared.string(fromByteCount: max(0, bytes))
    }

    @MainActor
    public static func formatMemory(_ bytes: UInt64) -> String {
        formatMemory(Int64(min(bytes, UInt64(Int64.max))))
    }
}

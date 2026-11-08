import AppKit
import SwiftUI

/// Abley's forest, mint and porcelain palette. Content fills are translucent
/// veils over native glass; accessibility appearances restore solid surfaces.
enum OverlayPalette {
    static let backdropBase = adaptive("backdropBase", light: 0xF2EFE3, dark: 0x203A2C)
    static let canvas = adaptive("canvas", light: 0xF2EFE3, dark: 0x203A2C, opacity: 0.14)
    static let readingSurface = adaptive("reading", light: 0xF6F3E9, dark: 0x203A2C, opacity: 0.10)
    static let surface = adaptive("surface", light: 0xF2EFE3, dark: 0x2A4333, opacity: 0.14)
    static let surfaceRaised = adaptive("raised", light: 0xF7F5EC, dark: 0xB5DFB5,
                                        highContrastDark: 0x2A4333, opacity: 0.12)
    static let surfaceOverlay = adaptive("overlay", light: 0xFFFFFF, dark: 0xB5DFB5,
                                         highContrastDark: 0x314C3B, opacity: 0.18)
    static let well = adaptive("well", light: 0xDDE7DA, dark: 0x152C20, opacity: 0.22)
    static let shellTint = adaptive("shell", light: 0xD5E8D4, dark: 0x203A2C, opacity: 0.18)

    static let hairline = adaptive("hairline", light: 0x45634C, dark: 0xEFE4C7,
                                   highContrastLight: 0x48634B, highContrastDark: 0xCDE3C7, opacity: 0.22)
    static let hairlineStrong = adaptive("edge", light: 0x496C53, dark: 0xB5DFB5,
                                         highContrastLight: 0x304D38, highContrastDark: 0xDEF1D8, opacity: 0.44)
    static let glassHighlight = adaptive("highlight", light: 0xFFFFFF, dark: 0xD5E8D4)
    static let glassShadow = adaptive("shadow", light: 0x314C37, dark: 0x06180D)

    static let textPrimary = adaptive("text", light: 0x203225, dark: 0xEFE4C7)
    static let textSecondary = adaptive("secondary", light: 0x3E5443, dark: 0xE0DFC9,
                                        highContrastLight: 0x253E2C, highContrastDark: 0xF8F1DD)
    static let textTertiary = adaptive("tertiary", light: 0x506050, dark: 0xBECEB8,
                                       highContrastLight: 0x304C38, highContrastDark: 0xE3EED8)
    static let accent = adaptive("accent", light: 0x2B653F, dark: 0xB5DFB5)
    static let accentTint = adaptive("selection", light: 0x96BE9D, dark: 0xB5DFB5,
                                     highContrastLight: 0xD5E8D4, highContrastDark: 0x2D4936, opacity: 0.23)
    static let accentStroke = adaptive("selectionEdge", light: 0x4A8057, dark: 0xB5DFB5, opacity: 0.65)
    static let onAccent = adaptive("onAccent", light: 0xFFFFFF, dark: 0x203A2C)
    static let primaryAction = adaptive("action", light: 0x2B5036, dark: 0xB5DFB5)
    static let onPrimaryAction = adaptive("onAction", light: 0xF7F5EA, dark: 0x203A2C)

    static let success = adaptive("success", light: 0x246748, dark: 0x9AD6AB)
    static let warning = adaptive("warning", light: 0x8B500E, dark: 0xF5CD8D)
    static let critical = adaptive("critical", light: 0xAE303C, dark: 0xF7A8B1)

    static func adaptive(_ name: String, light: UInt, dark: UInt,
                         highContrastLight: UInt? = nil, highContrastDark: UInt? = nil,
                         opacity: Double = 1) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("memanager.\(name)")) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            // bestMatch collapses accessibility appearances to Aqua/Dark Aqua.
            // Inspect the original name before choosing the solid fallback.
            let needsSolidSurface = appearance.name == .accessibilityHighContrastAqua
                || appearance.name == .accessibilityHighContrastDarkAqua
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || reduceTransparency
            let value = isDark
                ? (needsSolidSurface ? highContrastDark ?? dark : dark)
                : (needsSolidSurface ? highContrastLight ?? light : light)
            return NSColor(srgbRed: Double((value >> 16) & 0xFF) / 255,
                           green: Double((value >> 8) & 0xFF) / 255,
                           blue: Double(value & 0xFF) / 255, alpha: needsSolidSurface ? 1 : opacity)
        })
    }

    private static let speakerColors: [Color] = [
        adaptive("speaker0", light: 0x66548F, dark: 0xC7B7EC),
        success, accent,
        adaptive("speaker3", light: 0x914864, dark: 0xE7AAC2),
        adaptive("speaker4", light: 0x455E9A, dark: 0xB1C7F0), warning
    ]

    static func speaker(_ index: Int) -> Color {
        speakerColors[((index % speakerColors.count) + speakerColors.count) % speakerColors.count]
    }
}

enum OverlayTone: Equatable, Hashable {
    case neutral, info, success, warning, critical

    var color: Color {
        switch self {
        case .neutral: return OverlayPalette.textSecondary
        case .info: return OverlayPalette.accent
        case .success: return OverlayPalette.success
        case .warning: return OverlayPalette.warning
        case .critical: return OverlayPalette.critical
        }
    }

    var tint: Color { color.opacity(self == .neutral ? 0.07 : 0.12) }
    var stroke: Color { self == .neutral ? OverlayPalette.hairlineStrong : color.opacity(0.48) }

    var systemImage: String {
        switch self {
        case .neutral: return "circle"
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .critical: return "xmark.octagon"
        }
    }
}

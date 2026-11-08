import SwiftUI

/// The four text button treatments the overlay uses. Primary is reserved
/// for the single most important action on a surface; secondary is the
/// default; ghost is for quiet inline actions; destructive is for deletes.
enum OverlayButtonKind {
    case primary
    case secondary
    case ghost
    case destructive
}

enum OverlayControlSize {
    case regular
    case small

    var height: CGFloat {
        switch self {
        case .regular: return 34
        case .small: return 28
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .regular: return 12
        case .small: return 9
        }
    }

    var font: Font {
        switch self {
        case .regular: return OverlayType.callout
        case .small: return OverlayType.captionStrong
        }
    }
}

struct OverlayButtonStyle: ButtonStyle {
    var kind: OverlayButtonKind = .secondary
    var size: OverlayControlSize = .regular

    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: kind == .primary ? 18 : DesignTokens.Radius.sm, style: .continuous)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(foreground(pressed: configuration.isPressed))
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.height)
            .background(shape.fill(fill(pressed: configuration.isPressed)))
            .overlay(shape.stroke(stroke, lineWidth: 1))
            .overlay {
                if kind == .primary || kind == .secondary {
                    shape.inset(by: 2).stroke(OverlayPalette.glassHighlight.opacity(kind == .primary ? 0.25 : 0.6), lineWidth: 1)
                }
            }
            .shadow(color: kind == .primary ? OverlayPalette.glassShadow.opacity(0.18) : .clear, radius: 3, y: 2)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .animation(DesignTokens.Motion.focus, value: configuration.isPressed)
    }

    private func foreground(pressed: Bool) -> Color {
        switch kind {
        case .primary: return OverlayPalette.onPrimaryAction
        case .secondary: return OverlayPalette.textPrimary
        case .ghost: return pressed ? OverlayPalette.textPrimary : OverlayPalette.textSecondary
        case .destructive: return OverlayTone.critical.color
        }
    }

    private func fill(pressed: Bool) -> Color {
        switch kind {
        case .primary: return OverlayPalette.primaryAction.opacity(pressed ? 0.82 : 1)
        case .secondary: return pressed ? OverlayPalette.surfaceOverlay : OverlayPalette.surfaceRaised
        case .ghost: return pressed ? OverlayPalette.surfaceRaised : .clear
        case .destructive: return OverlayTone.critical.tint.opacity(pressed ? 1.4 : 1)
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary: return OverlayPalette.glassHighlight.opacity(0.5)
        case .secondary: return OverlayPalette.hairlineStrong
        case .ghost: return .clear
        case .destructive: return OverlayTone.critical.stroke
        }
    }
}

extension ButtonStyle where Self == OverlayButtonStyle {
    static var overlayPrimary: OverlayButtonStyle { OverlayButtonStyle(kind: .primary) }
    static var overlaySecondary: OverlayButtonStyle { OverlayButtonStyle(kind: .secondary) }
    static var overlayGhost: OverlayButtonStyle { OverlayButtonStyle(kind: .ghost) }
    static var overlayDestructive: OverlayButtonStyle { OverlayButtonStyle(kind: .destructive) }

    static func overlay(_ kind: OverlayButtonKind, size: OverlayControlSize = .regular) -> OverlayButtonStyle {
        OverlayButtonStyle(kind: kind, size: size)
    }
}

/// Square icon button. `isActive` renders the accent tint for toggles.
struct OverlayIconButtonStyle: ButtonStyle {
    var size: CGFloat = 26
    var isActive: Bool = false
    var bordered: Bool = true

    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OverlayType.symbol(11))
            .foregroundStyle(isActive ? OverlayPalette.accent : OverlayPalette.textSecondary)
            .frame(width: size, height: size)
            .background {
                if bordered { PearlControlPlate(radius: DesignTokens.Radius.sm, tint: fill(pressed: configuration.isPressed)) }
                else { shape.fill(fill(pressed: configuration.isPressed)) }
            }
            .overlay(shape.stroke(stroke, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(shape)
            .animation(DesignTokens.Motion.focus, value: configuration.isPressed)
    }

    private func fill(pressed: Bool) -> Color {
        if isActive { return OverlayPalette.accentTint }
        if pressed { return OverlayPalette.surfaceOverlay }
        return bordered ? OverlayPalette.surfaceRaised : .clear
    }

    private var stroke: Color {
        if isActive { return OverlayPalette.accentStroke }
        return bordered ? OverlayPalette.hairlineStrong : .clear
    }
}

extension ButtonStyle where Self == OverlayIconButtonStyle {
    static var overlayIcon: OverlayIconButtonStyle { OverlayIconButtonStyle() }

    static func overlayIcon(size: CGFloat = 26, isActive: Bool = false, bordered: Bool = true) -> OverlayIconButtonStyle {
        OverlayIconButtonStyle(size: size, isActive: isActive, bordered: bordered)
    }
}

import SwiftUI

/// Elevation levels for cards. Each level is a slightly brighter veil over
/// the black canvas, so nesting reads as depth without shadows or blur.
enum OverlayCardLevel {
    case base
    case raised
    case overlay

    var fill: Color {
        switch self {
        case .base: return OverlayPalette.surface
        case .raised: return OverlayPalette.surfaceRaised
        case .overlay: return OverlayPalette.surfaceOverlay
        }
    }
}

/// The one card treatment used across the overlay: continuous corners, a
/// level fill, a hairline stroke, and an optional accent edge for the
/// element the user should read first.
struct OverlayCardModifier: ViewModifier {
    let level: OverlayCardLevel
    let cornerRadius: CGFloat
    let padding: CGFloat?
    let accentEdge: Bool
    let strokeColor: Color?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .padding(padding ?? 0)
            .background(shape.fill(level.fill))
            .overlay(shape.stroke(strokeColor ?? OverlayPalette.hairline, lineWidth: 1))
            .overlay(alignment: .leading) {
                if accentEdge {
                    Capsule()
                        .fill(OverlayPalette.accent.opacity(0.85))
                        .frame(width: 3)
                        .padding(.vertical, 10)
                        .padding(.leading, 1)
                }
            }
            .clipShape(shape)
    }
}

extension View {
    /// Wraps the view in the overlay's card treatment.
    func overlayCard(
        _ level: OverlayCardLevel = .base,
        cornerRadius: CGFloat = DesignTokens.Radius.lg,
        padding: CGFloat? = nil,
        accentEdge: Bool = false,
        stroke: Color? = nil
    ) -> some View {
        modifier(
            OverlayCardModifier(
                level: level,
                cornerRadius: cornerRadius,
                padding: padding,
                accentEdge: accentEdge,
                strokeColor: stroke
            )
        )
    }
}

/// One point hairline used wherever content needs a quiet separator.
struct Hairline: View {
    var axis: Axis = .horizontal
    var color: Color = OverlayPalette.hairline

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
    }
}

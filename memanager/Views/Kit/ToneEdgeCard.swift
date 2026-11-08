import SwiftUI

/// Card with a semantic tone on its leading edge. The Kit card only offers
/// the accent edge; debrief sections, timeline nodes, and practice cards
/// carry a state instead, so the edge takes a tone color.
struct ToneEdgeCardModifier: ViewModifier {
    let tone: OverlayTone
    let level: OverlayCardLevel
    let cornerRadius: CGFloat
    let stroke: Color?

    func body(content: Content) -> some View {
        content
            .overlayCard(level, cornerRadius: cornerRadius, stroke: stroke)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tone.color.opacity(0.85))
                    .frame(width: 3)
                    .padding(.vertical, DesignTokens.Spacing.sm)
                    .padding(.leading, 1)
            }
    }
}

extension View {
    func toneEdgeCard(
        _ tone: OverlayTone,
        level: OverlayCardLevel = .base,
        cornerRadius: CGFloat = DesignTokens.Radius.lg,
        stroke: Color? = nil
    ) -> some View {
        modifier(ToneEdgeCardModifier(tone: tone, level: level, cornerRadius: cornerRadius, stroke: stroke))
    }
}

import SwiftUI

/// The problem in the user's own words: a quote card with the accent edge
/// at the reading size, because this is the first thing said out loud.
struct RestatementView: View {
    let content: String
    let fontSize: CGFloat

    var body: some View {
        Text(content)
            .font(OverlayType.body(fontSize))
            .foregroundStyle(OverlayPalette.textPrimary)
            .lineSpacing(DesignTokens.Spacing.xxs)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, DesignTokens.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlayCard(
                .base,
                cornerRadius: DesignTokens.Radius.md,
                padding: DesignTokens.Spacing.md,
                accentEdge: true
            )
    }
}

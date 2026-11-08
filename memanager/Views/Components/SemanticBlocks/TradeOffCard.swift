import SwiftUI

/// The trade off the candidate chose, stated as one card so it is said
/// right after the two complexities.
struct TradeOffCard: View {
    let content: String
    let fontSize: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Image(systemName: "arrow.left.arrow.right")
                .font(OverlayType.heading)
                .foregroundStyle(OverlayPalette.accent)
                .padding(.top, DesignTokens.Spacing.xxs)
            Text(content)
                .font(OverlayType.body(fontSize))
                .foregroundStyle(OverlayPalette.textPrimary)
                .lineSpacing(DesignTokens.Spacing.xxs)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlayCard(.base, padding: DesignTokens.Spacing.md)
    }
}

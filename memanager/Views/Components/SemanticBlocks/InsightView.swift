import SwiftUI

/// The one idea that unlocks the problem, raised above the other blocks
/// because it is the sentence the interviewer is waiting to hear.
struct InsightView: View {
    let content: String
    let fontSize: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Image(systemName: "lightbulb")
                .font(OverlayType.title)
                .foregroundStyle(OverlayPalette.accent)
                .padding(.top, DesignTokens.Spacing.xxs)
            Text(content)
                .font(OverlayType.bodyStrong(fontSize))
                .foregroundStyle(OverlayPalette.textPrimary)
                .lineSpacing(DesignTokens.Spacing.xxs)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlayCard(.raised, padding: DesignTokens.Spacing.md)
    }
}

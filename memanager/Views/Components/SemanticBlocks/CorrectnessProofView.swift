import SwiftUI

/// Why the approach is right, carried in the success tone so the argument
/// reads as settled rather than as another open question.
struct CorrectnessProofView: View {
    let content: String
    let fontSize: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Image(systemName: "checkmark.seal")
                .font(OverlayType.title)
                .foregroundStyle(OverlayTone.success.color)
                .padding(.top, DesignTokens.Spacing.xxs)
            Text(content)
                .font(OverlayType.body(fontSize))
                .foregroundStyle(OverlayPalette.textPrimary)
                .lineSpacing(DesignTokens.Spacing.xxs)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlayCard(.base, padding: DesignTokens.Spacing.md, stroke: OverlayTone.success.stroke)
    }
}

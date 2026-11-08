import SwiftUI

/// A single thought from the model: a muted line with an accent rail so
/// the voice shifts between thinking and acting without any drama.
struct QuickAssistFlowThoughtRow: View {
    let thought: QuickAssistFlowThought

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Capsule()
                .fill(OverlayPalette.accentStroke)
                .frame(width: 2)
                .padding(.vertical, DesignTokens.Spacing.xxs)
            Text(thought.text)
                .font(OverlayType.body)
                .foregroundStyle(OverlayPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .lineSpacing(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }
}

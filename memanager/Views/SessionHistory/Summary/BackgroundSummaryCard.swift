import SwiftUI

/// The prose summary of the session.
struct BackgroundSummaryCard: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            FieldLabel(text: "Background")
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No summary text was produced.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
            } else {
                Text(text)
                    .font(OverlayType.body)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignTokens.Spacing.md)
                    .overlayCard(.raised, cornerRadius: DesignTokens.Radius.md)
            }
        }
    }
}

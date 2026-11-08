import SwiftUI

/// The transcript moment the card is anchored to, quoted back.
struct PracticeTranscriptQuote: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            FieldLabel(text: "Recorded source")
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "quote.opening")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
                Text(text.isEmpty ? "No transcript quote was stored for this card." : text)
                    .font(OverlayType.body)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Spacing.md)
            .overlayCard(.raised, cornerRadius: DesignTokens.Radius.md)
        }
    }
}

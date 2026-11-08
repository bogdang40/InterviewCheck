import SwiftUI

/// The live response card the signal engine surfaced, with its actions.
struct QuickAssistLiveResponseCardRow: View {
    let card: ResponseCard
    let cardCount: Int
    let onCycle: () -> Void
    let onPin: () -> Void
    let onRefine: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "bolt.horizontal")
                    .font(OverlayType.captionStrong)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .frame(width: 14)
                Text("Live response card")
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                if cardCount > 1 {
                    CountBadge(count: cardCount)
                }
                Spacer(minLength: 0)
                ToneBadge(text: "\(Int((card.confidence * 100).rounded()))%", tone: .neutral, monospaced: true)
                    .help("Confidence")
            }
            Text(card.shortLine)
                .font(OverlayType.bodyStrong(13))
                .foregroundStyle(OverlayPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(card.expandedLine)
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DesignTokens.Spacing.xs) {
                Button("Refine", action: onRefine)
                    .buttonStyle(.overlay(.secondary, size: .small))
                Button("Pin", action: onPin)
                    .buttonStyle(.overlay(.ghost, size: .small))
                    .help("Pin to the teleprompter")
                if cardCount > 1 {
                    Button("Next card", action: onCycle)
                        .buttonStyle(.overlay(.ghost, size: .small))
                }
                Spacer(minLength: 0)
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.overlay(.ghost, size: .small))
            }
        }
    }
}

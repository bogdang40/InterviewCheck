import SwiftUI

/// Practice cards authored from this session, with the evidence each one
/// was built on.
struct ReplayPracticeCardsSection: View {
    let cards: [PracticeCard]

    @State private var isExpanded = true

    var body: some View {
        if !cards.isEmpty {
            DisclosureCard("Practice cards", systemImage: "square.stack.3d.up", count: cards.count, isExpanded: $isExpanded) {
                VStack(spacing: DesignTokens.Spacing.xs) {
                    ForEach(cards) { card in
                        row(card)
                    }
                }
            }
        }
    }

    private func row(_ card: PracticeCard) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ToneBadge(text: card.topicTag.capitalized, tone: .info)
                ToneBadge(text: card.difficulty.title, tone: card.difficulty.tone, style: .outline)
                Spacer(minLength: 0)
            }
            Text(card.prompt)
                .font(OverlayType.body)
                .foregroundStyle(OverlayPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(ReplayPresentation.evidenceLabel(for: card.sourceEvidence))
                .font(OverlayType.monoMicro)
                .foregroundStyle(OverlayPalette.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DesignTokens.Spacing.sm)
        .overlayCard(.raised, cornerRadius: DesignTokens.Radius.md)
    }
}

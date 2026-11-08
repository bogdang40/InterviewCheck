import SwiftUI

/// Row content for one fact: kind symbol, label, summary or kind, and how
/// often it has come up.
struct KnowledgeNodeRow: View {
    let node: KnowledgeNode

    private var tone: OverlayTone {
        KnowledgeNodePresentation.tone(for: node.kind)
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: node.kind.systemImage)
                .font(OverlayType.callout)
                .foregroundStyle(tone == .neutral ? OverlayPalette.textSecondary : tone.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(node.label)
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .lineLimit(1)
                Text(KnowledgeNodePresentation.subtitle(for: node))
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignTokens.Spacing.xs)
            if node.mentionCount > 1 {
                CountBadge(count: node.mentionCount)
            }
        }
    }
}

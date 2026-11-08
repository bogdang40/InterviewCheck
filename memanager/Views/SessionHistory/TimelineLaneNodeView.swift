import SwiftUI

/// One event on the lane: the clock, the spine, and a card whose edge and
/// dot carry the severity tone.
struct TimelineLaneNodeView: View {
    let event: WorkstreamTimelineEvent
    let isFirst: Bool
    let isLast: Bool
    let isSelected: Bool
    let onSelect: () -> Void

    private var tone: OverlayTone { event.severity.tone }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            TimelineTimestampLabel(date: event.timestamp)
            TimelineLaneConnectorView(tone: tone, isFirst: isFirst, isLast: isLast)
                .padding(.top, DesignTokens.Spacing.sm)
            Button(action: onSelect) {
                card
            }
            .buttonStyle(.plain)
            .padding(.vertical, DesignTokens.Spacing.xxs)
        }
        .frame(minHeight: 44)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(event.title)
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: DesignTokens.Spacing.xs)
                ToneBadge(text: event.type.shortTitle, tone: .neutral, style: .outline)
            }
            Text(event.summary)
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
                .lineLimit(2)
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
        .padding(.leading, DesignTokens.Spacing.md)
        .padding(.trailing, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .toneEdgeCard(
            tone,
            level: isSelected ? .raised : .base,
            cornerRadius: DesignTokens.Radius.md,
            stroke: isSelected ? OverlayPalette.accentStroke : nil
        )
        .contentShape(Rectangle())
    }
}

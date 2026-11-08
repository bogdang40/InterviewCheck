import SwiftUI

/// Several events within a few seconds fold into one disclosure row that
/// shows the count, the time range, and the dominant severity. Opening it
/// lists the events as selectable rows.
struct TimelineClusterNodeView: View {
    let events: [WorkstreamTimelineEvent]
    let dominantSeverity: WorkstreamEventSeverity
    let timestamp: Date
    let isFirst: Bool
    let isLast: Bool
    let selectedEventID: String?
    let onSelectEvent: (String) -> Void

    @State private var isExpanded = false

    private var rangeLabel: String {
        guard let first = events.first, let last = events.last else { return "" }
        return TimelineTimeFormatter.range(from: first.timestamp, to: last.timestamp)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
            TimelineTimestampLabel(date: timestamp)
            TimelineLaneConnectorView(tone: dominantSeverity.tone, isFirst: isFirst, isLast: isLast)
                .padding(.top, DesignTokens.Spacing.sm)
            DisclosureCard(
                "\(events.count) events",
                tone: dominantSeverity.tone,
                isExpanded: $isExpanded,
                trailing: {
                    Text(rangeLabel)
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textTertiary)
                        .lineLimit(1)
                },
                content: {
                    VStack(spacing: DesignTokens.Spacing.xxs) {
                        ForEach(events) { event in
                            childRow(event)
                        }
                    }
                }
            )
            .padding(.vertical, DesignTokens.Spacing.xxs)
        }
        .frame(minHeight: 44)
    }

    private func childRow(_ event: WorkstreamTimelineEvent) -> some View {
        SelectableRow(isSelected: event.id == selectedEventID, action: { onSelectEvent(event.id) }) {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
                Circle()
                    .fill(event.severity.tone.color)
                    .frame(width: 6, height: 6)
                    .padding(.top, DesignTokens.Spacing.xs)
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                    Text(event.title)
                        .font(OverlayType.callout)
                        .foregroundStyle(OverlayPalette.textPrimary)
                        .lineLimit(1)
                    Text(event.summary)
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: DesignTokens.Spacing.xs)
                Text(TimelineTimeFormatter.clock(event.timestamp))
                    .font(OverlayType.monoMicro)
                    .foregroundStyle(OverlayPalette.textTertiary)
            }
        }
    }
}

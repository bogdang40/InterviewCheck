import SwiftUI

/// Every timeline event of the session in order, with its clock stamp.
struct ReplayTimelineSection: View {
    let events: [WorkstreamTimelineEvent]

    @State private var isExpanded = false

    var body: some View {
        DisclosureCard("All recorded events", systemImage: "timeline.selection", count: events.count, isExpanded: $isExpanded) {
            if events.isEmpty {
                Text("No events were recorded for this session.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                        row(event)
                        if index < events.count - 1 {
                            Hairline()
                        }
                    }
                }
            }
        }
    }

    private func row(_ event: WorkstreamTimelineEvent) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Text(ReplayPresentation.timeLabel(event.timestamp))
                .font(OverlayType.monoMicro)
                .foregroundStyle(OverlayPalette.textTertiary)
                .frame(width: 72, alignment: .leading)
            Circle()
                .fill(event.severity.tone.color)
                .frame(width: 6, height: 6)
                .padding(.top, DesignTokens.Spacing.xs)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(event.title)
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                Text(event.summary)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(OverlayType.monoMicro)
                        .foregroundStyle(OverlayPalette.textTertiary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}

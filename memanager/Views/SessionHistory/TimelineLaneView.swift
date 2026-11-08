import SwiftUI

/// The vertical lane: one node per event, clusters folded into disclosure
/// rows, every node carrying its severity tone on the spine and the card
/// edge so the lane can be scanned for trouble.
struct TimelineLaneView: View {
    let items: [TimelineDisplayItem]
    let selectedEventID: String?
    let onSelect: (String) -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                node(for: item, isFirst: index == 0, isLast: index == items.count - 1)
            }
        }
    }

    @ViewBuilder
    private func node(for item: TimelineDisplayItem, isFirst: Bool, isLast: Bool) -> some View {
        switch item {
        case .single(let event):
            TimelineLaneNodeView(
                event: event,
                isFirst: isFirst,
                isLast: isLast,
                isSelected: event.id == selectedEventID,
                onSelect: { onSelect(event.id) }
            )
        case .cluster(_, let events, let timestamp, let severity):
            TimelineClusterNodeView(
                events: events,
                dominantSeverity: severity,
                timestamp: timestamp,
                isFirst: isFirst,
                isLast: isLast,
                selectedEventID: selectedEventID,
                onSelectEvent: onSelect
            )
        }
    }
}

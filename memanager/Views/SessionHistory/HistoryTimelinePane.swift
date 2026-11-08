import SwiftUI

/// Timeline of the selected session: search and type chips on top, the
/// lane with clustered nodes, then the selected event, its turn deep dive,
/// and thread compare folded away at the bottom.
struct HistoryTimelinePane: View {
    @ObservedObject private var controller = SessionController.shared
    @Binding var searchQuery: String
    @Binding var selectedThreadId: String?
    let availableThreads: [QuickAssistThreadSummary]
    let selectedEvent: WorkstreamTimelineEvent?

    @State private var enabledTypes: Set<WorkstreamEventType> = Set(WorkstreamEventType.allCases)

    private var filteredEvents: [WorkstreamTimelineEvent] {
        controller.workstreamTimelineEvents.filter { enabledTypes.contains($0.type) }
    }

    private var displayItems: [TimelineDisplayItem] {
        TimelineClusterEngine().cluster(events: filteredEvents)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SurfaceHeader("Timeline", systemImage: "timeline.selection", count: controller.workstreamTimelineEvents.count, prominence: .heading) {
                    TimelineThreadFilterMenu(selectedThreadId: $selectedThreadId, threads: availableThreads)
                }
                OverlaySearchField(placeholder: "Search events", text: $searchQuery)
                TimelineFilterChipBar(enabledTypes: $enabledTypes)
                lane
                detail
                CompareCard(availableThreads: availableThreads)
            }
            .padding(DesignTokens.Spacing.md)
        }
    }

    @ViewBuilder
    private var lane: some View {
        if controller.workstreamTimelineEvents.isEmpty {
            OverlayEmptyState(
                systemImage: "timeline.selection",
                title: "No events yet",
                message: "Events appear here as you work with Quick Assist during a session."
            )
        } else if displayItems.isEmpty {
            ToneBanner(tone: .neutral, message: "No events match the current search and type filters.")
        } else {
            TimelineLaneView(
                items: displayItems,
                selectedEventID: controller.selectedWorkstreamTimelineEventID
            ) { id in
                controller.selectedWorkstreamTimelineEventID = id
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let event = selectedEvent {
            SessionEventDetailCard(event: event, selectedThreadId: $selectedThreadId)
            if event.type == .quickAssist, event.threadId != nil, event.turnId != nil {
                TurnDeepDiveCard(event: event)
            }
        } else if !controller.workstreamTimelineEvents.isEmpty {
            ToneBanner(tone: .neutral, message: "Select an event to inspect it, open it, or branch a thread from it.", systemImage: "cursorarrow.click.2")
        }
    }
}

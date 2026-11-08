import SwiftUI

/// The segment strip that switches History panes. Icons drop away in the
/// stacked layout so all five titles fit the narrow column.
struct HistoryPaneStrip: View {
    let panes: [HistoryPane]
    @Binding var selection: HistoryPane
    var showsIcons: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            SegmentStrip(
                items: panes.map { SegmentItem(id: $0, title: $0.title, systemImage: showsIcons ? $0.systemImage : nil) },
                selection: $selection
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }
}

/// Mounts the view for a History pane. The session list is composed by the
/// screen itself, so this host only knows the detail panes.
struct HistoryPaneHost: View {
    let pane: HistoryPane
    let selectedSessionId: String?
    @Binding var selectedThreadId: String?
    @Binding var timelineQuery: String
    let providerStats: [ProviderStatsRecord]
    let availableThreads: [QuickAssistThreadSummary]
    let selectedEvent: WorkstreamTimelineEvent?
    @State private var visited: Set<HistoryPane> = []

    var body: some View {
        ZStack {
            ForEach(HistoryPane.allCases.filter { $0 != .sessions && (visited.contains($0) || $0 == pane) }) { item in
                content(for: item)
                    .opacity(item == pane ? 1 : 0)
                    .allowsHitTesting(item == pane)
                    .disabled(item != pane)
                    .accessibilityHidden(item != pane)
            }
        }
        .onAppear { visited.insert(pane) }
        .onChange(of: pane) { _, newValue in visited.insert(newValue) }
    }

    @ViewBuilder
    private func content(for selected: HistoryPane) -> some View {
        switch selected {
        case .sessions:
            EmptyView()
        case .overview:
            HistoryOverviewPane(sessionID: selectedSessionId, providerStats: providerStats)
        case .timeline:
            HistoryTimelinePane(
                searchQuery: $timelineQuery,
                selectedThreadId: $selectedThreadId,
                availableThreads: availableThreads,
                selectedEvent: selectedEvent
            )
        case .replay:
            SessionReplayStudioView(sessionID: selectedSessionId)
        case .debrief:
            DebriefDetailPane(selectedSessionId: selectedSessionId)
        }
    }
}

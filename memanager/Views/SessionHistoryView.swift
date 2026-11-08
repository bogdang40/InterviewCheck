import SwiftUI

/// History screen: past sessions on the left, the selected session's
/// overview, timeline, replay, and debrief on the right. Below the compact
/// breakpoint the list becomes one more pane behind the segment strip.
struct SessionHistoryView: View {
    @ObservedObject private var controller = SessionController.shared

    @State private var sessions: [SessionRecord] = []
    @State private var providerStats: [ProviderStatsRecord] = []
    @State private var selectedSessionId: String?
    @State private var selectedThreadId: String?
    @State private var timelineQuery: String = ""
    @State private var includeDebugEvents = true
    @State private var isLoading = false
    @State private var activePane: HistoryPane = .overview
    @State private var listResolver = SessionListResolver()
    @State private var masterPane: MasterDetailPane = .list
    @State private var didStart = false
    @State private var loadRequestID = UUID()
    @State private var sessionLimit = 120
    @State private var totalSessionCount = 0
    @State private var emptySessionCount = 0
    @State private var emptySessionIDs: Set<String> = []
    @State private var includeEmptySessions = false
    @State private var historyLoadError: String?

    @State private var pendingDeletion: [SessionRecord] = []
    @State private var batchSelection = HistoryBatchSelection()
    @State private var showDeletionConfirmation = false
    @State private var deletionError: String?

    private let dataSource = SessionHistoryDataSource()

    private var availableThreads: [QuickAssistThreadSummary] {
        SessionHistoryTimelineFilter.availableThreads(controller.quickAssistThreadSummaries, sessionId: selectedSessionId)
    }

    private var selectedEvent: WorkstreamTimelineEvent? {
        guard let id = controller.selectedWorkstreamTimelineEventID else { return nil }
        return controller.workstreamTimelineEvents.first { $0.id == id }
    }

    var body: some View {
        GeometryReader { geometry in
            OverlayMasterDetail(width: geometry.size.width, pane: $masterPane, listTitle: "Sessions", detailTitle: "Selected session") {
                sessionList(onSelect: { _ in masterPane = .detail })
            } detail: {
                SessionHistoryRightPane(panes: HistoryPane.allCases.filter { $0 != .sessions }, activePane: $activePane, hasSelection: selectedSessionId != nil) {
                    paneHost(for: activePane)
                }
            }
        }
        .alert(pendingDeletion.count == 1 ? "Delete session?" : "Delete \(pendingDeletion.count) sessions?", isPresented: $showDeletionConfirmation) {
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
            Button("Delete", role: .destructive) { deleteSessions() }
        } message: {
            Text("The selected \(pendingDeletion.count == 1 ? "session" : "sessions") and their transcripts, answers, replay and summaries will be permanently deleted. Saved practice cards, workspaces and Knowledge stay available.")
        }
        .alert("Could not delete session", isPresented: Binding(
            get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK") { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
        }
        .onAppear(perform: start)
        .onChange(of: selectedSessionId) { _, _ in sessionChanged() }
        .onChange(of: selectedThreadId) { _, _ in applyTimelineFilter() }
        .onChange(of: timelineQuery) { _, _ in applyTimelineFilter() }
        .onChange(of: includeEmptySessions) { _, _ in
            sessionLimit = 120
            batchSelection.finish()
            loadData()
        }
    }

    private func sessionList(onSelect: ((String) -> Void)?) -> some View {
        SessionHistoryLeftPane(
            sessions: sessions,
            resolver: $listResolver,
            selectedSessionId: $selectedSessionId,
            metadataMap: controller.sessionCardMetadataMap,
            isLoading: isLoading,
            onRefresh: refresh,
            onSelect: onSelect,
            activeSessionID: controller.activeHistorySessionID,
            deletionUnavailableReason: controller.sessionDeletionUnavailableReason,
            onDelete: { pendingDeletion = [$0]; showDeletionConfirmation = true },
            batchSelection: $batchSelection,
            onDeleteSelected: { ids in
                pendingDeletion = sessions.filter { ids.contains($0.id) }
                showDeletionConfirmation = !pendingDeletion.isEmpty
            },
            totalSessionCount: totalSessionCount,
            emptySessionCount: emptySessionCount,
            emptySessionIDs: emptySessionIDs,
            includeEmptySessions: $includeEmptySessions,
            loadError: historyLoadError,
            onLoadMore: { sessionLimit += 120; loadData() }
        )
    }

    private func paneHost(for pane: HistoryPane) -> some View {
        HistoryPaneHost(
            pane: pane,
            selectedSessionId: selectedSessionId,
            selectedThreadId: $selectedThreadId,
            timelineQuery: $timelineQuery,
            providerStats: providerStats,
            availableThreads: availableThreads,
            selectedEvent: selectedEvent
        )
    }

    // MARK: Lifecycle

    private func start() {
        guard !didStart else { return }
        didStart = true
        loadData()
        controller.refreshQuickAssistThreads(selectThreadID: controller.activeQuickAssistThreadID)
        let filter = controller.workstreamTimelineFilter
        selectedSessionId = filter.sessionId
        selectedThreadId = filter.threadId
        timelineQuery = filter.searchQuery
        includeDebugEvents = filter.includeDebugEvents
        applyTimelineFilter()
        loadSelectedSessionDetails()
    }

    private func deleteSessions() {
        let ids = Set(pendingDeletion.map(\.id))
        guard !ids.isEmpty else { return }
        let visible = listResolver.apply(to: sessions, metadata: controller.sessionCardMetadataMap)
        pendingDeletion = []
        do {
            try controller.deleteHistorySessions(ids: ids)
            loadRequestID = UUID()
            selectedSessionId = SessionListResolver.selectionAfterDeleting(
                ids, selectedID: selectedSessionId, visibleIDs: visible.map(\.id)
            )
            sessions.removeAll { ids.contains($0.id) }
            batchSelection.finish()
            if selectedSessionId == nil { masterPane = .list }
            sessionChanged()
            loadData(selectFirstIfNeeded: false)
        } catch {
            deletionError = error.localizedDescription
        }
    }

    private func refresh() {
        loadData()
        controller.refreshQuickAssistThreads(selectThreadID: controller.activeQuickAssistThreadID)
        controller.refreshWorkstreamTimeline()
    }

    private func sessionChanged() {
        if !SessionHistoryTimelineFilter.threadSelectionSurvives(threadId: selectedThreadId, in: availableThreads) {
            selectedThreadId = nil
        }
        loadSelectedSessionDetails()
        applyTimelineFilter()
    }

    private func loadSelectedSessionDetails() {
        guard let selectedSessionId else {
            controller.selectedReviewSessionID = nil
            controller.currentSessionDebrief = nil
            controller.currentSessionMetrics = nil
            return
        }
        controller.loadSessionDebrief(sessionID: selectedSessionId)
        controller.loadSessionAnalytics(sessionID: selectedSessionId)
    }

    private func applyTimelineFilter() {
        controller.workstreamTimelineFilter = SessionHistoryTimelineFilter.filter(
            base: controller.workstreamTimelineFilter,
            sessionId: selectedSessionId,
            threadId: selectedThreadId,
            query: timelineQuery,
            includeDebugEvents: includeDebugEvents
        )
        controller.refreshWorkstreamTimeline()
    }

    private func loadData(selectFirstIfNeeded: Bool = true) {
        controller.invalidateSessionCardMetadata()
        let requestID = UUID()
        loadRequestID = requestID
        isLoading = true
        dataSource.load(limit: sessionLimit, includeEmpty: includeEmptySessions) { result in
            guard requestID == loadRequestID else { return }
            isLoading = false
            guard case .success(let (page, loadedStats)) = result else {
                if case .failure(let error) = result { historyLoadError = error.localizedDescription }
                return
            }
            historyLoadError = nil
            let loadedSessions = page.sessions
            totalSessionCount = page.totalCount
            emptySessionCount = page.emptyCount
            emptySessionIDs = page.emptySessionIDs
            sessions = loadedSessions
            providerStats = loadedStats
            if let selectedSessionId, !loadedSessions.contains(where: { $0.id == selectedSessionId }) {
                self.selectedSessionId = nil
            }
            if selectedSessionId == nil && selectFirstIfNeeded {
                selectedSessionId = listResolver.apply(to: loadedSessions, metadata: controller.sessionCardMetadataMap).first?.id
            }
            controller.loadSessionCardMetadata(sessions: loadedSessions)
        }
    }
}

#if DEBUG && XCODE_RUNNING_FOR_PREVIEWS
#Preview {
    SessionHistoryView()
        .frame(width: 720, height: 640)
}
#endif

import SwiftUI

/// Binds the threads panel to the session controller: filters, search
/// focus, selection, and the delete flow.
struct QuickAssistHistorySidebar: View {
    @ObservedObject private var controller = SessionController.shared
    @State private var batchSelection = HistoryBatchSelection()
    @State private var deletionError: String?
    @State private var deletionConfirmation: ThreadHistoryDeletionConfirmation?
    @State private var activeFilters: Set<SidebarThreadFilter> = []
    @Binding private var searchFocusRequested: Bool
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isSearchFocused: Bool

    init(searchFocusRequested: Binding<Bool> = .constant(false)) {
        _searchFocusRequested = searchFocusRequested
    }

    private var visibleSummaries: [QuickAssistThreadSummary] {
        SidebarThreadFilter.apply(
            filters: activeFilters,
            to: controller.filteredQuickAssistThreadSummaries(),
            metadataMap: controller.threadCardMetadataMap
        )
    }

    private var selectedOrActiveThreadID: String? {
        controller.quickAssistSelectedHistoryThreadID ?? controller.activeQuickAssistThreadID
    }

    private var visibleThreadIDs: Set<String> {
        Set(visibleSummaries.map(\.id))
    }

    private var loadedThreadIDs: Set<String> {
        Set(controller.quickAssistThreadSummaries.map(\.id))
    }

    private var model: QuickAssistThreadsPanelModel {
        let visible = visibleSummaries
        let query = controller.quickAssistHistorySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return QuickAssistThreadsPanelModel(
            groups: ThreadDateGroup.group(visible),
            totalCount: controller.quickAssistThreadSummaries.count,
            visibleCount: visible.count,
            isFiltered: !query.isEmpty || !activeFilters.isEmpty,
            selectedThreadID: controller.quickAssistSelectedHistoryThreadID,
            activeThreadID: controller.activeQuickAssistThreadID,
            pendingDeletionThreadID: controller.quickAssistPendingDeletionThreadID,
            metadataMap: controller.threadCardMetadataMap,
            deleteAction: deletionConfirmation?.action
        )
    }

    private var actions: QuickAssistThreadsPanelActions {
        QuickAssistThreadsPanelActions(
            onRefresh: { refresh() },
            onDeleteAll: requestAllThreadDeletion,
            onOpenSelected: { controller.openSelectedQuickAssistHistoryThread() },
            onInspectSelected: {
                guard let id = selectedOrActiveThreadID else { return }
                controller.inspectThreadInTimeline(threadID: id)
            },
            onNewThread: { controller.createNewQuickAssistThread() },
            onSelect: { summary in
                controller.quickAssistSelectedHistoryThreadID = summary.id
                controller.openQuickAssistThread(threadID: summary.id, showQuickAssistView: true)
            },
            onDelete: { summary in deletionConfirmation = .thread(summary) },
            onInspect: { summary in controller.inspectThreadInTimeline(threadID: summary.id) },
            onConfirmDelete: { performDelete() },
            onCancelDelete: { deletionConfirmation = nil }
        )
    }

    var body: some View {
        QuickAssistThreadsPanel(
            model: model,
            actions: actions,
            searchText: $controller.quickAssistHistorySearchQuery,
            searchFocus: $isSearchFocused,
            activeFilters: $activeFilters,
            batchSelection: $batchSelection,
            deletionEnabled: !controller.isQuickAssistLoading,
            onDeleteSelected: { ids in
                let selected = visibleSummaries.filter { ids.contains($0.id) }
                guard let confirmation = HistoryBatchDeletionConfirmation(
                    selectedIDs: Set(selected.map(\.id)), visibleIDs: visibleThreadIDs
                ) else { return }
                deletionConfirmation = .threads(selected, confirmation)
            }
        )
        .alert("Could not delete threads", isPresented: Binding(
            get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }
        )) {
            Button("OK") { deletionError = nil }
        } message: {
            Text(deletionError ?? "")
        }
        .onAppear {
            refresh()
            handleSearchFocusRequest()
        }
        .onChange(of: controller.isQuickAssistLoading) { wasLoading, isLoadingNow in
            cancelInvalidConfirmation()
            if wasLoading && !isLoadingNow { refresh() }
        }
        .onChange(of: batchSelection) { _, _ in cancelInvalidConfirmation() }
        .onChange(of: visibleThreadIDs) { _, _ in cancelInvalidConfirmation() }
        .onChange(of: loadedThreadIDs) { _, _ in cancelInvalidConfirmation() }
        .onChange(of: searchFocusRequested) { _, _ in handleSearchFocusRequest() }
        .onChange(of: isEnabled) { _, active in
            if active { handleSearchFocusRequest() }
            else { isSearchFocused = false }
        }
        .onDisappear { isSearchFocused = false }
        .onExitCommand { deletionConfirmation = nil }
    }

    private func refresh() {
        controller.refreshQuickAssistThreads(selectThreadID: controller.activeQuickAssistThreadID)
    }

    private func handleSearchFocusRequest() {
        guard isEnabled, searchFocusRequested else { return }
        searchFocusRequested = false
        isSearchFocused = true
    }

    private func performDelete() {
        switch deletionConfirmation {
        case .thread(let summary): controller.deleteQuickAssistThread(threadID: summary.id)
        case .allThreads, .threads:
            do {
                // Revalidate before mutation even if SwiftUI has not delivered
                // onChange yet. Delete only captured IDs, never a newer thread.
                guard let ids = try validatedDeletionIDs() else {
                    deletionConfirmation = nil
                    return
                }
                try controller.deleteQuickAssistThreads(ids: ids)
                batchSelection.finish()
            } catch {
                deletionError = error.localizedDescription
            }
        case nil: break
        }
        deletionConfirmation = nil
    }

    private func requestAllThreadDeletion() {
        deletionConfirmation = nil
        do {
            let ids = try controller.logger.database.getQuickAssistThreadIDs()
            guard let confirmation = HistoryBatchDeletionConfirmation(allIDs: ids) else { return }
            deletionConfirmation = .allThreads(confirmation)
        } catch {
            deletionError = error.localizedDescription
        }
    }

    private func validatedDeletionIDs() throws -> Set<String>? {
        guard !controller.isQuickAssistLoading else { return nil }
        switch deletionConfirmation {
        case .threads(_, let confirmation):
            return confirmation.validatedIDs(
                selection: batchSelection, visibleIDs: visibleThreadIDs, deletionEnabled: true
            )
        case .allThreads(let confirmation):
            return confirmation.validatedAllIDs(
                currentIDs: try controller.logger.database.getQuickAssistThreadIDs(), deletionEnabled: true
            )
        default: return nil
        }
    }

    private func cancelInvalidConfirmation() {
        switch deletionConfirmation {
        case .allThreads, .threads:
            do {
                if try validatedDeletionIDs() == nil { deletionConfirmation = nil }
            } catch {
                deletionConfirmation = nil
                deletionError = error.localizedDescription
            }
        default: break
        }
    }
}

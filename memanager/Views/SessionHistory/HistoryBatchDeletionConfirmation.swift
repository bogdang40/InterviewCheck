import Foundation

/// A destructive confirmation belongs to one visible selection. An inline
/// banner must not remain actionable after the user edits that selection.
struct HistoryBatchDeletionConfirmation {
    private enum Scope {
        case selection(visibleIDs: Set<String>)
        case all
    }

    let selectedIDs: Set<String>
    private let scope: Scope

    init?(selectedIDs: Set<String>, visibleIDs: Set<String>) {
        guard !selectedIDs.isEmpty, selectedIDs.isSubset(of: visibleIDs) else { return nil }
        self.selectedIDs = selectedIDs
        scope = .selection(visibleIDs: visibleIDs)
    }

    init?(allIDs: Set<String>) {
        guard !allIDs.isEmpty else { return nil }
        selectedIDs = allIDs
        scope = .all
    }

    func validatedIDs(
        selection: HistoryBatchSelection,
        visibleIDs: Set<String>,
        deletionEnabled: Bool
    ) -> Set<String>? {
        guard case .selection(let capturedVisibleIDs) = scope,
              deletionEnabled, selection.isSelecting,
              selection.ids == selectedIDs, visibleIDs == capturedVisibleIDs else { return nil }
        return selectedIDs
    }

    func validatedAllIDs(currentIDs: Set<String>, deletionEnabled: Bool) -> Set<String>? {
        guard case .all = scope, deletionEnabled, currentIDs == selectedIDs else { return nil }
        return selectedIDs
    }
}

/// Keep the banner and its deletion scope in the same state value.
enum ThreadHistoryDeletionConfirmation {
    case thread(QuickAssistThreadSummary)
    case allThreads(HistoryBatchDeletionConfirmation)
    case threads([QuickAssistThreadSummary], HistoryBatchDeletionConfirmation)

    var action: SidebarDeleteAction {
        switch self {
        case .thread(let summary): return .thread(summary)
        case .allThreads(let confirmation): return .allThreads(count: confirmation.selectedIDs.count)
        case .threads(let summaries, _): return .threads(summaries)
        }
    }
}

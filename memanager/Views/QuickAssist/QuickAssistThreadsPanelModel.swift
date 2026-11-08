import Foundation

/// Everything the threads panel renders, built by the sidebar from the
/// controller so the panel itself stays free of singletons.
struct QuickAssistThreadsPanelModel {
    let groups: [ThreadDateGroup]
    let totalCount: Int
    let visibleCount: Int
    let isFiltered: Bool
    let selectedThreadID: String?
    let activeThreadID: String?
    let pendingDeletionThreadID: String?
    let metadataMap: [String: ThreadCardMetadata]
    let deleteAction: SidebarDeleteAction?

    var hasAnyThreads: Bool { totalCount > 0 }

    var hasSelection: Bool {
        selectedThreadID != nil || activeThreadID != nil
    }

    var subtitle: String? {
        guard isFiltered else { return nil }
        return "\(visibleCount) of \(totalCount) shown"
    }

    func row(for summary: QuickAssistThreadSummary) -> QuickAssistThreadRowModel {
        let isActive = summary.id == activeThreadID
        let isSelected = summary.id == selectedThreadID || (selectedThreadID == nil && isActive)
        return QuickAssistThreadRowModel(
            summary: summary,
            metadata: metadataMap[summary.id],
            isSelected: isSelected,
            isActive: isActive,
            isPendingDeletion: summary.id == pendingDeletionThreadID
        )
    }
}

/// Every action the threads panel can trigger.
struct QuickAssistThreadsPanelActions {
    let onRefresh: () -> Void
    let onDeleteAll: () -> Void
    let onOpenSelected: () -> Void
    let onInspectSelected: () -> Void
    let onNewThread: () -> Void
    let onSelect: (QuickAssistThreadSummary) -> Void
    let onDelete: (QuickAssistThreadSummary) -> Void
    let onInspect: (QuickAssistThreadSummary) -> Void
    let onConfirmDelete: () -> Void
    let onCancelDelete: () -> Void
}

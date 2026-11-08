import SwiftUI

/// The Threads tab of the drawer: header with count and menu, search,
/// filter chips, and the grouped list. Delete confirmations render inline
/// as a critical banner instead of a modal.
struct QuickAssistThreadsPanel: View {
    let model: QuickAssistThreadsPanelModel
    let actions: QuickAssistThreadsPanelActions
    @Binding var searchText: String
    let searchFocus: FocusState<Bool>.Binding
    @Binding var activeFilters: Set<SidebarThreadFilter>

    @Binding var batchSelection: HistoryBatchSelection
    var deletionEnabled = true
    var onDeleteSelected: (Set<String>) -> Void = { _ in }

    private var eligibleIDs: Set<String> {
        deletionEnabled ? Set(model.groups.flatMap(\.threads).map(\.id)) : []
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: DesignTokens.Spacing.sm) {
                SurfaceHeader("Threads", subtitle: model.subtitle, count: model.totalCount, prominence: .heading) {
                    Button(action: actions.onNewThread) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.overlayIcon(size: 22, bordered: false))
                    .help("New thread")
                    menu
                }
                OverlaySearchField(placeholder: "Search threads", text: $searchText, focus: searchFocus)
                SidebarThreadFilterBar(activeFilters: $activeFilters)
                HistoryBatchSelectionBar(
                    selection: $batchSelection,
                    eligibleIDs: eligibleIDs,
                    emptyIDs: Set(model.groups.flatMap(\.threads).filter { !$0.hasRecordedCalls }.map(\.id)),
                    onDelete: onDeleteSelected
                )
            }
            .padding(DesignTokens.Spacing.sm)

            Hairline()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        if let deleteAction = model.deleteAction {
                            SidebarDeleteConfirmationBanner(
                                action: deleteAction,
                                onCancel: actions.onCancelDelete,
                                onConfirm: actions.onConfirmDelete
                            )
                            .padding(.horizontal, DesignTokens.Spacing.sm)
                            .id("delete-confirmation")
                        }
                        if model.groups.isEmpty {
                            emptyState
                        } else {
                            SidebarThreadGroupedList(
                                groups: model.groups,
                                rowModel: model.row(for:),
                                onSelect: actions.onSelect,
                                onDelete: actions.onDelete,
                                onInspect: actions.onInspect,
                                batchSelection: $batchSelection,
                                eligibleIDs: eligibleIDs
                            )
                        }
                    }
                    .padding(.vertical, DesignTokens.Spacing.sm)
                }
                .onChange(of: model.deleteAction?.title) { _, title in
                    if title != nil { proxy.scrollTo("delete-confirmation", anchor: .top) }
                }
            }
        }
    }

    private var menu: some View {
        Menu {
            Button("Refresh", systemImage: "arrow.clockwise", action: actions.onRefresh)
            Button("Open selected thread", systemImage: "arrow.up.right.square", action: actions.onOpenSelected)
                .disabled(!model.hasSelection)
            Button("Inspect in timeline", systemImage: "clock.arrow.circlepath", action: actions.onInspectSelected)
                .disabled(!model.hasSelection)
            Divider()
            Button("Delete all threads", systemImage: "trash", role: .destructive, action: actions.onDeleteAll)
                .disabled(!model.hasAnyThreads)
        } label: {
            OverlayIconMenuLabel(systemImage: "ellipsis", size: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.hasAnyThreads {
            OverlayCompactEmptyState(
                systemImage: "magnifyingglass",
                title: "No matching threads",
                message: "Try another search or clear the filters."
            )
        } else {
            OverlayCompactEmptyState(
                systemImage: "bubble.left.and.text.bubble.right",
                title: "No threads yet",
                message: "Generate an answer to start the first thread.",
                action: EmptyStateAction(title: "New thread", action: actions.onNewThread)
            )
        }
    }
}

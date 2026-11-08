import SwiftUI

/// The running log for a job: auto recorded problems plus manual notes,
/// folded into one disclosure card.
struct WorkspaceJournalSection: View {
    let entries: [WorkspaceJournalEntry]
    let onAdd: () -> Void
    let onDelete: (WorkspaceJournalEntry) -> Void

    @State private var isExpanded = true
    @State private var expandedIDs: Set<UUID> = []
    @State private var pendingRemoval: WorkspaceJournalEntry?

    var body: some View {
        DisclosureCard("Journal", systemImage: "book.closed", count: entries.count, isExpanded: $isExpanded) {
            Button("Add entry", action: onAdd)
                .buttonStyle(.overlay(.secondary, size: .small))
        } content: {
            if entries.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Hairline()
                        }
                        WorkspaceJournalRow(
                            entry: entry,
                            isExpanded: expandedIDs.contains(entry.id),
                            onToggle: { toggle(entry.id) },
                            onDelete: { pendingRemoval = entry }
                        )
                    }
                }
            }
        }
        .confirmationDialog("Remove journal entry?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Remove entry", role: .destructive) {
                if let entry = pendingRemoval { onDelete(entry) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Remove \(pendingRemoval?.title ?? "this entry") from the app journal. Any existing Markdown copy in the workspace folder is retained.")
        }
    }

    private var emptyState: some View {
        OverlayCompactEmptyState(
            systemImage: "book.closed",
            title: "Nothing journaled yet",
            message: "Problems you work through with Quick Assist while this workspace is active land here automatically and feed the next turn.",
            action: EmptyStateAction(title: "Add entry", action: onAdd)
        )
    }

    private func toggle(_ id: UUID) {
        withAnimation(DesignTokens.Motion.sectionExpand) {
            if expandedIDs.contains(id) {
                expandedIDs.remove(id)
            } else {
                expandedIDs.insert(id)
            }
        }
    }
}

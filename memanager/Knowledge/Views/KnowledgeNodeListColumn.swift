import SwiftUI

/// The fact list: a header with the graph size and the two ways to add
/// facts, search, a kind filter, then one selectable row per fact.
struct KnowledgeNodeListColumn: View {
    @ObservedObject var store: KnowledgeGraphStore
    let onSelect: (UUID) -> Void
    let onAdd: () -> Void
    let onExtract: () -> Void
    var onOverview: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: DesignTokens.Spacing.sm) {
                SurfaceHeader("Knowledge", count: store.counts.nodes) {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.overlayIcon)
                    .help("Add a fact by hand")
                    Button(action: onExtract) {
                        Image(systemName: "text.badge.plus")
                    }
                    .buttonStyle(.overlayIcon)
                    .help("Extract facts from pasted text")
                }
                OverlaySearchField(placeholder: "Search facts", text: $store.searchText)
                HStack(spacing: DesignTokens.Spacing.sm) {
                    KnowledgeKindFilterMenu(selection: $store.kindFilter)
                    Spacer(minLength: 0)
                    if store.isExtracting {
                        ProgressCaption(text: "Extracting")
                    }
                }
                Button("Retrieval settings and overview", systemImage: "slider.horizontal.3", action: onOverview)
                    .buttonStyle(.overlay(.secondary, size: .small))
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            Hairline()
            if store.nodes.isEmpty {
                emptyState
                    .padding(.top, DesignTokens.Spacing.lg)
                Spacer(minLength: 0)
            } else {
                list
            }
        }
        .background(OverlayPalette.surface)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Spacing.xxs) {
                ForEach(store.nodes) { node in
                    SelectableRow(isSelected: store.selectedNodeID == node.id, action: { onSelect(node.id) }) {
                        KnowledgeNodeRow(node: node)
                    }
                }
            }
            .padding(DesignTokens.Spacing.sm)
        }
    }

    private var isFiltering: Bool {
        !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty || store.kindFilter != nil
    }

    @ViewBuilder
    private var emptyState: some View {
        if isFiltering {
            OverlayCompactEmptyState(
                systemImage: "magnifyingglass",
                title: "No matches",
                message: "Try another word or clear the kind filter.",
                action: EmptyStateAction(title: "Clear filters", action: clearFilters)
            )
        } else {
            OverlayCompactEmptyState(
                systemImage: "point.3.connected.trianglepath.dotted",
                title: "No facts yet",
                message: "Add one by hand, or paste a resume section and let the model extract them.",
                action: EmptyStateAction(title: "Add fact", action: onAdd)
            )
        }
    }

    private func clearFilters() {
        store.searchText = ""
        store.kindFilter = nil
    }
}

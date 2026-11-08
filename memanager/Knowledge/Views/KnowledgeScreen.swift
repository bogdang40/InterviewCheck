import SwiftUI

/// Overlay screen for the personal knowledge graph: search and browse in
/// the list, the selected fact with its neighborhood in the detail, and the
/// graph overview when nothing is selected.
struct KnowledgeScreen: View {
    @ObservedObject private var store = KnowledgeGraphStore.shared
    @ObservedObject private var settings = SettingsManager.shared
    @State private var pane: MasterDetailPane = .list
    @State private var isEditorPresented = false
    @State private var editingNode: KnowledgeNode?
    @State private var isExtractSheetPresented = false
    @State private var isClearConfirmationPresented = false
    @State private var pendingNodeDeletion: KnowledgeNode?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            OverlayMasterDetail(width: width, pane: $pane, listTitle: "Facts", detailTitle: "Detail") {
                KnowledgeNodeListColumn(
                    store: store,
                    onSelect: { id in
                        store.select(id)
                        pane = MasterDetailLayoutResolver.pane(afterSelectionIn: width, current: pane)
                    },
                    onAdd: presentNewFact,
                    onExtract: { isExtractSheetPresented = true },
                    onOverview: { store.select(nil); pane = .detail }
                )
            } detail: {
                detail(width: width)
            }
        }
        .onAppear { store.refresh() }
        .sheet(isPresented: $isEditorPresented) {
            KnowledgeNodeEditorSheet(node: editingNode) { node in try store.saveForEditing(node) }
        }
        .sheet(isPresented: $isExtractSheetPresented) {
            KnowledgeExtractSheet(store: store)
        }
        .confirmationDialog("Clear the whole knowledge graph?", isPresented: $isClearConfirmationPresented, titleVisibility: .visible) {
            Button("Clear everything", role: .destructive) { store.clearGraph() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every fact and relation is removed. Quick Assist keeps working without the graph.")
        }
        .confirmationDialog("Delete \(pendingNodeDeletion?.label ?? "this fact")?", isPresented: Binding(get: { pendingNodeDeletion != nil }, set: { if !$0 { pendingNodeDeletion = nil } }), titleVisibility: .visible) {
            Button("Delete fact and its relations", role: .destructive) {
                if let node = pendingNodeDeletion { store.deleteNode(node.id) }
                pendingNodeDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingNodeDeletion = nil }
        } message: {
            Text("The selected fact and its relations will be removed. Source files and other facts remain.")
        }
    }

    @ViewBuilder
    private func detail(width: CGFloat) -> some View {
        if let node = store.selectedNode {
            KnowledgeNodeDetailView(
                model: KnowledgeNodeDetailModel(
                    node: node,
                    neighborhood: store.neighborhood,
                    linkCandidates: store.nodes,
                    message: store.lastMessage
                ),
                actions: actions(for: node),
                breakpoint: OverlayLayout.breakpoint(for: width)
            )
            .id(node.id)
        } else {
            KnowledgeOverviewView(
                contextEnabled: $settings.knowledgeContextEnabled,
                autoExtractEnabled: $settings.knowledgeAutoExtractEnabled,
                counts: store.counts,
                message: store.lastMessage,
                width: width,
                onAdd: presentNewFact,
                onExtract: { isExtractSheetPresented = true },
                onClear: { isClearConfirmationPresented = true },
                onDismissMessage: { store.lastMessage = nil }
            )
        }
    }

    private func actions(for node: KnowledgeNode) -> KnowledgeNodeDetailActions {
        KnowledgeNodeDetailActions(
            edit: {
                editingNode = node
                isEditorPresented = true
            },
            delete: { pendingNodeDeletion = node },
            select: { store.select($0) },
            deleteEdge: { store.deleteEdge($0) },
            link: { request in
                guard store.addEdge(from: node.id, to: request.targetID, relation: request.relation, evidence: request.evidence) else {
                    throw KnowledgeEditError.link(store.lastMessage ?? "Choose a different target fact and try again.")
                }
            },
            dismissMessage: { store.lastMessage = nil }
        )
    }

    private func presentNewFact() {
        editingNode = nil
        isEditorPresented = true
    }
}

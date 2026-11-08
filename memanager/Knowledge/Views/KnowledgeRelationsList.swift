import SwiftUI

/// Every relation touching the selected fact, one sentence per row, with a
/// way to walk to the other end or unlink it.
struct KnowledgeRelationsList: View {
    let node: KnowledgeNode
    let graph: KnowledgeSubgraph
    let onNavigate: (UUID) -> Void
    let onDelete: (UUID) -> Void
    @State private var pendingRemoval: KnowledgeEdge?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SurfaceHeader("Relations", systemImage: "link", count: graph.edges.count, prominence: .heading)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
            Hairline()
            if graph.edges.isEmpty {
                OverlayCompactEmptyState(
                    systemImage: "link",
                    title: "Not linked yet",
                    message: "Link this fact to the people, projects, and skills it belongs with so retrieval can walk to them."
                )
            } else {
                ForEach(Array(graph.edges.enumerated()), id: \.element.id) { index, edge in
                    if index > 0 {
                        Hairline()
                    }
                    row(edge)
                }
            }
        }
        .overlayCard(.base)
        .confirmationDialog("Remove relation?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible) {
            Button("Remove relation", role: .destructive) {
                if let edge = pendingRemoval { onDelete(edge.id) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text(pendingRemoval.map { KnowledgeEdgeDescriber.describe($0, in: graph).text } ?? "Both facts will remain in the library.")
        }
    }

    private func row(_ edge: KnowledgeEdge) -> some View {
        let description = KnowledgeEdgeDescriber.describe(edge, in: graph)
        return HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(description.text)
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .lineLimit(2)
                if let evidence = description.evidence {
                    Text(evidence)
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            if let other = edge.neighbor(of: node.id) {
                Button {
                    onNavigate(other)
                } label: {
                    Image(systemName: "arrow.right")
                }
                .buttonStyle(.overlayIcon(size: 22, bordered: false))
                .help("Go to the other fact")
            }
            Button {
                pendingRemoval = edge
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.overlayIcon(size: 22, bordered: false))
            .help("Unlink")
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}

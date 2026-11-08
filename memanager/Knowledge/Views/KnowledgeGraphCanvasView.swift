import SwiftUI

/// Small neighborhood map. Positions come from the deterministic layout so
/// the picture is stable between renders; tapping a node selects it.
struct KnowledgeGraphCanvasView: View {
    let graph: KnowledgeSubgraph
    let centerID: UUID?
    let onSelect: (UUID) -> Void

    /// Layout is quadratic per iteration, so it runs once per graph change
    /// off the main thread instead of inside every body evaluation.
    @State private var positions: [UUID: CGPoint] = [:]

    private struct LayoutKey: Equatable {
        let graph: KnowledgeSubgraph
        let centerID: UUID?
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let points = positions
            ZStack {
                Canvas { context, _ in
                    for edge in graph.edges {
                        guard let from = points[edge.fromNodeID], let to = points[edge.toNodeID] else { continue }
                        drawEdge(edge, from: scaled(from, in: size), to: scaled(to, in: size), in: &context)
                    }
                }
                ForEach(graph.nodes) { node in
                    if let point = points[node.id] {
                        KnowledgeGraphNodeCapsule(node: node, isCenter: node.id == centerID)
                            .position(scaled(point, in: size))
                            .onTapGesture { onSelect(node.id) }
                    }
                }
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .task(id: LayoutKey(graph: graph, centerID: centerID)) {
            let graph = graph
            let centerID = centerID
            let computed = await Task.detached(priority: .userInitiated) {
                KnowledgeGraphLayout.positions(for: graph, pinned: centerID)
            }.value
            // The key changed while this ran; the newer task owns the positions.
            guard !Task.isCancelled else { return }
            positions = computed
        }
    }

    /// Strokes the edge, then sets its relation name on a card colored
    /// backing at the midpoint so the label never sits on the line.
    private func drawEdge(_ edge: KnowledgeEdge, from: CGPoint, to: CGPoint, in context: inout GraphicsContext) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(path, with: .color(OverlayPalette.hairlineStrong), lineWidth: 1 + min(2, edge.weight * 0.6))

        let midpoint = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let label = context.resolve(
            Text(edge.relation.displayName)
                .font(OverlayType.micro)
                .foregroundStyle(OverlayPalette.textTertiary)
        )
        let size = label.measure(in: CGSize(width: Self.labelMeasureWidth, height: Self.labelMeasureWidth))
        let backing = CGRect(
            x: midpoint.x - size.width / 2 - DesignTokens.Spacing.xs,
            y: midpoint.y - size.height / 2 - DesignTokens.Spacing.xxs,
            width: size.width + DesignTokens.Spacing.sm,
            height: size.height + DesignTokens.Spacing.xs
        )
        let backingPath = Path(roundedRect: backing, cornerRadius: DesignTokens.Radius.xs)
        context.fill(backingPath, with: .color(OverlayPalette.canvas))
        context.fill(backingPath, with: .color(OverlayPalette.surface))
        context.draw(label, at: midpoint)
    }

    private static let labelMeasureWidth: CGFloat = 200

    private func scaled(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }
}

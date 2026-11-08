import CoreGraphics
import Foundation

/// Deterministic force directed layout in the unit square. Small graphs
/// (what the detail pane shows) converge in a few dozen iterations, and the
/// seeded start means the same subgraph always lands in the same place.
enum KnowledgeGraphLayout {
    struct Options: Equatable {
        var iterations = 120
        var repulsion = 0.012
        var attraction = 0.9
        var gravity = 0.06
        var cooling = 0.94
        var initialStep = 0.06

        static let `default` = Options()
    }

    static func positions(for graph: KnowledgeSubgraph, pinned: UUID? = nil, options: Options = .default) -> [UUID: CGPoint] {
        let ids = graph.nodes.map(\.id).sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty else { return [:] }
        if ids.count == 1 { return [ids[0]: CGPoint(x: 0.5, y: 0.5)] }

        var points: [UUID: CGPoint] = [:]
        for (index, id) in ids.enumerated() {
            let angle = (Double(index) / Double(ids.count)) * 2 * Double.pi
            let radius = id == pinned ? 0.0 : 0.38
            points[id] = CGPoint(x: 0.5 + cos(angle) * radius, y: 0.5 + sin(angle) * radius)
        }

        var step = options.initialStep
        for _ in 0..<options.iterations {
            var displacement: [UUID: CGVector] = [:]
            for i in 0..<ids.count {
                for j in (i + 1)..<ids.count {
                    let a = ids[i], b = ids[j]
                    let delta = CGVector(dx: points[a]!.x - points[b]!.x, dy: points[a]!.y - points[b]!.y)
                    let distance = max(0.02, hypot(delta.dx, delta.dy))
                    let force = options.repulsion / (distance * distance)
                    let push = CGVector(dx: delta.dx / distance * force, dy: delta.dy / distance * force)
                    displacement[a, default: .zero] += push
                    displacement[b, default: .zero] -= push
                }
            }
            for edge in graph.edges {
                guard let from = points[edge.fromNodeID], let to = points[edge.toNodeID] else { continue }
                let delta = CGVector(dx: to.x - from.x, dy: to.y - from.y)
                let distance = max(0.02, hypot(delta.dx, delta.dy))
                let force = distance * distance * options.attraction * min(1.5, edge.weight)
                let pull = CGVector(dx: delta.dx / distance * force, dy: delta.dy / distance * force)
                displacement[edge.fromNodeID, default: .zero] += pull
                displacement[edge.toNodeID, default: .zero] -= pull
            }
            for id in ids {
                var point = points[id]!
                var move = displacement[id] ?? .zero
                move.dx += (0.5 - point.x) * options.gravity
                move.dy += (0.5 - point.y) * options.gravity
                let magnitude = hypot(move.dx, move.dy)
                if magnitude > step {
                    move = CGVector(dx: move.dx / magnitude * step, dy: move.dy / magnitude * step)
                }
                if id != pinned {
                    point.x = min(0.96, max(0.04, point.x + move.dx))
                    point.y = min(0.96, max(0.04, point.y + move.dy))
                }
                points[id] = point
            }
            step *= options.cooling
        }
        return points
    }
}

private extension CGVector {
    static func += (lhs: inout CGVector, rhs: CGVector) {
        lhs = CGVector(dx: lhs.dx + rhs.dx, dy: lhs.dy + rhs.dy)
    }

    static func -= (lhs: inout CGVector, rhs: CGVector) {
        lhs = CGVector(dx: lhs.dx - rhs.dx, dy: lhs.dy - rhs.dy)
    }
}

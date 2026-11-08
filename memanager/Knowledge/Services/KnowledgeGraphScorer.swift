import Foundation

/// Pure graph expansion and scoring. Seeds come from lexical search; this
/// walks outward a bounded number of hops with geometric decay and folds
/// relation weight, source trust, workspace affinity, and recency into one
/// number per node. No database access, so it is unit tested in isolation.
enum KnowledgeGraphScorer {
    struct Seed: Equatable {
        let nodeID: UUID
        let score: Double
    }

    struct Ranked: Equatable {
        let nodeID: UUID
        let score: Double
        let hops: Int
        let via: UUID?
    }

    struct Policy: Equatable {
        var maxHops: Int = 2
        var hopDecay: Double = 0.55
        var workspaceBoost: Double = 1.3
        var recencyHalfLifeDays: Double = 45
        var mentionBoostCap: Double = 0.25

        static let `default` = Policy()
    }

    /// Expands `seeds` over `edges` and returns every reached node with a
    /// score, highest first. `edges` may contain edges to nodes outside the
    /// seed set; they are followed.
    static func expand(seeds: [Seed], edges: [KnowledgeEdge], policy: Policy = .default) -> [Ranked] {
        var adjacency: [UUID: [KnowledgeEdge]] = [:]
        for edge in edges {
            adjacency[edge.fromNodeID, default: []].append(edge)
            adjacency[edge.toNodeID, default: []].append(edge)
        }

        var best: [UUID: Ranked] = [:]
        var peaks: [UUID: Double] = [:]
        var frontier: [Ranked] = seeds.map { Ranked(nodeID: $0.nodeID, score: $0.score, hops: 0, via: nil) }
        for candidate in frontier { merge(candidate, into: &best, peaks: &peaks) }

        var hop = 0
        while hop < policy.maxHops, !frontier.isEmpty {
            hop += 1
            var next: [Ranked] = []
            for current in frontier {
                for edge in adjacency[current.nodeID] ?? [] {
                    guard let neighbor = edge.neighbor(of: current.nodeID), neighbor != current.via else { continue }
                    let propagated = current.score * policy.hopDecay * edge.relation.traversalWeight * min(1.0, edge.weight)
                    guard propagated > 0.02 else { continue }
                    let candidate = Ranked(nodeID: neighbor, score: propagated, hops: hop, via: current.nodeID)
                    if merge(candidate, into: &best, peaks: &peaks) { next.append(candidate) }
                }
            }
            frontier = next
        }
        return best.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.nodeID.uuidString < rhs.nodeID.uuidString
        }
    }

    /// Applies node level signals on top of the structural score.
    static func adjust(_ ranked: Ranked, node: KnowledgeNode, workspaceID: UUID?, now: Date, policy: Policy = .default) -> Double {
        var score = ranked.score * node.sourceKind.trust * max(0.2, node.confidence)
        if let workspaceID, node.workspaceID == workspaceID {
            score *= policy.workspaceBoost
        }
        let ageDays = max(0, now.timeIntervalSince(node.updatedAt) / 86_400)
        let recency = pow(0.5, ageDays / policy.recencyHalfLifeDays)
        score *= 0.75 + 0.25 * recency
        score *= 1 + min(policy.mentionBoostCap, Double(max(0, node.mentionCount - 1)) * 0.05)
        return score
    }

    /// Records `candidate`. A node already reached by a shorter path keeps
    /// its score untouched (so seeds are never inflated by their own
    /// neighbors). Parallel paths of the same length corroborate each other
    /// as strongest path plus half of the rest, which is independent of the
    /// order edges arrive in. Returns true when the node is new, so the walk
    /// only continues outward from first arrivals.
    @discardableResult
    private static func merge(_ candidate: Ranked, into best: inout [UUID: Ranked], peaks: inout [UUID: Double]) -> Bool {
        guard let existing = best[candidate.nodeID] else {
            best[candidate.nodeID] = candidate
            peaks[candidate.nodeID] = candidate.score
            return true
        }
        guard candidate.hops == existing.hops, candidate.hops > 0 else { return false }
        let previousPeak = peaks[candidate.nodeID] ?? existing.score
        let newPeak = max(previousPeak, candidate.score)
        let others = existing.score - previousPeak + (previousPeak + candidate.score - newPeak) * 0.5
        peaks[candidate.nodeID] = newPeak
        best[candidate.nodeID] = Ranked(nodeID: candidate.nodeID, score: newPeak + others, hops: existing.hops, via: existing.via)
        return false
    }
}

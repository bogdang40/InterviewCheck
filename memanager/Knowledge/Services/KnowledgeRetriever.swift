import Foundation

struct KnowledgeRetrievalQuery: Equatable {
    var text: String
    var workspaceID: UUID?
    var seedLimit = 8
    var resultLimit = 12
    var policy = KnowledgeGraphScorer.Policy.default
}

struct KnowledgeRetrievalHit: Equatable, Identifiable {
    let node: KnowledgeNode
    let score: Double

    var id: UUID { node.id }
}

struct KnowledgeRetrievalResult: Equatable {
    let hits: [KnowledgeRetrievalHit]
    let edges: [KnowledgeEdge]

    static let empty = KnowledgeRetrievalResult(hits: [], edges: [])

    var isEmpty: Bool { hits.isEmpty }
}

/// Lexical seeds, then a bounded graph walk, then node level adjustments.
/// Everything the composer needs to write a grounded context block.
final class KnowledgeRetriever {
    private let database: SessionDatabase

    init(database: SessionDatabase = .shared) {
        self.database = database
    }

    func retrieve(_ query: KnowledgeRetrievalQuery, now: Date = Date()) -> KnowledgeRetrievalResult {
        let seedHits = database.searchKnowledgeNodes(text: query.text, limit: query.seedLimit)
        guard !seedHits.isEmpty else { return .empty }

        let seeds = seedHits.map { KnowledgeGraphScorer.Seed(nodeID: $0.node.id, score: $0.score) }
        let seedEdges = database.loadKnowledgeEdges(touching: seeds.map(\.nodeID))
        var edges = seedEdges
        // Two rings of edges are loaded, so the walk is effectively capped at
        // two hops however large maxHops is set.
        if query.policy.maxHops > 1 {
            let firstRing = Set(seedEdges.flatMap { [$0.fromNodeID, $0.toNodeID] }).subtracting(seeds.map(\.nodeID))
            edges += database.loadKnowledgeEdges(touching: Array(firstRing))
        }
        edges = KnowledgeRetriever.dedupe(edges)

        let expanded = KnowledgeGraphScorer.expand(seeds: seeds, edges: edges, policy: query.policy)
        let nodesByID = Dictionary(uniqueKeysWithValues: database.loadKnowledgeNodes(ids: expanded.map(\.nodeID)).map { ($0.id, $0) })

        let hits = expanded
            .compactMap { ranked -> KnowledgeRetrievalHit? in
                guard let node = nodesByID[ranked.nodeID] else { return nil }
                let score = KnowledgeGraphScorer.adjust(ranked, node: node, workspaceID: query.workspaceID, now: now, policy: query.policy)
                return KnowledgeRetrievalHit(node: node, score: score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.node.label < rhs.node.label
            }
            .prefix(query.resultLimit)

        let kept = Set(hits.map(\.node.id))
        let inducedEdges = edges.filter { kept.contains($0.fromNodeID) && kept.contains($0.toNodeID) }
        return KnowledgeRetrievalResult(hits: Array(hits), edges: inducedEdges)
    }

    private static func dedupe(_ edges: [KnowledgeEdge]) -> [KnowledgeEdge] {
        var seen = Set<UUID>()
        return edges.filter { seen.insert($0.id).inserted }
    }
}

import Foundation

/// A relation row: the sentence and, separately, the evidence behind it.
struct KnowledgeEdgeDescription: Equatable {
    let text: String
    let evidence: String?
}

/// Turns an edge into the sentence the relations list shows, resolving
/// both ends against the subgraph on screen.
enum KnowledgeEdgeDescriber {
    static let unknownLabel = "?"

    static func describe(_ edge: KnowledgeEdge, in graph: KnowledgeSubgraph) -> KnowledgeEdgeDescription {
        let from = graph.node(edge.fromNodeID)?.label ?? unknownLabel
        let to = graph.node(edge.toNodeID)?.label ?? unknownLabel
        let evidence = edge.evidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        return KnowledgeEdgeDescription(
            text: "\(from) \(edge.relation.displayName) \(to)",
            evidence: (evidence?.isEmpty ?? true) ? nil : evidence
        )
    }
}

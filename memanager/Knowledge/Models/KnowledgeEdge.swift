import Foundation

/// Typed relationships between graph nodes. Raw values are stable on disk
/// and are also the vocabulary the extraction prompt is asked to use.
enum KnowledgeRelation: String, Codable, CaseIterable, Identifiable {
    case workedAt = "worked_at"
    case workedWith = "worked_with"
    case built = "built"
    case usedSkill = "used_skill"
    case demonstrates = "demonstrates"
    case solved = "solved"
    case relatedTo = "related_to"
    case appliedTo = "applied_to"
    case interviewedAt = "interviewed_at"
    case mentionedIn = "mentioned_in"
    case requires = "requires"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .workedAt: return "worked at"
        case .workedWith: return "worked with"
        case .built: return "built"
        case .usedSkill: return "used skill"
        case .demonstrates: return "demonstrates"
        case .solved: return "solved"
        case .relatedTo: return "related to"
        case .appliedTo: return "applied to"
        case .interviewedAt: return "interviewed at"
        case .mentionedIn: return "mentioned in"
        case .requires: return "requires"
        }
    }

    /// Structural relations carry more retrieval signal than loose mentions.
    var traversalWeight: Double {
        switch self {
        case .relatedTo, .mentionedIn: return 0.6
        case .demonstrates, .solved, .usedSkill, .built: return 1.0
        case .workedAt, .workedWith, .appliedTo, .interviewedAt, .requires: return 0.85
        }
    }
}

struct KnowledgeEdge: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let fromNodeID: UUID
    let toNodeID: UUID
    var relation: KnowledgeRelation
    var weight: Double
    var evidence: String?
    var sourceRef: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        fromNodeID: UUID,
        toNodeID: UUID,
        relation: KnowledgeRelation,
        weight: Double = 1.0,
        evidence: String? = nil,
        sourceRef: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.relation = relation
        self.weight = weight
        self.evidence = evidence
        self.sourceRef = sourceRef
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The node on the far side of this edge from `nodeID`, if it touches it.
    func neighbor(of nodeID: UUID) -> UUID? {
        if fromNodeID == nodeID { return toNodeID }
        if toNodeID == nodeID { return fromNodeID }
        return nil
    }
}

/// A slice of the graph: the nodes of interest plus every edge among them.
struct KnowledgeSubgraph: Equatable {
    var nodes: [KnowledgeNode]
    var edges: [KnowledgeEdge]

    static let empty = KnowledgeSubgraph(nodes: [], edges: [])

    func node(_ id: UUID) -> KnowledgeNode? {
        nodes.first(where: { $0.id == id })
    }
}

struct KnowledgeSearchHit: Equatable {
    let node: KnowledgeNode
    let score: Double
}

import Foundation

/// Everything the detail pane shows, resolved from the store by the screen
/// so the pane itself stays pure and renders from fixtures.
struct KnowledgeNodeDetailModel {
    let node: KnowledgeNode
    let neighborhood: KnowledgeSubgraph
    let linkCandidates: [KnowledgeNode]
    var message: String? = nil

    /// Facts the node can still be linked to: everything listed except itself.
    var linkTargets: [KnowledgeNode] {
        linkCandidates.filter { $0.id != node.id }
    }
}

/// A link the user composed in the detail pane.
struct KnowledgeLinkRequest: Equatable {
    let targetID: UUID
    let relation: KnowledgeRelation
    let evidence: String?
}

/// The callbacks the detail pane can fire. Defaults are inert so fixtures
/// and previews can render the pane without a store.
struct KnowledgeNodeDetailActions {
    var edit: () -> Void = {}
    var delete: () -> Void = {}
    var select: (UUID) -> Void = { _ in }
    var deleteEdge: (UUID) -> Void = { _ in }
    var link: (KnowledgeLinkRequest) throws -> Void = { _ in }
    var dismissMessage: () -> Void = {}

    static let inert = KnowledgeNodeDetailActions()
}

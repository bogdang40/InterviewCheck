import Combine
import Foundation

struct KnowledgeGraphCounts: Equatable {
    var nodes = 0
    var edges = 0
}

/// Main actor facade over the graph for the Knowledge screen: browse,
/// search, edit, extract from pasted text, and inspect a node's neighborhood.
@MainActor
final class KnowledgeGraphStore: ObservableObject {
    static let shared = KnowledgeGraphStore()

    @Published private(set) var nodes: [KnowledgeNode] = []
    @Published private(set) var counts = KnowledgeGraphCounts()
    @Published private(set) var selectedNodeID: UUID?
    @Published private(set) var neighborhood: KnowledgeSubgraph = .empty
    @Published private(set) var isExtracting = false
    @Published var searchText = "" { didSet { refresh() } }
    @Published var kindFilter: KnowledgeNodeKind? { didSet { refresh() } }
    @Published var lastMessage: String?

    private let database: SessionDatabase
    private let merger: KnowledgeGraphMerger
    private let extractorFactory: () -> KnowledgeExtractor
    private var extractionID: UUID?
    private var extractionTask: Task<KnowledgeGraphMerger.Outcome, Error>?

    init(
        database: SessionDatabase = .shared,
        merger: KnowledgeGraphMerger? = nil,
        extractorFactory: (() -> KnowledgeExtractor)? = nil
    ) {
        self.database = database
        self.merger = merger ?? KnowledgeGraphMerger(database: database)
        let resolvedMerger = self.merger
        self.extractorFactory = extractorFactory ?? { KnowledgeExtractor(merger: resolvedMerger) }
    }

    var selectedNode: KnowledgeNode? {
        guard let selectedNodeID else { return nil }
        return neighborhood.node(selectedNodeID) ?? nodes.first(where: { $0.id == selectedNodeID })
    }

    // MARK: - Browsing

    func refresh() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var results: [KnowledgeNode]
        if trimmed.isEmpty {
            results = database.loadRecentKnowledgeNodes(limit: 200, kind: kindFilter)
        } else {
            results = database.searchKnowledgeNodes(text: trimmed, limit: 50).map(\.node)
            if let kindFilter { results = results.filter { $0.kind == kindFilter } }
        }
        nodes = results
        counts = KnowledgeGraphCounts(nodes: database.countKnowledgeNodes(), edges: database.countKnowledgeEdges())
        if let selectedNodeID { loadNeighborhood(of: selectedNodeID) }
    }

    func select(_ id: UUID?) {
        selectedNodeID = id
        guard let id else {
            neighborhood = .empty
            return
        }
        loadNeighborhood(of: id)
    }

    private func loadNeighborhood(of id: UUID) {
        guard let center = database.loadKnowledgeNode(id: id) else {
            neighborhood = .empty
            selectedNodeID = nil
            return
        }
        let edges = database.loadKnowledgeEdges(touching: [id])
        let neighborIDs = Array(Set(edges.compactMap { $0.neighbor(of: id) }))
        let neighbors = database.loadKnowledgeNodes(ids: neighborIDs)
        neighborhood = KnowledgeSubgraph(nodes: [center] + neighbors, edges: edges)
    }

    // MARK: - Editing

    func save(_ node: KnowledgeNode) {
        do {
            try saveForEditing(node)
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    func saveForEditing(_ node: KnowledgeNode) throws {
        if let clash = database.findKnowledgeNode(kind: node.kind, label: node.label), clash.id != node.id {
            select(clash.id)
            throw KnowledgeEditError.duplicate("A \(node.kind.displayName.lowercased()) named \(clash.label) already exists. Close this editor to review the existing fact, or change the label.")
        }
        var updated = node
        updated.updatedAt = Date()
        try database.upsertKnowledgeNode(updated)
        lastMessage = nil
        refresh()
        select(updated.id)
    }

    func deleteNode(_ id: UUID) {
        do {
            try database.deleteKnowledgeNode(id: id)
            if selectedNodeID == id { select(nil) }
            refresh()
        } catch {
            lastMessage = "Could not delete: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func addEdge(from: UUID, to: UUID, relation: KnowledgeRelation, evidence: String?) -> Bool {
        guard from != to else { return false }
        let edge = KnowledgeEdge(fromNodeID: from, toNodeID: to, relation: relation, evidence: evidence)
        do {
            try database.upsertKnowledgeEdge(edge)
            lastMessage = nil
            refresh()
            return true
        } catch {
            lastMessage = "Could not link: \(error.localizedDescription)"
            return false
        }
    }

    func deleteEdge(_ id: UUID) {
        do {
            try database.deleteKnowledgeEdge(id: id)
            refresh()
        } catch {
            lastMessage = "Could not remove relation: \(error.localizedDescription)"
        }
    }

    func clearGraph() {
        do {
            try database.clearKnowledgeGraph()
            extractionTask?.cancel()
            extractionTask = nil
            extractionID = nil
            isExtracting = false
            select(nil)
            refresh()
            lastMessage = "Knowledge graph cleared."
        } catch {
            lastMessage = "Could not clear: \(error.localizedDescription)"
        }
    }

    // MARK: - Extraction

    @discardableResult
    func extract(from text: String, workspace: JobWorkspace?) async -> Bool {
        guard !isExtracting else { return false }
        let requestID = UUID()
        extractionID = requestID
        isExtracting = true
        defer {
            if extractionID == requestID {
                extractionID = nil
                extractionTask = nil
                isExtracting = false
            }
        }
        let extractor = extractorFactory()
        let task = Task {
            try await extractor.extractAndMerge(
                text: text,
                sourceKind: .manual,
                sourceRef: "paste:\(Int(Date().timeIntervalSince1970))",
                workspaceID: workspace?.id,
                workspaceTitle: workspace?.displayTitle
            )
        }
        extractionTask = task
        do {
            let outcome = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard extractionID == requestID else { return false }
            lastMessage = "Added \(outcome.nodesCreated) new, updated \(outcome.nodesUpdated), linked \(outcome.edgesUpserted)."
            refresh()
            return true
        } catch {
            guard extractionID == requestID, !(error is CancellationError) else { return false }
            lastMessage = "Extraction failed: \(error.localizedDescription)"
            return false
        }
    }

    func noteGraphChanged() {
        refresh()
    }
}

enum KnowledgeEditError: LocalizedError {
    case duplicate(String)
    case link(String)
    var errorDescription: String? {
        switch self {
        case .duplicate(let message), .link(let message): return message
        }
    }
}

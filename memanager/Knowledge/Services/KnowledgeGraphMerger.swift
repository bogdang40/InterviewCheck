import Foundation

/// Folds extracted entries into the stored graph. Existing nodes (same kind
/// and normalized label) gain a mention and a better summary if they lacked
/// one; existing edges gain weight. Returns what was touched.
final class KnowledgeGraphMerger {
    struct Outcome: Equatable {
        var nodesCreated = 0
        var nodesUpdated = 0
        var edgesUpserted = 0
    }

    private let database: SessionDatabase

    init(database: SessionDatabase = .shared) {
        self.database = database
    }

    var generation: UInt64 { database.knowledgeGraphGeneration.snapshot() }

    func merge(
        _ extracted: ExtractedKnowledge,
        generation: UInt64,
        sourceKind: KnowledgeSourceKind,
        sourceRef: String?,
        workspaceID: UUID?
    ) throws -> Outcome {
        try database.knowledgeGraphGeneration.commit(generation: generation) {
            try Task.checkCancellation()
            return merge(extracted, sourceKind: sourceKind, sourceRef: sourceRef, workspaceID: workspaceID)
        }
    }

    @discardableResult
    func merge(_ extracted: ExtractedKnowledge, sourceKind: KnowledgeSourceKind, sourceRef: String?, workspaceID: UUID?, now: Date = Date()) -> Outcome {
        var outcome = Outcome()
        var idsByLabel: [String: UUID] = [:]

        for entry in extracted.nodes {
            let key = KnowledgeNode.normalize(entry.label)
            if idsByLabel[key] != nil { continue }
            // Same kind first; otherwise any stored node with this label. The
            // model is not consistent about kinds between turns, and one
            // "Stripe" split across company and topic scatters its relations.
            let existing = database.findKnowledgeNode(kind: entry.kind, label: entry.label)
                ?? database.findKnowledgeNode(label: entry.label)
            if let existing {
                var updated = existing
                updated.mentionCount += 1
                updated.updatedAt = now
                if (updated.summary ?? "").isEmpty, let summary = entry.summary { updated.summary = summary }
                if updated.workspaceID == nil { updated.workspaceID = workspaceID }
                if (try? database.upsertKnowledgeNode(updated)) != nil {
                    outcome.nodesUpdated += 1
                    idsByLabel[key] = updated.id
                }
            } else {
                let node = KnowledgeNode(
                    kind: entry.kind,
                    label: entry.label,
                    summary: entry.summary,
                    sourceKind: sourceKind,
                    sourceRef: sourceRef,
                    workspaceID: workspaceID,
                    confidence: sourceKind == .manual ? 1.0 : 0.8,
                    createdAt: now,
                    updatedAt: now
                )
                if (try? database.upsertKnowledgeNode(node)) != nil {
                    outcome.nodesCreated += 1
                    idsByLabel[key] = node.id
                } else if let raced = database.findKnowledgeNode(label: entry.label) {
                    // A concurrent merge inserted this label first; attach
                    // this batch's edges to that node instead of dropping them.
                    idsByLabel[key] = raced.id
                }
            }
        }

        for entry in extracted.edges {
            guard let from = idsByLabel[KnowledgeNode.normalize(entry.from)],
                  let to = idsByLabel[KnowledgeNode.normalize(entry.to)] else { continue }
            let edge = KnowledgeEdge(fromNodeID: from, toNodeID: to, relation: entry.relation, weight: 1.0, evidence: entry.evidence, sourceRef: sourceRef, createdAt: now, updatedAt: now)
            if (try? database.upsertKnowledgeEdge(edge)) != nil {
                outcome.edgesUpserted += 1
            }
        }
        return outcome
    }
}

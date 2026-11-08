import Foundation
import SQLite3

extension SessionDatabase {
    private static let knowledgeEdgeColumns =
        "id, from_node_id, to_node_id, relation, weight, evidence, source_ref, created_at, updated_at"

    /// Same (from, to, relation) triple merges: weight grows, evidence keeps
    /// the most recent non empty value.
    func upsertKnowledgeEdge(_ edge: KnowledgeEdge) throws {
        try performSyncThrowing { db in
            let sql = """
            INSERT INTO kg_edges (\(Self.knowledgeEdgeColumns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(from_node_id, to_node_id, relation) DO UPDATE SET
                weight = MIN(5.0, kg_edges.weight + excluded.weight * 0.5),
                evidence = COALESCE(excluded.evidence, kg_edges.evidence),
                source_ref = COALESCE(excluded.source_ref, kg_edges.source_ref),
                updated_at = excluded.updated_at
            """
            let statement = try SQLiteStatement(db: db, sql: sql)
            statement.bindText(edge.id.uuidString, at: 1)
            statement.bindText(edge.fromNodeID.uuidString, at: 2)
            statement.bindText(edge.toNodeID.uuidString, at: 3)
            statement.bindText(edge.relation.rawValue, at: 4)
            statement.bindDouble(edge.weight, at: 5)
            statement.bindOptionalText(edge.evidence, at: 6)
            statement.bindOptionalText(edge.sourceRef, at: 7)
            statement.bindMillis(edge.createdAt, at: 8)
            statement.bindMillis(edge.updatedAt, at: 9)
            try statement.executeStep()
        }
    }

    /// Every edge that touches any of the given nodes (either direction).
    func loadKnowledgeEdges(touching nodeIDs: [UUID]) -> [KnowledgeEdge] {
        guard !nodeIDs.isEmpty else { return [] }
        return (try? performSyncThrowing { db in
            let placeholders = Array(repeating: "?", count: nodeIDs.count).joined(separator: ", ")
            let sql = """
            SELECT \(Self.knowledgeEdgeColumns) FROM kg_edges
            WHERE from_node_id IN (\(placeholders)) OR to_node_id IN (\(placeholders))
            """
            let statement = try SQLiteStatement(db: db, sql: sql)
            for (offset, id) in nodeIDs.enumerated() {
                statement.bindText(id.uuidString, at: Int32(offset + 1))
                statement.bindText(id.uuidString, at: Int32(offset + 1 + nodeIDs.count))
            }
            var results: [KnowledgeEdge] = []
            while try statement.stepRow() {
                if let edge = makeKnowledgeEdge(from: statement) { results.append(edge) }
            }
            return results
        }) ?? []
    }

    func deleteKnowledgeEdge(id: UUID) throws {
        try performSyncThrowing { db in
            let statement = try SQLiteStatement(db: db, sql: "DELETE FROM kg_edges WHERE id = ?")
            statement.bindText(id.uuidString, at: 1)
            try statement.executeStep()
        }
    }

    func countKnowledgeEdges() -> Int {
        (try? performSyncThrowing { db in
            let statement = try SQLiteStatement(db: db, sql: "SELECT COUNT(*) FROM kg_edges")
            return try statement.stepRow() ? statement.columnInt(0) : 0
        }) ?? 0
    }

    /// Wipes the whole graph. Used by the settings reset button.
    func clearKnowledgeGraph() throws {
        try knowledgeGraphGeneration.clear {
            try performSyncThrowing { db in
                try withTransactionThrowing(db) {
                    try SQLiteStatement(db: db, sql: "DELETE FROM kg_edges").executeStep()
                    try SQLiteStatement(db: db, sql: "DELETE FROM kg_nodes").executeStep()
                    if knowledgeFTSSupported {
                        try SQLiteStatement(db: db, sql: "DELETE FROM kg_nodes_fts").executeStep()
                    }
                }
            }
        }
    }

    private func makeKnowledgeEdge(from statement: SQLiteStatement) -> KnowledgeEdge? {
        guard let rawID = statement.columnText(0), let id = UUID(uuidString: rawID),
              let from = statement.columnText(1).flatMap(UUID.init(uuidString:)),
              let to = statement.columnText(2).flatMap(UUID.init(uuidString:)),
              let relation = KnowledgeRelation(rawValue: statement.columnText(3) ?? "") else { return nil }
        return KnowledgeEdge(
            id: id,
            fromNodeID: from,
            toNodeID: to,
            relation: relation,
            weight: statement.columnDouble(4),
            evidence: statement.columnText(5),
            sourceRef: statement.columnText(6),
            createdAt: statement.columnDate(7),
            updatedAt: statement.columnDate(8)
        )
    }
}

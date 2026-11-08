import Foundation
import SQLite3

/// kg_nodes rows plus their FTS mirror. Edges and search live in siblings.
extension SessionDatabase {
    static let knowledgeNodeColumns =
        "id, kind, label, normalized_label, summary, properties, source_kind, source_ref, workspace_id, confidence, mention_count, created_at, updated_at"

    func upsertKnowledgeNode(_ node: KnowledgeNode) throws {
        try performSyncThrowing { db in
            try withTransactionThrowing(db) {
                let sql = """
                INSERT INTO kg_nodes (\(Self.knowledgeNodeColumns))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    kind = excluded.kind,
                    label = excluded.label,
                    normalized_label = excluded.normalized_label,
                    summary = excluded.summary,
                    properties = excluded.properties,
                    source_kind = excluded.source_kind,
                    source_ref = excluded.source_ref,
                    workspace_id = excluded.workspace_id,
                    confidence = excluded.confidence,
                    mention_count = excluded.mention_count,
                    updated_at = excluded.updated_at
                """
                let statement = try SQLiteStatement(db: db, sql: sql)
                statement.bindText(node.id.uuidString, at: 1)
                statement.bindText(node.kind.rawValue, at: 2)
                statement.bindText(node.label, at: 3)
                statement.bindText(node.normalizedLabel, at: 4)
                statement.bindOptionalText(node.summary, at: 5)
                statement.bindOptionalText(KnowledgePropertiesCodec.encode(node.properties), at: 6)
                statement.bindText(node.sourceKind.rawValue, at: 7)
                statement.bindOptionalText(node.sourceRef, at: 8)
                statement.bindOptionalText(node.workspaceID?.uuidString, at: 9)
                statement.bindDouble(node.confidence, at: 10)
                statement.bindInt(node.mentionCount, at: 11)
                statement.bindMillis(node.createdAt, at: 12)
                statement.bindMillis(node.updatedAt, at: 13)
                try statement.executeStep()
                try refreshKnowledgeFTS(for: node, db: db)
            }
        }
    }

    private func refreshKnowledgeFTS(for node: KnowledgeNode, db: OpaquePointer) throws {
        guard knowledgeFTSSupported else { return }
        let delete = try SQLiteStatement(db: db, sql: "DELETE FROM kg_nodes_fts WHERE node_id = ?")
        delete.bindText(node.id.uuidString, at: 1)
        try delete.executeStep()
        let insert = try SQLiteStatement(
            db: db,
            sql: "INSERT INTO kg_nodes_fts (node_id, label, summary, properties) VALUES (?, ?, ?, ?)"
        )
        insert.bindText(node.id.uuidString, at: 1)
        insert.bindText(node.label, at: 2)
        insert.bindOptionalText(node.summary, at: 3)
        insert.bindOptionalText(node.properties.values.joined(separator: " "), at: 4)
        try insert.executeStep()
    }

    func loadKnowledgeNode(id: UUID) -> KnowledgeNode? {
        try? performSyncThrowing { db in
            let statement = try SQLiteStatement(db: db, sql: "SELECT \(Self.knowledgeNodeColumns) FROM kg_nodes WHERE id = ? LIMIT 1")
            statement.bindText(id.uuidString, at: 1)
            guard try statement.stepRow() else { return nil }
            return makeKnowledgeNode(from: statement)
        }
    }

    func findKnowledgeNode(kind: KnowledgeNodeKind, label: String) -> KnowledgeNode? {
        try? performSyncThrowing { db in
            let statement = try SQLiteStatement(
                db: db,
                sql: "SELECT \(Self.knowledgeNodeColumns) FROM kg_nodes WHERE kind = ? AND normalized_label = ? LIMIT 1"
            )
            statement.bindText(kind.rawValue, at: 1)
            statement.bindText(KnowledgeNode.normalize(label), at: 2)
            guard try statement.stepRow() else { return nil }
            return makeKnowledgeNode(from: statement)
        }
    }

    /// Any node carrying this label, whatever its kind; the most mentioned
    /// wins when several exist.
    func findKnowledgeNode(label: String) -> KnowledgeNode? {
        try? performSyncThrowing { db in
            let statement = try SQLiteStatement(
                db: db,
                sql: "SELECT \(Self.knowledgeNodeColumns) FROM kg_nodes WHERE normalized_label = ? ORDER BY mention_count DESC, updated_at DESC LIMIT 1"
            )
            statement.bindText(KnowledgeNode.normalize(label), at: 1)
            guard try statement.stepRow() else { return nil }
            return makeKnowledgeNode(from: statement)
        }
    }

    func loadKnowledgeNodes(ids: [UUID]) -> [KnowledgeNode] {
        guard !ids.isEmpty else { return [] }
        return (try? performSyncThrowing { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            let statement = try SQLiteStatement(
                db: db,
                sql: "SELECT \(Self.knowledgeNodeColumns) FROM kg_nodes WHERE id IN (\(placeholders))"
            )
            for (offset, id) in ids.enumerated() {
                statement.bindText(id.uuidString, at: Int32(offset + 1))
            }
            var results: [KnowledgeNode] = []
            while try statement.stepRow() {
                if let node = makeKnowledgeNode(from: statement) { results.append(node) }
            }
            return results
        }) ?? []
    }

    func loadRecentKnowledgeNodes(limit: Int = 100, kind: KnowledgeNodeKind? = nil) -> [KnowledgeNode] {
        (try? performSyncThrowing { db in
            let filter = kind == nil ? "" : "WHERE kind = ?"
            let statement = try SQLiteStatement(
                db: db,
                sql: "SELECT \(Self.knowledgeNodeColumns) FROM kg_nodes \(filter) ORDER BY updated_at DESC LIMIT ?"
            )
            var index: Int32 = 1
            if let kind {
                statement.bindText(kind.rawValue, at: index)
                index += 1
            }
            statement.bindInt(max(1, limit), at: index)
            var results: [KnowledgeNode] = []
            while try statement.stepRow() {
                if let node = makeKnowledgeNode(from: statement) { results.append(node) }
            }
            return results
        }) ?? []
    }

    /// Deletes the node, its FTS row, and every edge touching it.
    func deleteKnowledgeNode(id: UUID) throws {
        try performSyncThrowing { db in
            try withTransactionThrowing(db) {
                let edges = try SQLiteStatement(db: db, sql: "DELETE FROM kg_edges WHERE from_node_id = ? OR to_node_id = ?")
                edges.bindText(id.uuidString, at: 1)
                edges.bindText(id.uuidString, at: 2)
                try edges.executeStep()
                if knowledgeFTSSupported {
                    let fts = try SQLiteStatement(db: db, sql: "DELETE FROM kg_nodes_fts WHERE node_id = ?")
                    fts.bindText(id.uuidString, at: 1)
                    try fts.executeStep()
                }
                let node = try SQLiteStatement(db: db, sql: "DELETE FROM kg_nodes WHERE id = ?")
                node.bindText(id.uuidString, at: 1)
                try node.executeStep()
            }
        }
    }

    func countKnowledgeNodes() -> Int {
        (try? performSyncThrowing { db in
            let statement = try SQLiteStatement(db: db, sql: "SELECT COUNT(*) FROM kg_nodes")
            return try statement.stepRow() ? statement.columnInt(0) : 0
        }) ?? 0
    }

    func makeKnowledgeNode(from statement: SQLiteStatement) -> KnowledgeNode? {
        guard let rawID = statement.columnText(0), let id = UUID(uuidString: rawID),
              let kind = KnowledgeNodeKind(rawValue: statement.columnText(1) ?? "") else { return nil }
        return KnowledgeNode(
            id: id,
            kind: kind,
            label: statement.columnText(2) ?? "",
            summary: statement.columnText(4),
            properties: KnowledgePropertiesCodec.decode(statement.columnText(5)),
            sourceKind: KnowledgeSourceKind(rawValue: statement.columnText(6) ?? "") ?? .manual,
            sourceRef: statement.columnText(7),
            workspaceID: statement.columnText(8).flatMap(UUID.init(uuidString:)),
            confidence: statement.columnDouble(9),
            mentionCount: statement.columnInt(10),
            createdAt: statement.columnDate(11),
            updatedAt: statement.columnDate(12)
        )
    }
}

/// Properties are a flat string map stored as sorted JSON so equal maps
/// produce byte identical rows.
enum KnowledgePropertiesCodec {
    static func encode(_ properties: [String: String]) -> String? {
        guard !properties.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(properties) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ raw: String?) -> [String: String] {
        guard let raw, let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }
}

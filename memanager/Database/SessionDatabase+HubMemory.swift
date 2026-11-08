import Foundation
import SQLite3

extension SessionDatabase {
    // MARK: - Hub Memory Operations

    func upsertMemoryNode(_ node: MemoryNodeRecord) {
        do {
            try performSyncThrowing { db in
                // The node row and its FTS mirror must move together or search
                // silently diverges from the graph.
                try withTransactionThrowing(db) {
                    try upsertMemoryNodeStatements(node, db: db)
                }
            }
        } catch {
            reportSwallowedError(error, operation: "upsertMemoryNode")
        }
    }

    private func upsertMemoryNodeStatements(_ node: MemoryNodeRecord, db: OpaquePointer) throws {
        let statement = try SQLiteStatement(db: db, sql: """
            INSERT OR REPLACE INTO memory_nodes
            (id, session_id, source_type, source_ref, thread_id, turn_id, question_source, intent, context_mode, content, summary, tags, importance, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        statement.bindText(node.id, at: 1)
        statement.bindText(node.sessionId, at: 2)
        statement.bindText(node.sourceType.rawValue, at: 3)
        statement.bindOptionalText(node.sourceRef, at: 4)
        statement.bindOptionalText(node.threadId, at: 5)
        statement.bindOptionalText(node.turnId, at: 6)
        statement.bindOptionalText(node.questionSource?.rawValue, at: 7)
        statement.bindOptionalText(node.intent, at: 8)
        statement.bindOptionalText(node.contextMode, at: 9)
        statement.bindText(node.content, at: 10)
        statement.bindOptionalText(node.summary, at: 11)
        statement.bindText(serializeTags(node.tags), at: 12)
        statement.bindInt(node.importance, at: 13)
        statement.bindMillis(node.createdAt, at: 14)
        statement.bindMillis(node.updatedAt, at: 15)
        try statement.executeStep()

        guard memoryFTSSupported else { return }
        let delete = try SQLiteStatement(db: db, sql: "DELETE FROM memory_nodes_fts WHERE node_id = ?")
        delete.bindText(node.id, at: 1)
        try delete.executeStep()

        let insert = try SQLiteStatement(db: db, sql: "INSERT INTO memory_nodes_fts (node_id, content, summary, tags) VALUES (?, ?, ?, ?)")
        insert.bindText(node.id, at: 1)
        insert.bindText(node.content, at: 2)
        insert.bindOptionalText(node.summary, at: 3)
        insert.bindText(serializeTags(node.tags), at: 4)
        try insert.executeStep()
    }

    func insertMemoryRelationship(_ relationship: MemoryRelationshipRecord) {
        performSync { db in
            guard let db else { return }
            let sql = """
            INSERT INTO memory_relationships
            (from_node_id, to_node_id, relation_type, strength, created_at)
            VALUES (?, ?, ?, ?, ?)
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, relationship.fromNodeId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, relationship.toNodeId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, relationship.relationType.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 4, Int32(relationship.strength))
                sqlite3_bind_int64(stmt, 5, Int64(relationship.createdAt.timeIntervalSince1970 * 1000))

                if sqlite3_step(stmt) != SQLITE_DONE {
                    NSLog("[SessionDatabase] Error inserting memory relationship: \(String(cString: sqlite3_errmsg(db)))")
                }
            }
            sqlite3_finalize(stmt)
        }
    }

    func clearHubMemory() throws {
            try performSyncThrowing { db in
                var statements = [
                    "DELETE FROM memory_relationships",
                    "DELETE FROM memory_nodes",
                    "DELETE FROM memory_retrieval_events",
                    "DELETE FROM quick_assist_thread_pins"
                ]
                // The FTS mirror only exists when the vtable was creatable;
                // deleting from a missing table would abort the transaction.
                if memoryFTSSupported {
                    statements.insert("DELETE FROM memory_nodes_fts", at: 2)
                }

                try withTransactionThrowing(db) {
                    for sql in statements {
                        let statement = try SQLiteStatement(db: db, sql: sql)
                        try statement.executeStep()
                    }
                }
            }
    }

}

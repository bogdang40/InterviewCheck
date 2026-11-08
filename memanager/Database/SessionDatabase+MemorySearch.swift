import Foundation
import SQLite3

extension SessionDatabase {
    func searchMemoryNodes(query: String, limit: Int = 5) -> [MemorySearchHit] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        var hits: [MemorySearchHit] = []
        performSync { db in
            guard let db else { return }

            if memoryFTSSupported {
                let matchQuery = makeFTSMatchQuery(from: trimmedQuery)
                let sql = """
                SELECT n.id, n.session_id, n.source_type, n.source_ref, n.content, n.summary, n.tags,
                       n.importance, n.created_at, n.updated_at,
                       n.thread_id, n.turn_id, n.question_source, n.intent, n.context_mode,
                       bm25(memory_nodes_fts)
                FROM memory_nodes_fts
                JOIN memory_nodes n ON n.id = memory_nodes_fts.node_id
                WHERE memory_nodes_fts MATCH ?
                ORDER BY bm25(memory_nodes_fts), n.importance DESC, n.updated_at DESC
                LIMIT ?
                """

                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, matchQuery, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(stmt, 2, Int32(limit))

                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let node = makeMemoryNodeRecord(from: stmt)
                        let bm25Score = sqlite3_column_type(stmt, 15) == SQLITE_NULL ? 0.0 : sqlite3_column_double(stmt, 15)
                        let normalizedScore = max(0, 1 - abs(bm25Score))
                        hits.append(MemorySearchHit(node: node, score: normalizedScore))
                    }
                }
                sqlite3_finalize(stmt)
            }

            if !hits.isEmpty {
                return
            }

            let likeValue = "%\(trimmedQuery.lowercased())%"
            let sql = """
            SELECT id, session_id, source_type, source_ref, content, summary, tags, importance, created_at, updated_at,
                   thread_id, turn_id, question_source, intent, context_mode
            FROM memory_nodes
            WHERE lower(content) LIKE ? OR lower(IFNULL(summary, '')) LIKE ? OR lower(IFNULL(tags, '')) LIKE ?
            ORDER BY importance DESC, updated_at DESC
            LIMIT ?
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, likeValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, likeValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, likeValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 4, Int32(limit))

                while sqlite3_step(stmt) == SQLITE_ROW {
                    let node = makeMemoryNodeRecord(from: stmt)
                    hits.append(MemorySearchHit(node: node, score: Double(node.importance)))
                }
            }
            sqlite3_finalize(stmt)
        }

        return hits
    }
}

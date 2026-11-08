import Foundation
import SQLite3

extension SessionDatabase {
    func insertMemoryRetrievalEvent(_ event: MemoryRetrievalEventRecord) {
        // Zero hit retrievals carry no diagnostic value worth a permanent
        // row; they were the bulk of this table's unbounded growth.
        guard event.hitCount > 0 else { return }
        performSync { db in
            guard let db else { return }
            let sql = """
            INSERT INTO memory_retrieval_events
            (query_source, query_text, query_tokens, anchor_query, expansion_query, hit_count, top_node_ids, top_score, confidence, latency_ms, session_id, thread_id, turn_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, event.querySource.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, event.queryText, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, event.queryTokens.joined(separator: ","), -1, SQLITE_TRANSIENT)
                bindOptionalText(event.anchorQuery, at: 4, in: stmt)
                bindOptionalText(event.expansionQuery, at: 5, in: stmt)
                sqlite3_bind_int(stmt, 6, Int32(event.hitCount))
                sqlite3_bind_text(stmt, 7, event.topNodeIds.joined(separator: ","), -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 8, event.topScore)
                sqlite3_bind_double(stmt, 9, event.confidence)
                sqlite3_bind_int(stmt, 10, Int32(event.latencyMs))
                bindOptionalText(event.sessionId, at: 11, in: stmt)
                bindOptionalText(event.threadId, at: 12, in: stmt)
                bindOptionalText(event.turnId, at: 13, in: stmt)
                sqlite3_bind_int64(stmt, 14, Int64(event.createdAt.timeIntervalSince1970 * 1000))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func makeMemoryNodeRecord(from stmt: OpaquePointer?) -> MemoryNodeRecord {
        let columnCount = sqlite3_column_count(stmt)
        let textAt: (Int32) -> String? = { index in
            guard index < columnCount else { return nil }
            guard let value = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: value)
        }
        let intAt: (Int32) -> Int = { index in
            guard index < columnCount else { return 0 }
            return Int(sqlite3_column_int(stmt, index))
        }
        let dateAt: (Int32) -> Date = { index in
            guard index < columnCount else { return Date() }
            return Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, index)) / 1000)
        }

        let id = textAt(0) ?? UUID().uuidString
        let sessionId = textAt(1) ?? ""
        let sourceTypeRaw = textAt(2) ?? MemoryNodeSource.quickAssist.rawValue
        let sourceRef = textAt(3)
        let content = textAt(4) ?? ""
        let summary = textAt(5)
        let tagsRaw = textAt(6) ?? ""
        let importance = intAt(7)
        let createdAt = dateAt(8)
        let updatedAt = dateAt(9)
        let threadId = textAt(10)
        let turnId = textAt(11)
        let questionSourceRaw = textAt(12)
        let intent = textAt(13)
        let contextMode = textAt(14)

        return MemoryNodeRecord(
            id: id,
            sessionId: sessionId,
            sourceType: MemoryNodeSource(rawValue: sourceTypeRaw) ?? .quickAssist,
            sourceRef: sourceRef,
            threadId: threadId,
            turnId: turnId,
            questionSource: questionSourceRaw.flatMap(QuickAssistQuestionSource.init(rawValue:)),
            intent: intent,
            contextMode: contextMode,
            content: content,
            summary: summary,
            tags: parseTags(tagsRaw),
            importance: importance,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    func serializeTags(_ tags: [String]) -> String {
        tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
    }

    private func parseTags(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func makeFTSMatchQuery(from query: String) -> String {
        let tokens = query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
        if tokens.isEmpty {
            return query
        }
        return makeFTSMatchQuery(tokens: tokens, useAnd: false)
    }

    func makeFTSMatchQuery(tokens: [String], useAnd: Bool) -> String {
        let filtered = tokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !filtered.isEmpty else { return "" }
        let joiner = useAnd ? " AND " : " OR "
        return filtered.map { "\"\($0)\"" }.joined(separator: joiner)
    }
}

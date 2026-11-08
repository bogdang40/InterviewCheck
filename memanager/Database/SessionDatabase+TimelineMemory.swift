import Foundation
import SQLite3

extension SessionDatabase {
    func fetchMemoryTimelineEvents(
        db: OpaquePointer,
        sessionId: String?,
        searchLike: String?,
        limit: Int
    ) -> [WorkstreamTimelineEvent] {
        var events: [WorkstreamTimelineEvent] = []
        var conditions: [String] = []
        var bindValues: [String] = []

        if let sessionId, !sessionId.isEmpty {
            conditions.append("session_id = ?")
            bindValues.append(sessionId)
        }
        if let searchLike {
            conditions.append("(lower(content) LIKE ? OR lower(IFNULL(summary, '')) LIKE ? OR lower(IFNULL(tags, '')) LIKE ?)")
            bindValues.append(contentsOf: [searchLike, searchLike, searchLike])
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let sql = """
        SELECT id, session_id, source_type, source_ref, content, summary, tags, importance, updated_at, thread_id, turn_id
        FROM memory_nodes
        \(whereClause)
        ORDER BY updated_at DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            var bindIndex: Int32 = 1
            for value in bindValues {
                sqlite3_bind_text(stmt, bindIndex, value, -1, SQLITE_TRANSIENT)
                bindIndex += 1
            }
            sqlite3_bind_int(stmt, bindIndex, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString
                let nodeSessionId = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let sourceType = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "quick_assist"
                let sourceRef = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let content = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let summary = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let tags = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                let importance = Int(sqlite3_column_int(stmt, 7))
                let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 8)) / 1000)
                let threadId = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
                let turnId = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
                let displaySummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? summary!
                    : content

                events.append(WorkstreamTimelineEvent(
                    id: "mem-\(id)",
                    type: .memory,
                    severity: importance >= 3 ? .warning : .info,
                    timestamp: updatedAt,
                    sessionId: nodeSessionId,
                    threadId: threadId,
                    turnId: turnId,
                    title: "Memory • \(sourceType)",
                    summary: String(displaySummary.prefix(220)),
                    detail: "tags=\(tags)",
                    sourceRef: sourceRef,
                    coachFindingId: nil
                ))
            }
        }
        sqlite3_finalize(stmt)
        return events
    }

    func fetchMemoryRetrievalTimelineEvents(
        db: OpaquePointer,
        sessionId: String?,
        threadId: String?,
        searchLike: String?,
        limit: Int
    ) -> [WorkstreamTimelineEvent] {
        var events: [WorkstreamTimelineEvent] = []
        var conditions: [String] = []
        var bindValues: [String] = []

        if let sessionId, !sessionId.isEmpty {
            conditions.append("session_id = ?")
            bindValues.append(sessionId)
        }
        if let threadId = threadId?.trimmingCharacters(in: .whitespacesAndNewlines), !threadId.isEmpty {
            conditions.append("thread_id = ?")
            bindValues.append(threadId)
        }
        if let searchLike {
            conditions.append("(lower(query_text) LIKE ? OR lower(IFNULL(query_tokens, '')) LIKE ?)")
            bindValues.append(contentsOf: [searchLike, searchLike])
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let sql = """
        SELECT id, query_source, query_text, query_tokens, hit_count, top_score, confidence, latency_ms, session_id, thread_id, turn_id, created_at
        FROM memory_retrieval_events
        \(whereClause)
        ORDER BY created_at DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            var bindIndex: Int32 = 1
            for value in bindValues {
                sqlite3_bind_text(stmt, bindIndex, value, -1, SQLITE_TRANSIENT)
                bindIndex += 1
            }
            sqlite3_bind_int(stmt, bindIndex, Int32(limit))

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int64(sqlite3_column_int64(stmt, 0))
                let querySource = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "unknown"
                let queryText = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let queryTokens = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let hitCount = Int(sqlite3_column_int(stmt, 4))
                let topScore = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? 0 : sqlite3_column_double(stmt, 5)
                let confidence = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? 0 : sqlite3_column_double(stmt, 6)
                let latencyMs = Int(sqlite3_column_int(stmt, 7))
                let rowSessionId = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
                let rowThreadId = sqlite3_column_text(stmt, 9).map { String(cString: $0) }
                let rowTurnId = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
                let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 11)) / 1000)
                let severity: WorkstreamEventSeverity = (confidence < 0.35 || hitCount == 0) ? .warning : .info

                let detail = "source=\(querySource), tokens=\(queryTokens), topScore=\(String(format: "%.2f", topScore)), confidence=\(String(format: "%.2f", confidence)), latencyMs=\(latencyMs)"
                events.append(WorkstreamTimelineEvent(
                    id: "memr-\(id)",
                    type: .memoryRetrieval,
                    severity: severity,
                    timestamp: createdAt,
                    sessionId: rowSessionId,
                    threadId: rowThreadId,
                    turnId: rowTurnId,
                    title: "Memory retrieval • \(querySource)",
                    summary: "hits=\(hitCount) • \(String(queryText.prefix(180)))",
                    detail: detail,
                    sourceRef: "memory_retrieval_events:\(id)",
                    coachFindingId: nil
                ))
            }
        }
        sqlite3_finalize(stmt)
        return events
    }

}

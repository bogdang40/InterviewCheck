import Foundation
import SQLite3

extension SessionDatabase {
    func fetchQuickAssistTimelineEvents(
        db: OpaquePointer,
        filter: WorkstreamTimelineFilter,
        searchLike: String?,
        limit: Int
    ) -> [WorkstreamTimelineEvent] {
        var events: [WorkstreamTimelineEvent] = []
        var conditions: [String] = []
        var bindValues: [String] = []

        if let sessionId = filter.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionId.isEmpty {
            conditions.append("session_id = ?")
            bindValues.append(sessionId)
        }
        if let threadId = filter.threadId?.trimmingCharacters(in: .whitespacesAndNewlines), !threadId.isEmpty {
            conditions.append("thread_id = ?")
            bindValues.append(threadId)
        }
        if let searchLike {
            conditions.append("(lower(IFNULL(question, '')) LIKE ? OR lower(IFNULL(response_text, '')) LIKE ? OR lower(IFNULL(error_message, '')) LIKE ?)")
            bindValues.append(contentsOf: [searchLike, searchLike, searchLike])
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let sql = """
        SELECT id, session_id, thread_id, turn_id, status, started_at, duration_ms,
               question, response_text, error_message, context_mode, model_tier, verification_status, route_confidence
        FROM quick_assist_calls
        \(whereClause)
        ORDER BY started_at DESC
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
                let sessionId = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let threadId = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let turnId = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let status = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "unknown"
                let startedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 5)) / 1000)
                let durationMs = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 6))
                let question = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
                let responseText = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
                let error = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? ""
                let mode = sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? "conversation"
                let tier = sqlite3_column_text(stmt, 11).map { String(cString: $0) } ?? "fast"
                let verificationStatus = sqlite3_column_text(stmt, 12).map { String(cString: $0) } ?? "pending"
                let routeConfidence = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 13)

                let summaryBase: String
                if status == "error" {
                    summaryBase = error.isEmpty ? "Quick Assist failed." : error
                } else {
                    summaryBase = responseText.isEmpty ? "Quick Assist turn completed." : responseText
                }
                let questionLine = question.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = questionLine.isEmpty ? "Quick Assist turn" : String(questionLine.prefix(96))
                let detail = "status=\(status), mode=\(mode), tier=\(tier), verification=\(verificationStatus), routeConfidence=\(routeConfidence.map { String(format: "%.2f", $0) } ?? "n/a"), durationMs=\(durationMs.map(String.init) ?? "n/a")"
                let severity: WorkstreamEventSeverity = status == "error" ? .critical : (status == "cancelled" ? .warning : .info)

                events.append(WorkstreamTimelineEvent(
                    id: "qa-\(id)",
                    type: .quickAssist,
                    severity: severity,
                    timestamp: startedAt,
                    sessionId: sessionId,
                    threadId: threadId,
                    turnId: turnId,
                    title: title,
                    summary: String(summaryBase.prefix(220)),
                    detail: detail,
                    sourceRef: "quick_assist_calls:\(id)",
                    coachFindingId: nil
                ))
            }
        }
        sqlite3_finalize(stmt)
        return events
    }

    func fetchTranscriptTimelineEvents(
        db: OpaquePointer,
        sessionId: String?,
        searchLike: String?,
        limit: Int
    ) -> [WorkstreamTimelineEvent] {
        var events: [WorkstreamTimelineEvent] = []
        guard let sessionId, !sessionId.isEmpty else { return events }

        var conditions: [String] = ["session_id = ?"]
        var bindValues: [String] = [sessionId]
        if let searchLike {
            conditions.append("lower(text) LIKE ?")
            bindValues.append(searchLike)
        }
        let sql = """
        SELECT id, speaker, text, source, timestamp
        FROM transcript_entries
        WHERE \(conditions.joined(separator: " AND "))
        ORDER BY timestamp DESC
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
                let speaker = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "Speaker"
                let text = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let source = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "microphone"
                let ts = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4)) / 1000)

                events.append(WorkstreamTimelineEvent(
                    id: "tr-\(id)",
                    type: .transcript,
                    severity: .info,
                    timestamp: ts,
                    sessionId: sessionId,
                    threadId: nil,
                    turnId: nil,
                    title: "Transcript • \(speaker)",
                    summary: String(text.prefix(220)),
                    detail: "source=\(source)",
                    sourceRef: "transcript_entries:\(id)",
                    coachFindingId: nil
                ))
            }
        }
        sqlite3_finalize(stmt)
        return events
    }

    func fetchQuickAssistPolicyTimelineEvents(
        db: OpaquePointer,
        filter: WorkstreamTimelineFilter,
        searchLike: String?,
        limit: Int
    ) -> [WorkstreamTimelineEvent] {
        var events: [WorkstreamTimelineEvent] = []
        var conditions: [String] = []
        var bindValues: [String] = []

        if let sessionId = filter.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionId.isEmpty {
            conditions.append("session_id = ?")
            bindValues.append(sessionId)
        }
        if let threadId = filter.threadId?.trimmingCharacters(in: .whitespacesAndNewlines), !threadId.isEmpty {
            conditions.append("thread_id = ?")
            bindValues.append(threadId)
        }
        if let searchLike {
            conditions.append("(lower(IFNULL(selected_intent, '')) LIKE ? OR lower(IFNULL(decision_vector, '')) LIKE ?)")
            bindValues.append(contentsOf: [searchLike, searchLike])
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let sql = """
        SELECT id, session_id, thread_id, turn_id, policy_version, selected_intent, route_confidence, route_override, decision_vector, created_at
        FROM quick_assist_policy_events
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
                let sessionId = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let threadId = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let turnId = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let policyVersion = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "unknown"
                let selectedIntent = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "conversation"
                let routeConfidence = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? 0 : sqlite3_column_double(stmt, 6)
                let routeOverride = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
                let decisionVector = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
                let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 9)) / 1000)
                let severity: WorkstreamEventSeverity = routeConfidence < 0.45 ? .warning : .info
                let title = routeOverride == nil
                    ? "Routing policy • \(selectedIntent)"
                    : "Routing policy • \(selectedIntent) (override)"
                let detail = "policy=\(policyVersion), confidence=\(String(format: "%.2f", routeConfidence)), override=\(routeOverride ?? "none"), decision=\(decisionVector)"

                events.append(WorkstreamTimelineEvent(
                    id: "qap-\(id)",
                    type: .routingPolicy,
                    severity: severity,
                    timestamp: createdAt,
                    sessionId: sessionId,
                    threadId: threadId,
                    turnId: turnId,
                    title: title,
                    summary: String(detail.prefix(220)),
                    detail: detail,
                    sourceRef: "quick_assist_policy_events:\(id)",
                    coachFindingId: nil
                ))
            }
        }
        sqlite3_finalize(stmt)
        return events
    }

}

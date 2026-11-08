import Foundation
import SQLite3

extension SessionDatabase {
    func fetchDebugTimelineEvents(
        db: OpaquePointer,
        sessionId: String?,
        searchLike: String?,
        limit: Int
    ) -> [WorkstreamTimelineEvent] {
        var events: [WorkstreamTimelineEvent] = []
        var conditions: [String] = [
            "(event_type = 'error' OR event_name IN ('render_timeout_kept_last_good', 'render_failure_kept_last_good', 'web_content_process_terminated', 'progressive_step_skipped_invalid', 'api_call_complete'))"
        ]
        var bindValues: [String] = []

        if let sessionId, !sessionId.isEmpty {
            conditions.append("session_id = ?")
            bindValues.append(sessionId)
        }
        if let searchLike {
            conditions.append("(lower(event_category) LIKE ? OR lower(event_name) LIKE ? OR lower(IFNULL(details, '')) LIKE ?)")
            bindValues.append(contentsOf: [searchLike, searchLike, searchLike])
        }
        let sql = """
        SELECT id, session_id, event_type, event_category, event_name, details, timestamp
        FROM debug_events
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
                let rowSessionId = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let eventType = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "lifecycle"
                let category = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "debug"
                let name = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "event"
                let details = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let ts = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 6)) / 1000)
                let severity: WorkstreamEventSeverity = eventType == "error" ? .critical : .warning

                events.append(WorkstreamTimelineEvent(
                    id: "dbg-\(id)",
                    type: .debug,
                    severity: severity,
                    timestamp: ts,
                    sessionId: rowSessionId,
                    threadId: nil,
                    turnId: nil,
                    title: "\(category) • \(name)",
                    summary: String((details ?? "No additional details").prefix(220)),
                    detail: "type=\(eventType)",
                    sourceRef: "debug_events:\(id)",
                    coachFindingId: nil
                ))
            }
        }
        sqlite3_finalize(stmt)
        return events
    }

    func fetchCoachTimelineEvents(
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
            conditions.append("(lower(title) LIKE ? OR lower(message) LIKE ? OR lower(suggested_question) LIKE ?)")
            bindValues.append(contentsOf: [searchLike, searchLike, searchLike])
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let sql = """
        SELECT id, session_id, thread_id, issue_type, severity, status, title, message, updated_at
        FROM coach_findings
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
                let sessionId = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let threadId = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let issueType = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "issue"
                let severityRaw = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? WorkstreamEventSeverity.info.rawValue
                let status = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? CoachFindingStatus.active.rawValue
                let title = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "Coach finding"
                let message = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
                let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 8)) / 1000)

                events.append(WorkstreamTimelineEvent(
                    id: "coach-\(id)",
                    type: .coachFinding,
                    severity: WorkstreamEventSeverity(rawValue: severityRaw) ?? .warning,
                    timestamp: updatedAt,
                    sessionId: sessionId,
                    threadId: threadId,
                    turnId: nil,
                    title: title,
                    summary: String(message.prefix(220)),
                    detail: "issue=\(issueType), status=\(status)",
                    sourceRef: "coach_findings:\(id)",
                    coachFindingId: id
                ))
            }
        }
        sqlite3_finalize(stmt)
        return events
    }
}

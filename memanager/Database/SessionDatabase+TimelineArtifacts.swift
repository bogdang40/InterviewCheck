import Foundation
import SQLite3

extension SessionDatabase {
    func fetchScreenshotTimelineEvents(
        db: OpaquePointer,
        sessionId: String?,
        limit: Int
    ) -> [WorkstreamTimelineEvent] {
        var events: [WorkstreamTimelineEvent] = []
        guard let sessionId, !sessionId.isEmpty else { return events }

        let sql = """
        SELECT id, captured_at, width, height, source
        FROM screenshots
        WHERE session_id = ?
        ORDER BY captured_at DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int64(sqlite3_column_int64(stmt, 0))
                let capturedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1)) / 1000)
                let width = Int(sqlite3_column_int(stmt, 2))
                let height = Int(sqlite3_column_int(stmt, 3))
                let source = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "manual"
                let summary = width > 0 && height > 0
                    ? "\(width)x\(height) • \(source)"
                    : source

                events.append(WorkstreamTimelineEvent(
                    id: "ss-\(id)",
                    type: .screenshot,
                    severity: .info,
                    timestamp: capturedAt,
                    sessionId: sessionId,
                    threadId: nil,
                    turnId: nil,
                    title: "Screenshot captured",
                    summary: summary,
                    detail: nil,
                    sourceRef: "screenshots:\(id)",
                    coachFindingId: nil
                ))
            }
        }
        sqlite3_finalize(stmt)
        return events
    }

    func fetchResponseCardTimelineEvents(
        db: OpaquePointer,
        sessionId: String?,
        limit: Int
    ) -> [WorkstreamTimelineEvent] {
        var events: [WorkstreamTimelineEvent] = []
        guard let sessionId, !sessionId.isEmpty else { return events }
        let sql = """
        SELECT id, event_name, details, timestamp
        FROM debug_events
        WHERE session_id = ? AND event_category = 'response_card'
        ORDER BY timestamp DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = Int64(sqlite3_column_int64(stmt, 0))
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "response_card"
                let details = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let timestamp = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 3)) / 1000)
                events.append(
                    WorkstreamTimelineEvent(
                        id: "rc-\(id)",
                        type: .responseCard,
                        severity: .info,
                        timestamp: timestamp,
                        sessionId: sessionId,
                        threadId: nil,
                        turnId: nil,
                        title: "Response card \(name.replacingOccurrences(of: "_", with: " "))",
                        summary: String((details ?? "Live response card event").prefix(180)),
                        detail: details,
                        sourceRef: "debug_events:\(id)",
                        coachFindingId: nil
                    )
                )
            }
        }
        sqlite3_finalize(stmt)
        return events
    }

    func fetchExperimentTimelineEvents(
        db: OpaquePointer,
        sessionId: String?,
        threadId: String?,
        limit: Int
    ) -> [WorkstreamTimelineEvent] {
        var events: [WorkstreamTimelineEvent] = []
        var conditions: [String] = []
        if let sessionId, !sessionId.isEmpty {
            conditions.append("session_id = ?")
        }
        if let threadId, !threadId.isEmpty {
            conditions.append("source_thread_id = ?")
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let sql = """
        SELECT id, session_id, source_thread_id, source_turn_id, status, winner_candidate_id, updated_at
        FROM quick_assist_experiments
        \(whereClause)
        ORDER BY updated_at DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            var bindIndex: Int32 = 1
            if let sessionId, !sessionId.isEmpty {
                sqlite3_bind_text(stmt, bindIndex, sessionId, -1, SQLITE_TRANSIENT)
                bindIndex += 1
            }
            if let threadId, !threadId.isEmpty {
                sqlite3_bind_text(stmt, bindIndex, threadId, -1, SQLITE_TRANSIENT)
                bindIndex += 1
            }
            sqlite3_bind_int(stmt, bindIndex, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString
                let sessionId = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                let sourceThreadId = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let sourceTurnId = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let status = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "running"
                let winner = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 6)) / 1000)
                events.append(
                    WorkstreamTimelineEvent(
                        id: "exp-\(id)",
                        type: .experiment,
                        severity: status == QuickAssistExperimentStatus.completed.rawValue ? .info : .warning,
                        timestamp: updatedAt,
                        sessionId: sessionId,
                        threadId: sourceThreadId,
                        turnId: sourceTurnId,
                        title: "Experiment Lab",
                        summary: "status=\(status), winner=\(winner ?? "pending")",
                        detail: "experiment_id=\(id)",
                        sourceRef: "quick_assist_experiments:\(id)",
                        coachFindingId: nil
                    )
                )
            }
        }
        sqlite3_finalize(stmt)
        return events
    }

    func fetchDebriefTimelineEvents(
        db: OpaquePointer,
        sessionId: String?,
        limit: Int
    ) -> [WorkstreamTimelineEvent] {
        var events: [WorkstreamTimelineEvent] = []
        guard let sessionId, !sessionId.isEmpty else { return events }
        let sql = """
        SELECT id, updated_at
        FROM session_debriefs
        WHERE session_id = ?
        ORDER BY updated_at DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString
                let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1)) / 1000)
                events.append(
                    WorkstreamTimelineEvent(
                        id: "deb-\(id)",
                        type: .debrief,
                        severity: .info,
                        timestamp: updatedAt,
                        sessionId: sessionId,
                        threadId: nil,
                        turnId: nil,
                        title: "Session debrief",
                        summary: "Debrief regenerated for this session.",
                        detail: "debrief_id=\(id)",
                        sourceRef: "session_debriefs:\(id)",
                        coachFindingId: nil
                    )
                )
            }
        }
        sqlite3_finalize(stmt)
        return events
    }

}

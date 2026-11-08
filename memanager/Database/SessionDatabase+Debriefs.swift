import Foundation
import SQLite3

extension SessionDatabase {
    func saveSessionDebrief(_ debrief: SessionDebrief) {
        do {
            try performSyncThrowing { db in
                // Debrief row and its drills replace together: a crash between
                // the drill delete and reinserts must not lose the drills.
                try withTransactionThrowing(db) {
                    saveSessionDebriefStatements(debrief, db: db)
                }
            }
        } catch {
            reportSwallowedError(error, operation: "saveSessionDebrief")
        }
    }

    private func saveSessionDebriefStatements(_ debrief: SessionDebrief, db: OpaquePointer) {
            let nowMs = Int64(debrief.updatedAt.timeIntervalSince1970 * 1000)
            let sql = """
            INSERT OR REPLACE INTO session_debriefs
            (id, session_id, what_happened, strong_moments, missed_opportunities, recommended_drills, next_session_focus, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT created_at FROM session_debriefs WHERE session_id = ?), ?), ?)
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, debrief.id, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, debrief.sessionId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, encodeStringArray(debrief.whatHappened) ?? "[]", -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, encodeStringArray(debrief.strongMoments) ?? "[]", -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, encodeStringArray(debrief.missedOpportunities) ?? "[]", -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 6, encodeStringArray(debrief.recommendedDrills) ?? "[]", -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 7, encodeStringArray(debrief.nextSessionFocus) ?? "[]", -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 8, debrief.sessionId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 9, Int64(debrief.createdAt.timeIntervalSince1970 * 1000))
                sqlite3_bind_int64(stmt, 10, nowMs)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)

            var deleteStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM session_debrief_drills WHERE session_id = ?", -1, &deleteStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(deleteStmt, 1, debrief.sessionId, -1, SQLITE_TRANSIENT)
                sqlite3_step(deleteStmt)
            }
            sqlite3_finalize(deleteStmt)

            let insertDrillSQL = """
            INSERT INTO session_debrief_drills
            (id, session_id, debrief_id, kind, title, prompt, transcript_span, related_thread_id, related_turn_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            for drill in debrief.drills {
                var drillStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, insertDrillSQL, -1, &drillStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(drillStmt, 1, drill.id, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(drillStmt, 2, drill.sessionId, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(drillStmt, 3, drill.debriefId, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(drillStmt, 4, drill.kind.rawValue, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(drillStmt, 5, drill.title, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(drillStmt, 6, drill.prompt, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(drillStmt, 7, drill.transcriptSpan, -1, SQLITE_TRANSIENT)
                    bindOptionalText(drill.relatedThreadId, at: 8, in: drillStmt)
                    bindOptionalText(drill.relatedTurnId, at: 9, in: drillStmt)
                    sqlite3_bind_int64(drillStmt, 10, Int64(drill.createdAt.timeIntervalSince1970 * 1000))
                    sqlite3_step(drillStmt)
                }
                sqlite3_finalize(drillStmt)
            }
    }

    func loadSessionDebrief(sessionId: String) -> SessionDebrief? {
        var debrief: SessionDebrief?
        performSync { db in
            guard let db else { return }
            let sql = """
            SELECT id, what_happened, strong_moments, missed_opportunities, recommended_drills, next_session_focus, created_at, updated_at
            FROM session_debriefs
            WHERE session_id = ?
            LIMIT 1
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString
                    let whatHappened = decodeStringArray(sqlite3_column_text(stmt, 1).map { String(cString: $0) })
                    let strongMoments = decodeStringArray(sqlite3_column_text(stmt, 2).map { String(cString: $0) })
                    let missedOpportunities = decodeStringArray(sqlite3_column_text(stmt, 3).map { String(cString: $0) })
                    let recommendedDrills = decodeStringArray(sqlite3_column_text(stmt, 4).map { String(cString: $0) })
                    let nextSessionFocus = decodeStringArray(sqlite3_column_text(stmt, 5).map { String(cString: $0) })
                    let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 6)) / 1000)
                    let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 7)) / 1000)
                    let drills = loadSessionDebriefDrills(db: db, sessionId: sessionId, debriefId: id)
                    debrief = SessionDebrief(
                        id: id,
                        sessionId: sessionId,
                        whatHappened: whatHappened,
                        strongMoments: strongMoments,
                        missedOpportunities: missedOpportunities,
                        recommendedDrills: recommendedDrills,
                        nextSessionFocus: nextSessionFocus,
                        createdAt: createdAt,
                        updatedAt: updatedAt,
                        drills: drills
                    )
                }
            }
            sqlite3_finalize(stmt)
        }
        return debrief
    }

    private func loadSessionDebriefDrills(
        db: OpaquePointer,
        sessionId: String,
        debriefId: String
    ) -> [SessionDrill] {
        var drills: [SessionDrill] = []
        let sql = """
        SELECT id, kind, title, prompt, transcript_span, related_thread_id, related_turn_id, created_at
        FROM session_debrief_drills
        WHERE session_id = ? AND debrief_id = ?
        ORDER BY created_at ASC
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, debriefId, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString
                let kind = sqlite3_column_text(stmt, 1).map { String(cString: $0) }.flatMap(SessionDrillKind.init(rawValue:)) ?? .clarification
                let title = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let prompt = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let transcriptSpan = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let relatedThreadId = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let relatedTurnId = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 7)) / 1000)
                drills.append(
                    SessionDrill(
                        id: id,
                        sessionId: sessionId,
                        debriefId: debriefId,
                        kind: kind,
                        title: title,
                        prompt: prompt,
                        transcriptSpan: transcriptSpan,
                        relatedThreadId: relatedThreadId,
                        relatedTurnId: relatedTurnId,
                        createdAt: createdAt
                    )
                )
            }
        }
        sqlite3_finalize(stmt)
        return drills
    }
}

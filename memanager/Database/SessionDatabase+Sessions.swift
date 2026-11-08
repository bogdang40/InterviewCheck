import Foundation
import SQLite3

extension SessionDatabase {
    // MARK: - Session Operations
    
    func insertSession(_ session: SessionRecord) {
        performAsync { [weak self] db in
            guard let self, let db else { return }

            // UPSERT instead of INSERT OR REPLACE: session updates must never
            // clobber started_at, created_at, or an already recorded ended_at
            // (SessionRecord.from always carries endedAt nil, so the old
            // REPLACE reset ended sessions back to open on every update).
            let sql = """
            INSERT INTO sessions
            (id, started_at, ended_at, state, transcript, transcript_word_count,
             screenshot_count, has_response, provider, model, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                state = excluded.state,
                transcript = excluded.transcript,
                transcript_word_count = excluded.transcript_word_count,
                screenshot_count = excluded.screenshot_count,
                has_response = excluded.has_response,
                provider = excluded.provider,
                model = excluded.model
            """

            do {
                let statement = try SQLiteStatement(db: db, sql: sql)
                statement.bindText(session.id, at: 1)
                statement.bindMillis(session.startedAt, at: 2)
                if let endedAt = session.endedAt {
                    statement.bindMillis(endedAt, at: 3)
                } else {
                    statement.bindNull(at: 3)
                }
                statement.bindText(session.state, at: 4)
                statement.bindOptionalText(session.transcript, at: 5)
                statement.bindInt(session.transcriptWordCount, at: 6)
                statement.bindInt(session.screenshotCount, at: 7)
                statement.bindInt(session.hasResponse ? 1 : 0, at: 8)
                statement.bindOptionalText(session.provider, at: 9)
                statement.bindOptionalText(session.model, at: 10)
                statement.bindMillis(Date(), at: 11)
                try statement.executeStep()
            } catch {
                self.reportSwallowedError(error, operation: "insertSession")
            }
        }
    }
    
    func updateSessionEnded(sessionId: String, endedAt: Date) {
        performAsync { db in
            guard let db else { return }
            
            let sql = "UPDATE sessions SET ended_at = ? WHERE id = ?"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, Int64(endedAt.timeIntervalSince1970 * 1000))
                sqlite3_bind_text(stmt, 2, sessionId, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }
}

import Foundation
import SQLite3

extension SessionDatabase {
    /// The complete identity set for destructive confirmation, independent of
    /// the history page limit and without loading every thread's call summary.
    func getQuickAssistThreadIDs() throws -> Set<String> {
        try performSyncThrowing { db in
            let statement = try SQLiteStatement(db: db, sql: "SELECT id FROM quick_assist_threads")
            var ids: Set<String> = []
            while try statement.stepRow() {
                if let id = statement.columnText(0) { ids.insert(id) }
            }
            return ids
        }
    }

    func getQuickAssistThreads(limit: Int = 200) -> [QuickAssistThreadSummary] {
        var threads: [QuickAssistThreadSummary] = []

        performSync { db in
            guard let db else { return }

            let sql = Self.quickAssistThreadSelectSQL + """
            ORDER BY COALESCE(last_turn_at, t.updated_at) DESC
            LIMIT ?
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(limit))

                while sqlite3_step(stmt) == SQLITE_ROW {
                    threads.append(makeQuickAssistThreadSummary(from: stmt))
                }
            }
            sqlite3_finalize(stmt)
        }

        return threads
    }

    func getLatestQuickAssistThread(originSessionId: String) -> QuickAssistThreadSummary? {
        var thread: QuickAssistThreadSummary?

        performSync { db in
            guard let db else { return }

            let sql = Self.quickAssistThreadSelectSQL + """
            WHERE t.origin_session_id = ?
            ORDER BY COALESCE(last_turn_at, t.updated_at) DESC
            LIMIT 1
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, originSessionId, -1, SQLITE_TRANSIENT)

                if sqlite3_step(stmt) == SQLITE_ROW {
                    thread = makeQuickAssistThreadSummary(from: stmt)
                }
            }
            sqlite3_finalize(stmt)
        }

        return thread
    }


    private static let quickAssistThreadSelectSQL = """
        SELECT
            t.id,
            COALESCE(NULLIF(TRIM(t.title), ''), 'Quick Assist Thread'),
            t.created_at,
            t.updated_at,
            COALESCE(NULLIF(TRIM(t.selected_mode), ''), 'auto'),
            t.origin_session_id,
            t.parent_thread_id,
            t.branched_from_turn_id,
            (
                SELECT COUNT(*)
                FROM quick_assist_calls c
                WHERE c.thread_id = t.id AND c.status = 'success'
            ) AS turn_count,
            (
                SELECT c.started_at
                FROM quick_assist_calls c
                WHERE c.thread_id = t.id AND c.status = 'success'
                ORDER BY c.started_at DESC
                LIMIT 1
            ) AS last_turn_at,
            (
                SELECT c.response_text
                FROM quick_assist_calls c
                WHERE c.thread_id = t.id AND c.status = 'success'
                ORDER BY c.started_at DESC
                LIMIT 1
            ) AS preview_text,
            EXISTS(SELECT 1 FROM quick_assist_calls c WHERE c.thread_id = t.id) AS has_recorded_calls
        FROM quick_assist_threads t

        """

    private func makeQuickAssistThreadSummary(from stmt: OpaquePointer?) -> QuickAssistThreadSummary {
        let id = String(cString: sqlite3_column_text(stmt, 0))
        let title = String(cString: sqlite3_column_text(stmt, 1))
        let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)) / 1000)
        let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 3)) / 1000)
        let selectedModeRaw = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? QuickAssistThreadMode.auto.rawValue
        let selectedMode = QuickAssistThreadMode(rawValue: selectedModeRaw) ?? .auto
        let originSessionId = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
        let parentThreadId = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
        let branchedFromTurnId = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        let turnCount = Int(sqlite3_column_int(stmt, 8))
        let lastTurnAt: Date? = sqlite3_column_type(stmt, 9) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 9)) / 1000)
        let previewText = sqlite3_column_text(stmt, 10).map { String(cString: $0) }

        return QuickAssistThreadSummary(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            selectedMode: selectedMode,
            originSessionId: originSessionId,
            parentThreadId: parentThreadId,
            branchedFromTurnId: branchedFromTurnId,
            turnCount: turnCount,
            lastTurnAt: lastTurnAt,
            previewText: previewText,
            hasRecordedCalls: sqlite3_column_int(stmt, 11) != 0
        )
    }
}

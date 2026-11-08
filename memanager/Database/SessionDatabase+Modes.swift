import Foundation
import SQLite3

// MARK: - Session Mode Snapshot Persistence

extension SessionDatabase {
    func saveSessionModeSnapshot(_ record: SessionModeSnapshotRecord) {
        performSync { db in
            guard let db else { return }
            let sql = """
            INSERT OR REPLACE INTO session_mode_snapshots
            (snapshot_id, session_id, source_mode_id, captured_at, title, prompt_text,
             attachments_json, project_folder_display_path,
             project_folder_enabled_at_capture, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                return
            }
            sqlite3_bind_text(stmt, 1, record.snapshotID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, record.sessionID, -1, SQLITE_TRANSIENT)
            if let source = record.sourceModeID {
                sqlite3_bind_text(stmt, 3, source, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_int64(stmt, 4, Int64(record.capturedAt.timeIntervalSince1970 * 1000))
            sqlite3_bind_text(stmt, 5, record.title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, record.promptText, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, record.attachmentsJSON, -1, SQLITE_TRANSIENT)
            if let displayPath = record.projectFolderDisplayPath {
                sqlite3_bind_text(stmt, 8, displayPath, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            sqlite3_bind_int(stmt, 9, record.projectFolderEnabledAtCapture ? 1 : 0)
            sqlite3_bind_int64(stmt, 10, Int64(record.createdAt.timeIntervalSince1970 * 1000))
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    func loadSessionModeSnapshot(sessionID: String) -> SessionModeSnapshotRecord? {
        performSync { db in
            guard let db else { return nil }
            let sql = """
            SELECT snapshot_id, session_id, source_mode_id, captured_at, title, prompt_text,
                   attachments_json, project_folder_display_path,
                   project_folder_enabled_at_capture, created_at
            FROM session_mode_snapshots
            WHERE session_id = ?
            LIMIT 1
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return SessionModeSnapshotRecord(
                snapshotID: columnString(stmt, 0) ?? "",
                sessionID: columnString(stmt, 1) ?? sessionID,
                sourceModeID: columnString(stmt, 2),
                capturedAt: columnDate(stmt, 3),
                title: columnString(stmt, 4) ?? "",
                promptText: columnString(stmt, 5) ?? "",
                attachmentsJSON: columnString(stmt, 6) ?? "[]",
                projectFolderDisplayPath: columnString(stmt, 7),
                projectFolderEnabledAtCapture: sqlite3_column_int(stmt, 8) != 0,
                createdAt: columnDate(stmt, 9)
            )
        }
    }

    func loadSessionModeSnapshot(snapshotID: String) -> SessionModeSnapshotRecord? {
        performSync { db in
            guard let db else { return nil }
            let sql = """
            SELECT snapshot_id, session_id, source_mode_id, captured_at, title, prompt_text,
                   attachments_json, project_folder_display_path,
                   project_folder_enabled_at_capture, created_at
            FROM session_mode_snapshots
            WHERE snapshot_id = ?
            LIMIT 1
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, snapshotID, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return SessionModeSnapshotRecord(
                snapshotID: columnString(stmt, 0) ?? snapshotID,
                sessionID: columnString(stmt, 1) ?? "",
                sourceModeID: columnString(stmt, 2),
                capturedAt: columnDate(stmt, 3),
                title: columnString(stmt, 4) ?? "",
                promptText: columnString(stmt, 5) ?? "",
                attachmentsJSON: columnString(stmt, 6) ?? "[]",
                projectFolderDisplayPath: columnString(stmt, 7),
                projectFolderEnabledAtCapture: sqlite3_column_int(stmt, 8) != 0,
                createdAt: columnDate(stmt, 9)
            )
        }
    }

    // MARK: - Session Summary Persistence

    func saveSessionSummary(_ record: SessionSummaryRecord, actionItems: [SessionSummaryActionItemRecord]) {
        do {
            try performSyncThrowing { [self] db in
                // Summary row and its action items replace together atomically so
                // a failure mid-sequence cannot leave the items deleted but not
                // reinserted.
                try withTransactionThrowing(db) {
                    let exists = try SQLiteStatement(db: db, sql: "SELECT 1 FROM sessions WHERE id = ?")
                    exists.bindText(record.sessionID, at: 1)
                    guard try exists.stepRow() else { return }
                    guard saveSessionSummaryStatements(record, actionItems: actionItems, db: db) else {
                        throw DatabaseError.batchFailed(operation: "saveSessionSummary")
                    }
                }
            }
        } catch {
            reportSwallowedError(error, operation: "saveSessionSummary")
        }
    }

    private func saveSessionSummaryStatements(
        _ record: SessionSummaryRecord,
        actionItems: [SessionSummaryActionItemRecord],
        db: OpaquePointer
    ) -> Bool {
            var succeeded = true
            let summarySQL = """
            INSERT OR REPLACE INTO session_summaries
            (session_id, status, background_summary, follow_up_email, generated_at, error_message, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, summarySQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, record.sessionID, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, record.status, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, record.backgroundSummary, -1, SQLITE_TRANSIENT)
                if let email = record.followUpEmail {
                    sqlite3_bind_text(stmt, 4, email, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                if let generatedAt = record.generatedAt {
                    sqlite3_bind_int64(stmt, 5, Int64(generatedAt.timeIntervalSince1970 * 1000))
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                if let error = record.errorMessage {
                    sqlite3_bind_text(stmt, 6, error, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                sqlite3_bind_int64(stmt, 7, Int64(record.createdAt.timeIntervalSince1970 * 1000))
                sqlite3_bind_int64(stmt, 8, Int64(record.updatedAt.timeIntervalSince1970 * 1000))
                if sqlite3_step(stmt) != SQLITE_DONE {
                    succeeded = false
                }
            }
            sqlite3_finalize(stmt)
            self.replaceActionItems(db: db, sessionID: record.sessionID, items: actionItems)
            return succeeded
    }

    private func replaceActionItems(db: OpaquePointer, sessionID: String, items: [SessionSummaryActionItemRecord]) {
        var deleteStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM session_summary_action_items WHERE session_id = ?", -1, &deleteStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(deleteStmt, 1, sessionID, -1, SQLITE_TRANSIENT)
            sqlite3_step(deleteStmt)
        }
        sqlite3_finalize(deleteStmt)
        let insertSQL = """
        INSERT INTO session_summary_action_items
        (id, session_id, title, owner, due_date, notes, ordinal, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        for item in items {
            var insertStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(insertStmt, 1, item.id, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insertStmt, 2, item.sessionID, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insertStmt, 3, item.title, -1, SQLITE_TRANSIENT)
                bindOptionalText(insertStmt, 4, item.owner)
                bindOptionalText(insertStmt, 5, item.dueDate)
                bindOptionalText(insertStmt, 6, item.notes)
                sqlite3_bind_int(insertStmt, 7, Int32(item.ordinal))
                sqlite3_bind_int64(insertStmt, 8, Int64(item.createdAt.timeIntervalSince1970 * 1000))
                sqlite3_step(insertStmt)
            }
            sqlite3_finalize(insertStmt)
        }
    }

    func loadSessionSummary(sessionID: String) -> (SessionSummaryRecord, [SessionSummaryActionItemRecord])? {
        performSync { db in
            guard let db else { return nil }
            var summary: SessionSummaryRecord?
            let summarySQL = """
            SELECT session_id, status, background_summary, follow_up_email, generated_at, error_message, created_at, updated_at
            FROM session_summaries
            WHERE session_id = ?
            LIMIT 1
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, summarySQL, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    summary = SessionSummaryRecord(
                        sessionID: columnString(stmt, 0) ?? sessionID,
                        status: columnString(stmt, 1) ?? SessionSummary.Status.pending.rawValue,
                        backgroundSummary: columnString(stmt, 2) ?? "",
                        followUpEmail: columnString(stmt, 3),
                        generatedAt: columnOptionalDate(stmt, 4),
                        errorMessage: columnString(stmt, 5),
                        createdAt: columnDate(stmt, 6),
                        updatedAt: columnDate(stmt, 7)
                    )
                }
            }
            sqlite3_finalize(stmt)
            guard let loadedSummary = summary else { return nil }
            let items = loadActionItems(db: db, sessionID: sessionID)
            return (loadedSummary, items)
        }
    }

    private func loadActionItems(db: OpaquePointer, sessionID: String) -> [SessionSummaryActionItemRecord] {
        var results: [SessionSummaryActionItemRecord] = []
        let sql = """
        SELECT id, session_id, title, owner, due_date, notes, ordinal, created_at
        FROM session_summary_action_items
        WHERE session_id = ?
        ORDER BY ordinal ASC
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, sessionID, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(
                    SessionSummaryActionItemRecord(
                        id: columnString(stmt, 0) ?? UUID().uuidString,
                        sessionID: columnString(stmt, 1) ?? sessionID,
                        title: columnString(stmt, 2) ?? "",
                        owner: columnString(stmt, 3),
                        dueDate: columnString(stmt, 4),
                        notes: columnString(stmt, 5),
                        ordinal: Int(sqlite3_column_int(stmt, 6)),
                        createdAt: columnDate(stmt, 7)
                    )
                )
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    // MARK: - Tool Call Persistence

    func logToolCall(_ record: SessionToolCallRecord) {
        performAsync { [self] db in
            guard let db else { return }
            let sql = """
            INSERT INTO session_tool_calls
            (session_id, thread_id, turn_id, tool_name, arguments_json, display_input, result_preview,
             result_content, content_truncated, overflow_path, is_error, iteration, started_at, duration_ms, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, record.sessionID, -1, SQLITE_TRANSIENT)
                self.bindOptionalText(stmt, 2, record.threadID)
                self.bindOptionalText(stmt, 3, record.turnID)
                sqlite3_bind_text(stmt, 4, record.toolName, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, record.argumentsJSON, -1, SQLITE_TRANSIENT)
                self.bindOptionalText(stmt, 6, record.displayInput)
                self.bindOptionalText(stmt, 7, record.resultPreview)
                self.bindOptionalText(stmt, 8, record.resultContent)
                sqlite3_bind_int(stmt, 9, record.contentTruncated ? 1 : 0)
                self.bindOptionalText(stmt, 10, record.overflowPath)
                sqlite3_bind_int(stmt, 11, record.isError ? 1 : 0)
                sqlite3_bind_int(stmt, 12, Int32(record.iteration))
                sqlite3_bind_int64(stmt, 13, Int64(record.startedAt.timeIntervalSince1970 * 1000))
                if let duration = record.durationMs {
                    sqlite3_bind_int(stmt, 14, Int32(duration))
                } else {
                    sqlite3_bind_null(stmt, 14)
                }
                sqlite3_bind_int64(stmt, 15, Int64(Date().timeIntervalSince1970 * 1000))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func loadToolCalls(turnID: String) -> [SessionToolCallRecord] {
        performSync { db in
            guard let db else { return [] }
            let sql = """
            SELECT session_id, thread_id, turn_id, tool_name, arguments_json, display_input, result_preview,
                   result_content, content_truncated, overflow_path, is_error, iteration, started_at, duration_ms
            FROM session_tool_calls
            WHERE turn_id = ?
            ORDER BY iteration ASC, started_at ASC, created_at ASC
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_text(stmt, 1, turnID, -1, SQLITE_TRANSIENT)

            var records: [SessionToolCallRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                records.append(
                    SessionToolCallRecord(
                        sessionID: columnString(stmt, 0) ?? "",
                        threadID: columnString(stmt, 1),
                        turnID: columnString(stmt, 2),
                        toolName: columnString(stmt, 3) ?? "",
                        argumentsJSON: columnString(stmt, 4) ?? "{}",
                        displayInput: columnString(stmt, 5),
                        resultPreview: columnString(stmt, 6),
                        resultContent: columnString(stmt, 7),
                        contentTruncated: sqlite3_column_int(stmt, 8) != 0,
                        overflowPath: columnString(stmt, 9),
                        isError: sqlite3_column_int(stmt, 10) != 0,
                        iteration: Int(sqlite3_column_int(stmt, 11)),
                        startedAt: columnDate(stmt, 12),
                        durationMs: sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 13))
                    )
                )
            }
            return records
        }
    }

    // MARK: - Column helpers

    fileprivate func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    fileprivate func columnDate(_ stmt: OpaquePointer?, _ index: Int32) -> Date {
        Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, index)) / 1000.0)
    }

    fileprivate func columnOptionalDate(_ stmt: OpaquePointer?, _ index: Int32) -> Date? {
        let columnType = sqlite3_column_type(stmt, index)
        if columnType == SQLITE_NULL { return nil }
        return columnDate(stmt, index)
    }

    fileprivate func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
}

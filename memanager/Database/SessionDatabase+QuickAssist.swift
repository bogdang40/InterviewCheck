import Foundation
import SQLite3

extension SessionDatabase {
    // MARK: - Quick Assist Operations
    
    func insertQuickAssistCall(_ call: QuickAssistCallRecord, ownershipID: UUID? = nil) {
        performSync { db in
            guard let db else { return }
            // Direct recordings and branch copies still create their first
            // thread. Tracked provider callbacks require live request ownership.
            if let ownershipID, !consumeQuickAssistCallOwnership(ownershipID, call: call) { return }

            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let sql = """
            INSERT INTO quick_assist_calls
            (session_id, thread_id, turn_id, provider, model, started_at, completed_at, duration_ms,
             is_follow_up, transcript_length, has_screenshot, has_previous_response,
             response_length, status, error_message,
             transcript_text, question, extra_context, request_payload, response_text, raw_response_text, guarded_response_text, previous_response,
             context_mode, model_tier, question_source, route_confidence, verification_status, verification_confidence, unsupported_claim_count,
             verification_missing_questions, verification_suggested_follow_up, policy_version, route_override, evidence_pack_manifest,
             user_feedback_status, user_feedback_note, user_feedback_at, experiment_group_id, candidate_label, base_turn_id, candidate_role, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, call.sessionId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, call.threadId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, call.turnId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, call.provider, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, call.model, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 6, Int64(call.startedAt.timeIntervalSince1970 * 1000))
                if let completedAt = call.completedAt {
                    sqlite3_bind_int64(stmt, 7, Int64(completedAt.timeIntervalSince1970 * 1000))
                } else {
                    sqlite3_bind_null(stmt, 7)
                }
                if let durationMs = call.durationMs {
                    sqlite3_bind_int64(stmt, 8, Int64(durationMs))
                } else {
                    sqlite3_bind_null(stmt, 8)
                }
                sqlite3_bind_int(stmt, 9, call.isFollowUp ? 1 : 0)
                sqlite3_bind_int(stmt, 10, Int32(call.transcriptLength))
                sqlite3_bind_int(stmt, 11, call.hasScreenshot ? 1 : 0)
                sqlite3_bind_int(stmt, 12, call.hasPreviousResponse ? 1 : 0)
                sqlite3_bind_int(stmt, 13, Int32(call.responseLength ?? 0))
                sqlite3_bind_text(stmt, 14, call.status, -1, SQLITE_TRANSIENT)
                if let errorMessage = call.errorMessage {
                    sqlite3_bind_text(stmt, 15, errorMessage, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 15)
                }
                if let transcriptText = call.transcriptText {
                    sqlite3_bind_text(stmt, 16, transcriptText, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 16)
                }
                if let question = call.question {
                    sqlite3_bind_text(stmt, 17, question, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 17)
                }
                if let extraContext = call.extraContext {
                    sqlite3_bind_text(stmt, 18, extraContext, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 18)
                }
                if let requestPayload = call.requestPayload {
                    sqlite3_bind_text(stmt, 19, requestPayload, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 19)
                }
                if let responseText = call.responseText {
                    sqlite3_bind_text(stmt, 20, responseText, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 20)
                }
                if let rawResponseText = call.rawResponseText {
                    sqlite3_bind_text(stmt, 21, rawResponseText, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 21)
                }
                if let guardedResponseText = call.guardedResponseText {
                    sqlite3_bind_text(stmt, 22, guardedResponseText, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 22)
                }
                if let previousResponse = call.previousResponse {
                    sqlite3_bind_text(stmt, 23, previousResponse, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 23)
                }
                sqlite3_bind_text(stmt, 24, call.contextMode.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 25, call.modelTier.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 26, call.questionSource.rawValue, -1, SQLITE_TRANSIENT)
                if let routeConfidence = call.routeConfidence {
                    sqlite3_bind_double(stmt, 27, routeConfidence)
                } else {
                    sqlite3_bind_null(stmt, 27)
                }
                sqlite3_bind_text(stmt, 28, call.verificationStatus.rawValue, -1, SQLITE_TRANSIENT)
                if let verificationConfidence = call.verificationConfidence {
                    sqlite3_bind_double(stmt, 29, verificationConfidence)
                } else {
                    sqlite3_bind_null(stmt, 29)
                }
                if let unsupportedClaimCount = call.unsupportedClaimCount {
                    sqlite3_bind_int64(stmt, 30, Int64(unsupportedClaimCount))
                } else {
                    sqlite3_bind_null(stmt, 30)
                }
                bindOptionalText(encodeStringArray(call.verificationMissingQuestions), at: 31, in: stmt)
                bindOptionalText(call.verificationSuggestedFollowUp, at: 32, in: stmt)
                bindOptionalText(call.policyVersion, at: 33, in: stmt)
                bindOptionalText(call.routeOverride, at: 34, in: stmt)
                bindOptionalText(call.evidencePackManifest, at: 35, in: stmt)
                sqlite3_bind_text(stmt, 36, call.userFeedbackStatus.rawValue, -1, SQLITE_TRANSIENT)
                bindOptionalText(call.userFeedbackNote, at: 37, in: stmt)
                if let userFeedbackAt = call.userFeedbackAt {
                    sqlite3_bind_int64(stmt, 38, Int64(userFeedbackAt.timeIntervalSince1970 * 1000))
                } else {
                    sqlite3_bind_null(stmt, 38)
                }
                bindOptionalText(call.experimentGroupId, at: 39, in: stmt)
                bindOptionalText(call.candidateLabel, at: 40, in: stmt)
                bindOptionalText(call.baseTurnId, at: 41, in: stmt)
                bindOptionalText(call.candidateRole?.rawValue, at: 42, in: stmt)
                sqlite3_bind_int64(stmt, 43, nowMs)

                if sqlite3_step(stmt) != SQLITE_DONE {
                    NSLog("[SessionDatabase] Error inserting quick assist call: \(String(cString: sqlite3_errmsg(db)))")
                }
            }
            sqlite3_finalize(stmt)

            upsertQuickAssistThread(
                threadId: call.threadId,
                originSessionId: call.sessionId,
                titleCandidate: deriveThreadTitle(question: call.question, response: call.responseText),
                updatedAtMs: nowMs,
                db: db
            )
        }
    }

    func createQuickAssistThread(
        threadId: String,
        title: String? = nil,
        originSessionId: String? = nil,
        parentThreadId: String? = nil,
        branchedFromTurnId: String? = nil,
        selectedMode: QuickAssistThreadMode = .auto
    ) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        performSync { db in
            upsertQuickAssistThread(
                threadId: threadId,
                originSessionId: originSessionId,
                titleCandidate: title,
                updatedAtMs: nowMs,
                parentThreadId: parentThreadId,
                branchedFromTurnId: branchedFromTurnId,
                selectedMode: selectedMode,
                db: db
            )
        }
    }

    func updateQuickAssistThreadSelectedMode(
        threadId: String,
        selectedMode: QuickAssistThreadMode
    ) {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        performSync { db in
            guard let db else { return }
            let sql = """
            UPDATE quick_assist_threads
            SET selected_mode = ?, updated_at = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, selectedMode.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, nowMs)
                sqlite3_bind_text(stmt, 3, threadId, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func deleteQuickAssistThread(threadId: String) {
        do {
            try performSyncThrowing { db in
                // All four tables move together: a partial delete strands
                // orphaned calls, policy events, or pins behind a gone thread.
                try withTransactionThrowing(db) {
                    let scopedDeletes = [
                        "DELETE FROM quick_assist_calls WHERE thread_id = ?",
                        "DELETE FROM quick_assist_policy_events WHERE thread_id = ?",
                        "DELETE FROM quick_assist_thread_pins WHERE thread_id = ?",
                        "DELETE FROM quick_assist_threads WHERE id = ?"
                    ]
                    for sql in scopedDeletes {
                        let statement = try SQLiteStatement(db: db, sql: sql)
                        statement.bindText(threadId, at: 1)
                        try statement.executeStep()
                    }
                }
                invalidateQuickAssistCallOwnership(threadIDs: [threadId])
            }
        } catch {
            reportSwallowedError(error, operation: "deleteQuickAssistThread")
        }
    }

    func deleteAllQuickAssistHistory() {
        do {
            try performSyncThrowing { db in
                try withTransactionThrowing(db) {
                    let deletes = [
                        "DELETE FROM quick_assist_calls",
                        "DELETE FROM quick_assist_policy_events",
                        "DELETE FROM quick_assist_thread_pins",
                        "DELETE FROM quick_assist_threads"
                    ]
                    for sql in deletes {
                        let statement = try SQLiteStatement(db: db, sql: sql)
                        try statement.executeStep()
                    }
                }
                quickAssistCallOwners.removeAll()
            }
        } catch {
            reportSwallowedError(error, operation: "deleteAllQuickAssistHistory")
        }
    }

    private func deriveThreadTitle(question: String?, response: String?) -> String? {
        let trimmedQuestion = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedQuestion.isEmpty {
            return String(trimmedQuestion.prefix(80))
        }

        let trimmedResponse = response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedResponse.isEmpty {
            return String(trimmedResponse.prefix(80))
        }
        return nil
    }

    private func upsertQuickAssistThread(
        threadId: String,
        originSessionId: String?,
        titleCandidate: String?,
        updatedAtMs: Int64,
        parentThreadId: String? = nil,
        branchedFromTurnId: String? = nil,
        selectedMode: QuickAssistThreadMode = .auto,
        db: OpaquePointer?
    ) {
        guard let db = db else { return }
        let normalizedTitle = titleCandidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleToStore = (normalizedTitle?.isEmpty == false) ? normalizedTitle : nil

        let insertSQL = """
        INSERT OR IGNORE INTO quick_assist_threads
        (id, created_at, updated_at, title, origin_session_id, parent_thread_id, branched_from_turn_id, selected_mode)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        var insertStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insertSQL, -1, &insertStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(insertStmt, 1, threadId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(insertStmt, 2, updatedAtMs)
            sqlite3_bind_int64(insertStmt, 3, updatedAtMs)
            if let titleToStore {
                sqlite3_bind_text(insertStmt, 4, titleToStore, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(insertStmt, 4)
            }
            if let originSessionId {
                sqlite3_bind_text(insertStmt, 5, originSessionId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(insertStmt, 5)
            }
            if let parentThreadId {
                sqlite3_bind_text(insertStmt, 6, parentThreadId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(insertStmt, 6)
            }
            if let branchedFromTurnId {
                sqlite3_bind_text(insertStmt, 7, branchedFromTurnId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(insertStmt, 7)
            }
            sqlite3_bind_text(insertStmt, 8, selectedMode.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_step(insertStmt)
        }
        sqlite3_finalize(insertStmt)

        let updateSQL = """
        UPDATE quick_assist_threads
        SET updated_at = ?,
            title = CASE
                WHEN (title IS NULL OR TRIM(title) = '') AND ? IS NOT NULL AND TRIM(?) <> '' THEN ?
                ELSE title
            END,
            origin_session_id = COALESCE(origin_session_id, ?),
            parent_thread_id = COALESCE(parent_thread_id, ?),
            branched_from_turn_id = COALESCE(branched_from_turn_id, ?),
            selected_mode = COALESCE(NULLIF(TRIM(selected_mode), ''), ?)
        WHERE id = ?
        """
        var updateStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(updateStmt, 1, updatedAtMs)
            if let titleToStore {
                sqlite3_bind_text(updateStmt, 2, titleToStore, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(updateStmt, 3, titleToStore, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(updateStmt, 4, titleToStore, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(updateStmt, 2)
                sqlite3_bind_null(updateStmt, 3)
                sqlite3_bind_null(updateStmt, 4)
            }
            if let originSessionId {
                sqlite3_bind_text(updateStmt, 5, originSessionId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(updateStmt, 5)
            }
            if let parentThreadId {
                sqlite3_bind_text(updateStmt, 6, parentThreadId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(updateStmt, 6)
            }
            if let branchedFromTurnId {
                sqlite3_bind_text(updateStmt, 7, branchedFromTurnId, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(updateStmt, 7)
            }
            sqlite3_bind_text(updateStmt, 8, selectedMode.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(updateStmt, 9, threadId, -1, SQLITE_TRANSIENT)
            sqlite3_step(updateStmt)
        }
        sqlite3_finalize(updateStmt)
    }
}

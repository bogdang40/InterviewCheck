import Foundation
import SQLite3

extension SessionDatabase {
    func insertQuickAssistPolicyEvent(_ event: QuickAssistPolicyEventRecord) {
        performSync { db in
            guard let db else { return }
            let sql = """
            INSERT INTO quick_assist_policy_events
            (session_id, thread_id, turn_id, policy_version, selected_intent, route_confidence, route_override, decision_vector, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, event.sessionId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, event.threadId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, event.turnId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, event.policyVersion, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, event.selectedIntent.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 6, event.routeConfidence)
                bindOptionalText(event.routeOverride?.rawValue, at: 7, in: stmt)
                bindOptionalText(event.decisionVector, at: 8, in: stmt)
                sqlite3_bind_int64(stmt, 9, Int64(event.createdAt.timeIntervalSince1970 * 1000))
                if sqlite3_step(stmt) != SQLITE_DONE {
                    NSLog("[SessionDatabase] Error inserting quick assist policy event: \(String(cString: sqlite3_errmsg(db)))")
                }
            }
            sqlite3_finalize(stmt)
        }
    }

    func updateQuickAssistCallVerification(
        threadId: String,
        turnId: String,
        verification: QuickAssistVerificationRecord
    ) {
        performSync { db in
            guard let db else { return }
            let sql = """
            UPDATE quick_assist_calls
            SET verification_status = ?,
                verification_confidence = ?,
                unsupported_claim_count = ?,
                verification_missing_questions = ?,
                verification_suggested_follow_up = ?
            WHERE id = (
                SELECT id
                FROM quick_assist_calls
                WHERE thread_id = ? AND turn_id = ?
                ORDER BY started_at DESC
                LIMIT 1
            )
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, verification.status.rawValue, -1, SQLITE_TRANSIENT)
                if let confidence = verification.confidence {
                    sqlite3_bind_double(stmt, 2, confidence)
                } else {
                    sqlite3_bind_null(stmt, 2)
                }
                sqlite3_bind_int64(stmt, 3, Int64(verification.unsupportedClaimCount))
                bindOptionalText(encodeStringArray(verification.missingQuestions), at: 4, in: stmt)
                bindOptionalText(verification.suggestedFollowUp, at: 5, in: stmt)
                sqlite3_bind_text(stmt, 6, threadId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 7, turnId, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    NSLog("[SessionDatabase] Error updating quick assist verification: \(String(cString: sqlite3_errmsg(db)))")
                }
            }
            sqlite3_finalize(stmt)
        }
    }

    func updateQuickAssistCallFeedback(
        threadId: String,
        turnId: String,
        status: QuickAssistTurnFeedbackStatus,
        note: String?,
        feedbackAt: Date
    ) {
        performSync { db in
            guard let db else { return }
            let sql = """
            UPDATE quick_assist_calls
            SET user_feedback_status = ?,
                user_feedback_note = ?,
                user_feedback_at = ?
            WHERE id = (
                SELECT id
                FROM quick_assist_calls
                WHERE thread_id = ? AND turn_id = ?
                ORDER BY started_at DESC
                LIMIT 1
            )
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
                bindOptionalText(note, at: 2, in: stmt)
                sqlite3_bind_int64(stmt, 3, Int64(feedbackAt.timeIntervalSince1970 * 1000))
                sqlite3_bind_text(stmt, 4, threadId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, turnId, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    NSLog("[SessionDatabase] Error updating quick assist feedback: \(String(cString: sqlite3_errmsg(db)))")
                }
            }
            sqlite3_finalize(stmt)
        }
    }

    func insertQuickAssistExperiment(
        id: String,
        sessionId: String,
        sourceThreadId: String,
        sourceTurnId: String,
        selectedIntent: QuickAssistIntent?,
        routeConfidence: Double?,
        status: QuickAssistExperimentStatus
    ) {
        performSync { db in
            guard let db else { return }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let sql = """
            INSERT OR REPLACE INTO quick_assist_experiments
            (id, session_id, source_thread_id, source_turn_id, selected_intent, route_confidence, status, winner_candidate_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, COALESCE((SELECT winner_candidate_id FROM quick_assist_experiments WHERE id = ?), NULL), COALESCE((SELECT created_at FROM quick_assist_experiments WHERE id = ?), ?), ?)
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, sessionId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, sourceThreadId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, sourceTurnId, -1, SQLITE_TRANSIENT)
                bindOptionalText(selectedIntent?.rawValue, at: 5, in: stmt)
                if let routeConfidence {
                    sqlite3_bind_double(stmt, 6, routeConfidence)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                sqlite3_bind_text(stmt, 7, status.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 8, id, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 9, id, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 10, nowMs)
                sqlite3_bind_int64(stmt, 11, nowMs)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func updateQuickAssistExperiment(
        id: String,
        status: QuickAssistExperimentStatus,
        winnerCandidateId: String?
    ) {
        performSync { db in
            guard let db else { return }
            let sql = """
            UPDATE quick_assist_experiments
            SET status = ?, winner_candidate_id = ?, updated_at = ?
            WHERE id = ?
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
                bindOptionalText(winnerCandidateId, at: 2, in: stmt)
                sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970 * 1000))
                sqlite3_bind_text(stmt, 4, id, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func loadQuickAssistExperiment(id: String) -> QuickAssistExperiment? {
        var experiment: QuickAssistExperiment?
        performSync { db in
            guard let db else { return }
            let sql = """
            SELECT session_id, source_thread_id, source_turn_id, selected_intent, route_confidence, status, winner_candidate_id, created_at, updated_at
            FROM quick_assist_experiments
            WHERE id = ?
            LIMIT 1
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let sessionId = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                    let sourceThreadId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let sourceTurnId = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    let selectedIntent = sqlite3_column_text(stmt, 3).map { String(cString: $0) }.flatMap(QuickAssistIntent.init(rawValue:))
                    let routeConfidence = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 4)
                    let status = sqlite3_column_text(stmt, 5).map { String(cString: $0) }.flatMap(QuickAssistExperimentStatus.init(rawValue:)) ?? .running
                    let winnerCandidateId = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                    let createdAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 7)) / 1000)
                    let updatedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 8)) / 1000)
                    let candidates = loadQuickAssistExperimentCandidates(db: db, experimentId: id, winnerCandidateId: winnerCandidateId)
                    experiment = QuickAssistExperiment(
                        id: id,
                        sessionId: sessionId,
                        sourceThreadId: sourceThreadId,
                        sourceTurnId: sourceTurnId,
                        status: status,
                        selectedIntent: selectedIntent,
                        routeConfidence: routeConfidence,
                        winnerCandidateId: winnerCandidateId,
                        createdAt: createdAt,
                        updatedAt: updatedAt,
                        candidates: candidates
                    )
                }
            }
            sqlite3_finalize(stmt)
        }
        return experiment
    }

    func setQuickAssistThreadPin(
        threadId: String,
        memoryNodeId: String,
        pinned: Bool
    ) {
        let normalizedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNodeId = memoryNodeId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadId.isEmpty, !normalizedNodeId.isEmpty else { return }

        performSync { db in
            guard let db else { return }
            let sql: String
            if pinned {
                sql = """
                INSERT OR REPLACE INTO quick_assist_thread_pins (thread_id, memory_node_id, created_at)
                VALUES (?, ?, ?)
                """
            } else {
                sql = "DELETE FROM quick_assist_thread_pins WHERE thread_id = ? AND memory_node_id = ?"
            }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, normalizedThreadId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, normalizedNodeId, -1, SQLITE_TRANSIENT)
                if pinned {
                    sqlite3_bind_int64(stmt, 3, Int64(Date().timeIntervalSince1970 * 1000))
                }
                if sqlite3_step(stmt) != SQLITE_DONE {
                    NSLog("[SessionDatabase] Error updating quick assist thread pin: \(String(cString: sqlite3_errmsg(db)))")
                }
            }
            sqlite3_finalize(stmt)
        }
    }

    func getQuickAssistThreadPins(threadId: String) -> Set<String> {
        let normalizedThreadId = threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedThreadId.isEmpty else { return [] }

        var pins = Set<String>()
        performSync { db in
            guard let db else { return }
            let sql = """
            SELECT memory_node_id
            FROM quick_assist_thread_pins
            WHERE thread_id = ?
            ORDER BY created_at ASC
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, normalizedThreadId, -1, SQLITE_TRANSIENT)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let value = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) {
                        pins.insert(value)
                    }
                }
            }
            sqlite3_finalize(stmt)
        }
        return pins
    }

    private func loadQuickAssistExperimentCandidates(
        db: OpaquePointer,
        experimentId: String,
        winnerCandidateId: String?
    ) -> [QuickAssistCandidate] {
        var calls: [QuickAssistCallRecord] = []
        let sql = """
        SELECT id, session_id, thread_id, turn_id, provider, model, started_at, completed_at, duration_ms,
               is_follow_up, transcript_length, has_screenshot, has_previous_response,
               response_length, status, error_message, transcript_text, question, extra_context,
               request_payload, response_text, raw_response_text, guarded_response_text, previous_response, context_mode, model_tier, question_source,
               route_confidence, verification_status, verification_confidence, unsupported_claim_count, verification_missing_questions,
               verification_suggested_follow_up, policy_version, route_override, evidence_pack_manifest,
               user_feedback_status, user_feedback_note, user_feedback_at, experiment_group_id, candidate_label, base_turn_id, candidate_role
        FROM quick_assist_calls
        WHERE experiment_group_id = ?
          AND candidate_role IS NOT NULL
        ORDER BY started_at ASC
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, experimentId, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                calls.append(makeQuickAssistCallRecord(from: stmt))
            }
        }
        sqlite3_finalize(stmt)

        let scorer = QuickAssistOutcomeScorer()
        let grouped = Dictionary(grouping: calls, by: { $0.threadId })
        let latestCalls = grouped.values.compactMap(\.last)
        return latestCalls
            .map { call in
                let score = scorer.score(call: call, preferredProvider: nil)
                return QuickAssistCandidate(
                    id: call.turnId,
                    threadId: call.threadId,
                    turnId: call.turnId,
                    label: call.candidateLabel ?? call.candidateRole?.displayLabel ?? "Candidate",
                    role: call.candidateRole ?? .currentRoute,
                    provider: call.provider,
                    model: call.model,
                    modelTier: call.modelTier,
                    verificationStatus: call.verificationStatus,
                    unsupportedClaimCount: call.unsupportedClaimCount ?? 0,
                    feedbackStatus: call.userFeedbackStatus,
                    latencyMs: call.durationMs,
                    score: score,
                    isWinner: winnerCandidateId == call.turnId
                )
            }
            .sorted {
                if $0.score.total == $1.score.total {
                    let lhsLatency = $0.latencyMs ?? Int.max
                    let rhsLatency = $1.latencyMs ?? Int.max
                    if lhsLatency == rhsLatency {
                        return $0.provider < $1.provider
                    }
                    return lhsLatency < rhsLatency
                }
                return $0.score.total > $1.score.total
            }
    }
}

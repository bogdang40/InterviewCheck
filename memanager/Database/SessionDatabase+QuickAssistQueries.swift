import Foundation
import SQLite3

extension SessionDatabase {
    func getRecentQuickAssistCalls(limit: Int = 200) -> [QuickAssistCallRecord] {
        var calls: [QuickAssistCallRecord] = []

        performSync { db in
            guard let db else { return }

            let sql = """
            SELECT id, session_id, thread_id, turn_id, provider, model, started_at, completed_at, duration_ms,
                   is_follow_up, transcript_length, has_screenshot, has_previous_response,
                   response_length, status, error_message, transcript_text, question, extra_context,
                   request_payload, response_text, raw_response_text, guarded_response_text, previous_response, context_mode, model_tier, question_source,
                   route_confidence, verification_status, verification_confidence, unsupported_claim_count, verification_missing_questions,
                   verification_suggested_follow_up, policy_version, route_override, evidence_pack_manifest,
                   user_feedback_status, user_feedback_note, user_feedback_at, experiment_group_id, candidate_label, base_turn_id, candidate_role
            FROM quick_assist_calls
            ORDER BY started_at DESC
            LIMIT ?
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(limit))

                while sqlite3_step(stmt) == SQLITE_ROW {
                    calls.append(makeQuickAssistCallRecord(from: stmt))
                }
            }
            sqlite3_finalize(stmt)
        }

        return calls
    }

    func getQuickAssistCallsForSession(sessionId: String, limit: Int = 100) -> [QuickAssistCallRecord] {
        var calls: [QuickAssistCallRecord] = []

        performSync { db in
            guard let db else { return }

            let sql = """
            SELECT id, session_id, thread_id, turn_id, provider, model, started_at, completed_at, duration_ms,
                   is_follow_up, transcript_length, has_screenshot, has_previous_response,
                   response_length, status, error_message, transcript_text, question, extra_context,
                   request_payload, response_text, raw_response_text, guarded_response_text, previous_response, context_mode, model_tier, question_source,
                   route_confidence, verification_status, verification_confidence, unsupported_claim_count, verification_missing_questions,
                   verification_suggested_follow_up, policy_version, route_override, evidence_pack_manifest,
                   user_feedback_status, user_feedback_note, user_feedback_at, experiment_group_id, candidate_label, base_turn_id, candidate_role
            FROM quick_assist_calls
            WHERE session_id = ?
            ORDER BY started_at DESC
            LIMIT ?
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 2, Int32(limit))

                while sqlite3_step(stmt) == SQLITE_ROW {
                    calls.append(makeQuickAssistCallRecord(from: stmt))
                }
            }
            sqlite3_finalize(stmt)
        }

        return calls
    }

    /// Single turn fetch by (thread, turn); uses idx_quick_assist_thread_id_started_at.
    func getQuickAssistCall(threadId: String, turnId: String) -> QuickAssistCallRecord? {
        performSync { db in
            guard let db else { return nil }

            let sql = """
            SELECT id, session_id, thread_id, turn_id, provider, model, started_at, completed_at, duration_ms,
                   is_follow_up, transcript_length, has_screenshot, has_previous_response,
                   response_length, status, error_message, transcript_text, question, extra_context,
                   request_payload, response_text, raw_response_text, guarded_response_text, previous_response, context_mode, model_tier, question_source,
                   route_confidence, verification_status, verification_confidence, unsupported_claim_count, verification_missing_questions,
                   verification_suggested_follow_up, policy_version, route_override, evidence_pack_manifest,
                   user_feedback_status, user_feedback_note, user_feedback_at, experiment_group_id, candidate_label, base_turn_id, candidate_role
            FROM quick_assist_calls
            WHERE thread_id = ? AND turn_id = ?
            LIMIT 1
            """

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            sqlite3_bind_text(stmt, 1, threadId, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, turnId, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            return makeQuickAssistCallRecord(from: stmt)
        }
    }

    func getQuickAssistCallsForThread(threadId: String, limit: Int = 0) -> [QuickAssistCallRecord] {
        var calls: [QuickAssistCallRecord] = []

        performSync { db in
            guard let db else { return }

            var sql = """
            SELECT id, session_id, thread_id, turn_id, provider, model, started_at, completed_at, duration_ms,
                   is_follow_up, transcript_length, has_screenshot, has_previous_response,
                   response_length, status, error_message, transcript_text, question, extra_context,
                   request_payload, response_text, raw_response_text, guarded_response_text, previous_response, context_mode, model_tier, question_source,
                   route_confidence, verification_status, verification_confidence, unsupported_claim_count, verification_missing_questions,
                   verification_suggested_follow_up, policy_version, route_override, evidence_pack_manifest,
                   user_feedback_status, user_feedback_note, user_feedback_at, experiment_group_id, candidate_label, base_turn_id, candidate_role
            FROM quick_assist_calls
            WHERE thread_id = ?
            ORDER BY started_at ASC
            """
            if limit > 0 {
                sql += "\nLIMIT ?"
            }

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, threadId, -1, SQLITE_TRANSIENT)
                if limit > 0 {
                    sqlite3_bind_int(stmt, 2, Int32(limit))
                }

                while sqlite3_step(stmt) == SQLITE_ROW {
                    calls.append(makeQuickAssistCallRecord(from: stmt))
                }
            }
            sqlite3_finalize(stmt)
        }

        return calls
    }

    func makeQuickAssistCallRecord(from stmt: OpaquePointer?) -> QuickAssistCallRecord {
        let id = Int64(sqlite3_column_int64(stmt, 0))
        let sessionId = String(cString: sqlite3_column_text(stmt, 1))
        let threadId = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? sessionId
        let turnId = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? UUID().uuidString
        let provider = String(cString: sqlite3_column_text(stmt, 4))
        let model = String(cString: sqlite3_column_text(stmt, 5))
        let startedAt = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 6)) / 1000)
        let completedAt: Date? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 7)) / 1000)
        let durationMs: Int? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int64(stmt, 8))
        let isFollowUp = sqlite3_column_int(stmt, 9) == 1
        let transcriptLength = Int(sqlite3_column_int(stmt, 10))
        let hasScreenshot = sqlite3_column_int(stmt, 11) == 1
        let hasPreviousResponse = sqlite3_column_int(stmt, 12) == 1
        let responseLength = sqlite3_column_type(stmt, 13) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 13)) : nil
        let status = String(cString: sqlite3_column_text(stmt, 14))
        let errorMessage = sqlite3_column_text(stmt, 15).map { String(cString: $0) }
        let transcriptText = sqlite3_column_text(stmt, 16).map { String(cString: $0) }
        let question = sqlite3_column_text(stmt, 17).map { String(cString: $0) }
        let extraContext = sqlite3_column_text(stmt, 18).map { String(cString: $0) }
        let requestPayload = sqlite3_column_text(stmt, 19).map { String(cString: $0) }
        let responseText = sqlite3_column_text(stmt, 20).map { String(cString: $0) }
        let rawResponseText = sqlite3_column_text(stmt, 21).map { String(cString: $0) }
        let guardedResponseText = sqlite3_column_text(stmt, 22).map { String(cString: $0) }
        let previousResponse = sqlite3_column_text(stmt, 23).map { String(cString: $0) }
        let contextModeRaw = sqlite3_column_text(stmt, 24).map { String(cString: $0) }
        let modelTierRaw = sqlite3_column_text(stmt, 25).map { String(cString: $0) }
        let questionSourceRaw = sqlite3_column_text(stmt, 26).map { String(cString: $0) }
        let routeConfidence: Double? = sqlite3_column_type(stmt, 27) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(stmt, 27)
        let verificationStatusRaw = sqlite3_column_text(stmt, 28).map { String(cString: $0) }
        let verificationConfidence: Double? = sqlite3_column_type(stmt, 29) == SQLITE_NULL
            ? nil
            : sqlite3_column_double(stmt, 29)
        let unsupportedClaimCount: Int? = sqlite3_column_type(stmt, 30) == SQLITE_NULL
            ? nil
            : Int(sqlite3_column_int64(stmt, 30))
        let verificationMissingQuestionsRaw = sqlite3_column_text(stmt, 31).map { String(cString: $0) }
        let verificationSuggestedFollowUp = sqlite3_column_text(stmt, 32).map { String(cString: $0) }
        let policyVersion = sqlite3_column_text(stmt, 33).map { String(cString: $0) }
        let routeOverride = sqlite3_column_text(stmt, 34).map { String(cString: $0) }
        let evidencePackManifest = sqlite3_column_text(stmt, 35).map { String(cString: $0) }
        let userFeedbackStatusRaw = sqlite3_column_text(stmt, 36).map { String(cString: $0) }
        let userFeedbackNote = sqlite3_column_text(stmt, 37).map { String(cString: $0) }
        let userFeedbackAt: Date? = sqlite3_column_type(stmt, 38) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 38)) / 1000)
        let experimentGroupId = sqlite3_column_text(stmt, 39).map { String(cString: $0) }
        let candidateLabel = sqlite3_column_text(stmt, 40).map { String(cString: $0) }
        let baseTurnId = sqlite3_column_text(stmt, 41).map { String(cString: $0) }
        let candidateRoleRaw = sqlite3_column_text(stmt, 42).map { String(cString: $0) }

        return QuickAssistCallRecord(
            id: id,
            sessionId: sessionId,
            threadId: threadId,
            turnId: turnId,
            provider: provider,
            model: model,
            startedAt: startedAt,
            completedAt: completedAt,
            durationMs: durationMs,
            isFollowUp: isFollowUp,
            transcriptLength: transcriptLength,
            hasScreenshot: hasScreenshot,
            hasPreviousResponse: hasPreviousResponse,
            responseLength: responseLength,
            status: status,
            errorMessage: errorMessage,
            transcriptText: transcriptText,
            question: question,
            extraContext: extraContext,
            requestPayload: requestPayload,
            responseText: responseText,
            rawResponseText: rawResponseText,
            guardedResponseText: guardedResponseText,
            previousResponse: previousResponse,
            contextMode: QuickAssistContextMode(rawValue: contextModeRaw ?? "") ?? .conversation,
            modelTier: QuickAssistModelTier(rawValue: modelTierRaw ?? "") ?? .fast,
            questionSource: QuickAssistQuestionSource(rawValue: questionSourceRaw ?? "") ?? .none,
            routeConfidence: routeConfidence,
            verificationStatus: QuickAssistVerificationStatus(rawValue: verificationStatusRaw ?? "") ?? .pending,
            verificationConfidence: verificationConfidence,
            unsupportedClaimCount: unsupportedClaimCount,
            verificationMissingQuestions: decodeStringArray(verificationMissingQuestionsRaw),
            verificationSuggestedFollowUp: verificationSuggestedFollowUp,
            policyVersion: policyVersion,
            routeOverride: routeOverride,
            evidencePackManifest: evidencePackManifest,
            userFeedbackStatus: QuickAssistTurnFeedbackStatus(rawValue: userFeedbackStatusRaw ?? "") ?? .none,
            userFeedbackNote: userFeedbackNote,
            userFeedbackAt: userFeedbackAt,
            experimentGroupId: experimentGroupId,
            candidateLabel: candidateLabel,
            baseTurnId: baseTurnId,
            candidateRole: candidateRoleRaw.flatMap(QuickAssistCandidateRole.init(rawValue:))
        )
    }
}

import Foundation
import SQLite3

extension SessionDatabase {
    // MARK: - Practice Operations

    func loadPracticeState() -> (cards: [PracticeCard], schedules: [PracticeSchedule], reviews: [PracticeReview]) {
        var cards: [PracticeCard] = []
        var schedules: [PracticeSchedule] = []
        var reviews: [PracticeReview] = []

        performSync { db in
            guard let db else { return }

            let cardSQL = """
            SELECT id, created_at, session_id, topic_tag, prompt, ideal_reasoning,
                   transcript_snippet, candidate_attempt_summary, difficulty,
                   evidence_kind, evidence_value, is_archived
            FROM practice_cards
            ORDER BY created_at ASC
            """
            var cardStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, cardSQL, -1, &cardStmt, nil) == SQLITE_OK {
                while sqlite3_step(cardStmt) == SQLITE_ROW {
                    cards.append(makePracticeCard(from: cardStmt))
                }
            }
            sqlite3_finalize(cardStmt)

            let scheduleSQL = """
            SELECT card_id, repetition_count, easiness, interval_days, next_review_at, lapses, last_reviewed_at
            FROM practice_schedules
            ORDER BY next_review_at ASC
            """
            var scheduleStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, scheduleSQL, -1, &scheduleStmt, nil) == SQLITE_OK {
                while sqlite3_step(scheduleStmt) == SQLITE_ROW {
                    schedules.append(makePracticeSchedule(from: scheduleStmt))
                }
            }
            sqlite3_finalize(scheduleStmt)

            let reviewSQL = """
            SELECT id, card_id, reviewed_at, grade, duration_ms, self_reported_confidence, feedback, attempt_transcript
            FROM practice_reviews
            ORDER BY reviewed_at ASC
            """
            var reviewStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, reviewSQL, -1, &reviewStmt, nil) == SQLITE_OK {
                while sqlite3_step(reviewStmt) == SQLITE_ROW {
                    reviews.append(makePracticeReview(from: reviewStmt))
                }
            }
            sqlite3_finalize(reviewStmt)
        }

        return (cards, schedules, reviews)
    }

    func upsertPracticeCard(_ card: PracticeCard, schedule: PracticeSchedule) {
        do {
            try performSyncThrowing { db in
                // Card and schedule commit together so SM-2 state can never
                // exist for a card that failed to persist (or vice versa).
                try withTransactionThrowing(db) {
                    upsertPracticeCard(card, db: db)
                    try upsertPracticeSchedule(schedule, db: db)
                }
            }
        } catch {
            reportSwallowedError(error, operation: "upsertPracticeCard")
        }
    }

    func insertPracticeReview(_ review: PracticeReview, schedule: PracticeSchedule) {
        do {
            try insertPracticeReviewReporting(review, schedule: schedule)
        } catch {
            reportSwallowedError(error, operation: "insertPracticeReview")
        }
    }

    func insertPracticeReviewReporting(_ review: PracticeReview, schedule: PracticeSchedule) throws {
            try performSyncThrowing { db in
                // Review log and schedule update commit together: a crash
                // between them desynced SM-2 state from review history.
                try withTransactionThrowing(db) {
                    let sql = """
                    INSERT OR REPLACE INTO practice_reviews
                    (id, card_id, reviewed_at, grade, duration_ms, self_reported_confidence, feedback, attempt_transcript, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                    let statement = try SQLiteStatement(db: db, sql: sql)
                    statement.bindText(review.id, at: 1)
                    statement.bindText(review.cardID, at: 2)
                    statement.bindMillis(review.reviewedAt, at: 3)
                    statement.bindInt(review.grade.rawValue, at: 4)
                    statement.bindInt(review.durationMs, at: 5)
                    if let confidence = review.selfReportedConfidence {
                        statement.bindInt(confidence, at: 6)
                    } else {
                        statement.bindNull(at: 6)
                    }
                    statement.bindOptionalText(review.feedback, at: 7)
                    statement.bindOptionalText(review.attemptTranscript, at: 8)
                    statement.bindMillis(Date(), at: 9)
                    try statement.executeStep()

                    try upsertPracticeSchedule(schedule, db: db)
                }
            }
    }

    func archivePracticeCard(cardID: String) {
        performSync { db in
            guard let db else { return }
            let sql = "UPDATE practice_cards SET is_archived = 1 WHERE id = ?"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, cardID, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func clearPracticeData() {
        do {
            try performSyncThrowing { db in
                try withTransactionThrowing(db) {
                    for sql in [
                        "DELETE FROM practice_reviews",
                        "DELETE FROM practice_schedules",
                        "DELETE FROM practice_cards"
                    ] {
                        let statement = try SQLiteStatement(db: db, sql: sql)
                        try statement.executeStep()
                    }
                }
            }
        } catch {
            reportSwallowedError(error, operation: "clearPracticeData")
        }
    }

    private func upsertPracticeCard(_ card: PracticeCard, db: OpaquePointer) {
        let evidence = encodePracticeEvidence(card.sourceEvidence)
        let sql = """
        INSERT OR REPLACE INTO practice_cards
        (id, created_at, session_id, topic_tag, prompt, ideal_reasoning, transcript_snippet,
         candidate_attempt_summary, difficulty, evidence_kind, evidence_value, is_archived)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, card.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(card.createdAt.timeIntervalSince1970 * 1000))
            sqlite3_bind_text(stmt, 3, card.sessionID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, card.topicTag, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, card.prompt, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, card.idealReasoning, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, card.transcriptSnippet, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, card.candidateAttemptSummary, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 9, card.difficulty.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 10, evidence.kind, -1, SQLITE_TRANSIENT)
            bindOptionalText(evidence.value, at: 11, in: stmt)
            sqlite3_bind_int(stmt, 12, card.isArchived ? 1 : 0)

            if sqlite3_step(stmt) != SQLITE_DONE {
                NSLog("[SessionDatabase] Error upserting practice card: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        sqlite3_finalize(stmt)
    }

    private func upsertPracticeSchedule(_ schedule: PracticeSchedule, db: OpaquePointer) throws {
        let statement = try SQLiteStatement(db: db, sql: """
        INSERT OR REPLACE INTO practice_schedules
        (card_id, repetition_count, easiness, interval_days, next_review_at, lapses, last_reviewed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """)
        statement.bindText(schedule.cardID, at: 1)
        statement.bindInt(schedule.repetitionCount, at: 2)
        statement.bindDouble(schedule.easiness, at: 3)
        statement.bindInt(schedule.intervalDays, at: 4)
        statement.bindMillis(schedule.nextReviewAt, at: 5)
        statement.bindInt(schedule.lapses, at: 6)
        if let lastReviewedAt = schedule.lastReviewedAt {
            statement.bindMillis(lastReviewedAt, at: 7)
        } else {
            statement.bindNull(at: 7)
        }
        try statement.executeStep()
    }

    private func makePracticeCard(from stmt: OpaquePointer?) -> PracticeCard {
        let evidenceKind = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? "manual"
        let evidenceValue = sqlite3_column_text(stmt, 10).map { String(cString: $0) }
        let difficultyRaw = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? PracticeDifficulty.medium.rawValue
        return PracticeCard(
            id: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString,
            createdAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1)) / 1000),
            sessionID: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
            topicTag: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "practice",
            prompt: sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "",
            idealReasoning: sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "",
            transcriptSnippet: sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "",
            candidateAttemptSummary: sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "",
            difficulty: PracticeDifficulty(rawValue: difficultyRaw) ?? .medium,
            sourceEvidence: decodePracticeEvidence(kind: evidenceKind, value: evidenceValue),
            isArchived: sqlite3_column_int(stmt, 11) != 0
        )
    }

    private func makePracticeSchedule(from stmt: OpaquePointer?) -> PracticeSchedule {
        let lastReviewedAt = sqlite3_column_type(stmt, 6) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 6)) / 1000)
        return PracticeSchedule(
            cardID: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "",
            repetitionCount: Int(sqlite3_column_int(stmt, 1)),
            easiness: sqlite3_column_double(stmt, 2),
            intervalDays: Int(sqlite3_column_int(stmt, 3)),
            nextReviewAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4)) / 1000),
            lapses: Int(sqlite3_column_int(stmt, 5)),
            lastReviewedAt: lastReviewedAt
        )
    }

    private func makePracticeReview(from stmt: OpaquePointer?) -> PracticeReview {
        let gradeRaw = Int(sqlite3_column_int(stmt, 3))
        let confidence = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 5))
        return PracticeReview(
            id: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? UUID().uuidString,
            cardID: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
            reviewedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)) / 1000),
            grade: PracticeGrade(rawValue: gradeRaw) ?? .blackout,
            durationMs: Int(sqlite3_column_int(stmt, 4)),
            selfReportedConfidence: confidence,
            feedback: sqlite3_column_text(stmt, 6).map { String(cString: $0) },
            attemptTranscript: sqlite3_column_text(stmt, 7).map { String(cString: $0) }
        )
    }

    private func encodePracticeEvidence(_ evidence: PracticeEvidence) -> (kind: String, value: String?) {
        switch evidence {
        case .drill(let drillID):
            return ("drill", drillID)
        case .coachFinding(let findingID):
            return ("coach_finding", findingID)
        case .pacingStall(let timestamp):
            return ("pacing_stall", String(Int64(timestamp.timeIntervalSince1970 * 1000)))
        case .lowConfidenceTranscript(let entryID):
            return ("low_confidence_transcript", entryID)
        case .manual:
            return ("manual", nil)
        }
    }

    private func decodePracticeEvidence(kind: String, value: String?) -> PracticeEvidence {
        switch kind {
        case "drill":
            return .drill(drillID: value ?? "")
        case "coach_finding":
            return .coachFinding(findingID: value ?? "")
        case "pacing_stall":
            let timestampMs = value.flatMap(Double.init) ?? 0
            return .pacingStall(timestamp: Date(timeIntervalSince1970: timestampMs / 1000))
        case "low_confidence_transcript":
            return .lowConfidenceTranscript(entryID: value ?? "")
        default:
            return .manual
        }
    }
}

import Foundation
import SQLite3

/// Reads and writes for the cheating detector's interview tables.
extension SessionDatabase {
    func saveInterview(_ interview: InterviewRecord) {
        interviewWrite("saveInterview", """
            INSERT OR REPLACE INTO interviews
            (id, workspace_id, role_title, candidate_name, consent_confirmed_at, started_at, ended_at,
             overall_percent, flagged_count, question_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            statement.bindText(interview.id, at: 1)
            statement.bindOptionalText(interview.workspaceID, at: 2)
            statement.bindText(interview.roleTitle, at: 3)
            statement.bindText(interview.candidateName, at: 4)
            statement.bindOptionalMillis(interview.consentConfirmedAt, at: 5)
            statement.bindMillis(interview.startedAt, at: 6)
            statement.bindOptionalMillis(interview.endedAt, at: 7)
            statement.bindOptionalInt64(interview.overallPercent.map(Int64.init), at: 8)
            statement.bindInt(interview.flaggedCount, at: 9)
            statement.bindInt(interview.questionCount, at: 10)
        }
    }

    /// Appends words; `origin` is the host time the interview started.
    func appendInterviewWords(_ words: [TimedWord], interviewID: String, origin: TimeInterval) {
        guard !words.isEmpty else { return }
        do {
            try performSyncThrowing { db in
                try withTransactionThrowing(db) {
                    let statement = try SQLiteStatement(db: db, sql: """
                        INSERT INTO interview_words
                        (interview_id, side, speaker_index, text, start_ms, end_ms, confidence, is_filler)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """)
                    for word in words {
                        statement.reset()
                        statement.bindText(interviewID, at: 1)
                        statement.bindText(word.side.rawValue, at: 2)
                        statement.bindOptionalInt64(word.speakerIndex.map(Int64.init), at: 3)
                        statement.bindText(word.text, at: 4)
                        statement.bindInt64(Self.millis(word.start - origin), at: 5)
                        statement.bindInt64(Self.millis(word.end - origin), at: 6)
                        if let confidence = word.confidence {
                            statement.bindDouble(confidence, at: 7)
                        } else {
                            statement.bindNull(at: 7)
                        }
                        statement.bindBool(word.isFiller, at: 8)
                        try statement.executeStep()
                    }
                }
            }
        } catch {
            reportSwallowedError(error, operation: "appendInterviewWords")
        }
    }

    func saveInterviewQuestion(_ question: InterviewQuestionRecord) {
        interviewWrite("saveInterviewQuestion", """
            INSERT OR REPLACE INTO interview_questions
            (id, interview_id, ordinal, text, source, marked_at_ms, question_end_ms, answer_start_ms,
             answer_end_ms, closed_at_ms, answer_text)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            statement.bindText(question.id, at: 1)
            statement.bindText(question.interviewID, at: 2)
            statement.bindInt(question.ordinal, at: 3)
            statement.bindText(question.text, at: 4)
            statement.bindText(question.source.rawValue, at: 5)
            statement.bindInt64(Self.millis(question.markedAt), at: 6)
            statement.bindOptionalInt64(question.questionEnd.map(Self.millis), at: 7)
            statement.bindOptionalInt64(question.answerStart.map(Self.millis), at: 8)
            statement.bindOptionalInt64(question.answerEnd.map(Self.millis), at: 9)
            statement.bindOptionalInt64(question.closedAt.map(Self.millis), at: 10)
            statement.bindText(question.answerText, at: 11)
        }
    }

    func saveReferenceAnswer(_ answer: ReferenceAnswerRecord) {
        interviewWrite("saveReferenceAnswer", """
            INSERT OR REPLACE INTO reference_answers
            (id, question_id, provider, model, prompt_name, text, first_sentence_ms, total_ms, error)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            statement.bindText(answer.id, at: 1)
            statement.bindText(answer.questionID, at: 2)
            statement.bindText(answer.provider.rawValue, at: 3)
            statement.bindText(answer.model, at: 4)
            statement.bindText(answer.promptName, at: 5)
            statement.bindText(answer.text, at: 6)
            statement.bindOptionalInt64(answer.firstSentenceSeconds.map(Self.millis), at: 7)
            statement.bindOptionalInt64(answer.totalSeconds.map(Self.millis), at: 8)
            statement.bindOptionalText(answer.error, at: 9)
        }
    }

    func saveAnswerScore(_ score: AnswerScoreRecord) {
        interviewWrite("saveAnswerScore", """
            INSERT OR REPLACE INTO answer_scores
            (question_id, percent, confidence, reasons, counterpoints, follow_ups, metrics, is_final, computed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """) { statement in
            statement.bindText(score.questionID, at: 1)
            statement.bindInt(score.percent, at: 2)
            statement.bindText(score.confidence.rawValue, at: 3)
            statement.bindText(Self.json(score.reasons), at: 4)
            statement.bindText(Self.json(score.counterpoints), at: 5)
            statement.bindText(Self.json(score.followUps), at: 6)
            statement.bindText(Self.json(score.metrics), at: 7)
            statement.bindBool(score.isFinal, at: 8)
            statement.bindMillis(Date(), at: 9)
        }
    }

    func saveRoleProfile(_ profile: RoleProfile) {
        interviewWrite("saveRoleProfile", """
            INSERT OR REPLACE INTO role_profiles (workspace_id, profile, updated_at) VALUES (?, ?, ?)
            """) { statement in
            statement.bindText(profile.workspaceID, at: 1)
            statement.bindText(Self.json(profile), at: 2)
            statement.bindMillis(profile.updatedAt, at: 3)
        }
    }

    func loadRoleProfiles() -> [RoleProfile] {
        interviewRead("loadRoleProfiles", "SELECT profile FROM role_profiles ORDER BY updated_at DESC",
                      row: { Self.decode(RoleProfile.self, $0.columnText(0)) }).compactMap { $0 }
    }

    func deleteRoleProfile(workspaceID: String) {
        interviewWrite("deleteRoleProfile", "DELETE FROM role_profiles WHERE workspace_id = ?") {
            $0.bindText(workspaceID, at: 1)
        }
    }

    func loadRoleProfile(workspaceID: String) -> RoleProfile? {
        interviewRead("loadRoleProfile", "SELECT profile FROM role_profiles WHERE workspace_id = ?",
             bind: { $0.bindText(workspaceID, at: 1) },
             row: { Self.decode(RoleProfile.self, $0.columnText(0)) }).compactMap { $0 }.first
    }

    // MARK: - Helpers

    static func millis(_ seconds: TimeInterval) -> Int64 { Int64((seconds * 1000).rounded()) }

    static func seconds(_ millis: Int64) -> TimeInterval { Double(millis) / 1000 }

    static func json<T: Encodable>(_ value: T) -> String {
        (try? String(data: JSONEncoder().encode(value), encoding: .utf8)) ?? "null"
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func interviewWrite(_ operation: String, _ sql: String, bind: (SQLiteStatement) -> Void) {
        do {
            try performSyncThrowing { db in
                let statement = try SQLiteStatement(db: db, sql: sql)
                bind(statement)
                try statement.executeStep()
            }
        } catch {
            reportSwallowedError(error, operation: operation)
        }
    }

    func interviewRead<T>(_ operation: String, _ sql: String, bind: (SQLiteStatement) -> Void = { _ in },
                 row: (SQLiteStatement) -> T) -> [T] {
        do {
            return try performSyncThrowing { db in
                let statement = try SQLiteStatement(db: db, sql: sql)
                bind(statement)
                var rows: [T] = []
                while try statement.stepRow() { rows.append(row(statement)) }
                return rows
            }
        } catch {
            reportSwallowedError(error, operation: operation)
            return []
        }
    }
}

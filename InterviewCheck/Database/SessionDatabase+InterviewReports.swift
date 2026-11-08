import Foundation
import SQLite3
import InterviewCheckKit

/// Everything stored about one interview, for the report.
struct InterviewReportData: Equatable {
    let interview: InterviewRecord
    let questions: [InterviewQuestionRecord]
    let references: [String: [ReferenceAnswerRecord]]
    let scores: [String: AnswerScoreRecord]
    var verdicts: [String: AnswerLabel] = [:]
    var notes: [String: String] = [:]
}

extension SessionDatabase {
    func loadInterviews(limit: Int = 200) -> [InterviewRecord] {
        interviewRead("loadInterviews", """
            SELECT id, workspace_id, role_title, candidate_name, consent_confirmed_at, started_at, ended_at,
                   overall_percent, flagged_count, question_count, interrupted, external_ref, scored_from
            FROM interviews ORDER BY started_at DESC LIMIT ?
            """, bind: { $0.bindInt(limit, at: 1) }, row: Self.interviewRow)
    }

    func loadInterviewReport(id: String) -> InterviewReportData? {
        guard let interview = interviewRead("loadInterview", """
            SELECT id, workspace_id, role_title, candidate_name, consent_confirmed_at, started_at, ended_at,
                   overall_percent, flagged_count, question_count, interrupted, external_ref, scored_from
            FROM interviews WHERE id = ?
            """, bind: { $0.bindText(id, at: 1) }, row: Self.interviewRow).first else { return nil }

        let questions = interviewRead("loadInterviewQuestions", """
            SELECT id, interview_id, ordinal, text, source, marked_at_ms, question_end_ms, answer_start_ms,
                   answer_end_ms, closed_at_ms, answer_text
            FROM interview_questions WHERE interview_id = ? ORDER BY ordinal
            """, bind: { $0.bindText(id, at: 1) }) { row in
            InterviewQuestionRecord(
                id: row.columnText(0) ?? "", interviewID: row.columnText(1) ?? "", ordinal: row.columnInt(2),
                text: row.columnText(3) ?? "", source: QuestionSource(rawValue: row.columnText(4) ?? "") ?? .live,
                markedAt: Self.seconds(row.columnInt64(5)), questionEnd: Self.optionalSeconds(row, 6),
                answerStart: Self.optionalSeconds(row, 7), answerEnd: Self.optionalSeconds(row, 8),
                closedAt: Self.optionalSeconds(row, 9), answerText: row.columnText(10) ?? ""
            )
        }

        let references = interviewRead("loadReferenceAnswers", """
            SELECT r.id, r.question_id, r.provider, r.model, r.prompt_name, r.text, r.first_sentence_ms,
                   r.total_ms, r.error
            FROM reference_answers r JOIN interview_questions q ON q.id = r.question_id
            WHERE q.interview_id = ? ORDER BY r.rowid
            """, bind: { $0.bindText(id, at: 1) }) { row in
            ReferenceAnswerRecord(
                id: row.columnText(0) ?? "", questionID: row.columnText(1) ?? "",
                provider: AIProviderType(rawValue: row.columnText(2) ?? "") ?? .openai,
                model: row.columnText(3) ?? "", promptName: row.columnText(4) ?? "", text: row.columnText(5) ?? "",
                firstSentenceSeconds: Self.optionalSeconds(row, 6), totalSeconds: Self.optionalSeconds(row, 7),
                error: row.columnText(8)
            )
        }

        let scores = interviewRead("loadAnswerScores", """
            SELECT s.question_id, s.percent, s.confidence, s.reasons, s.counterpoints, s.follow_ups, s.metrics,
                   s.is_final
            FROM answer_scores s JOIN interview_questions q ON q.id = s.question_id
            WHERE q.interview_id = ?
            """, bind: { $0.bindText(id, at: 1) }) { row -> AnswerScoreRecord? in
            guard let metrics = Self.decode(AnswerMetrics.self, row.columnText(6)) else { return nil }
            return AnswerScoreRecord(
                questionID: row.columnText(0) ?? "", percent: row.columnInt(1),
                confidence: ScoreConfidence(rawValue: row.columnText(2) ?? "") ?? .low,
                reasons: Self.decode([String].self, row.columnText(3)) ?? [],
                counterpoints: Self.decode([String].self, row.columnText(4)) ?? [],
                followUps: Self.decode([String].self, row.columnText(5)) ?? [],
                metrics: metrics, isFinal: row.columnBool(7)
            )
        }.compactMap { $0 }

        return InterviewReportData(
            interview: interview,
            questions: questions,
            references: Dictionary(grouping: references, by: \.questionID),
            scores: Dictionary(scores.map { ($0.questionID, $0) }, uniquingKeysWith: { $1 }),
            verdicts: loadAnswerLabels(interviewID: id),
            notes: loadAnswerNotes(interviewID: id)
        )
    }

    func loadInterviewWords(interviewID: String) -> [TimedWord] {
        interviewRead("loadInterviewWords", """
            SELECT side, speaker_index, text, start_ms, end_ms, confidence, is_filler
            FROM interview_words WHERE interview_id = ? ORDER BY start_ms
            """, bind: { $0.bindText(interviewID, at: 1) }) { row in
            TimedWord(
                side: InterviewSide(rawValue: row.columnText(0) ?? "") ?? .candidate,
                speakerIndex: row.columnIsNull(1) ? nil : row.columnInt(1),
                text: row.columnText(2) ?? "",
                start: Self.seconds(row.columnInt64(3)), end: Self.seconds(row.columnInt64(4)),
                confidence: row.columnIsNull(5) ? nil : row.columnDouble(5),
                isFiller: row.columnBool(6)
            )
        }
    }

    func deleteInterview(id: String) {
        for sql in [
            "DELETE FROM answer_labels WHERE question_id IN (SELECT id FROM interview_questions WHERE interview_id = ?)",
            "DELETE FROM answer_notes WHERE question_id IN (SELECT id FROM interview_questions WHERE interview_id = ?)",
            "DELETE FROM answer_scores WHERE question_id IN (SELECT id FROM interview_questions WHERE interview_id = ?)",
            "DELETE FROM reference_answers WHERE question_id IN (SELECT id FROM interview_questions WHERE interview_id = ?)",
            "DELETE FROM interview_questions WHERE interview_id = ?",
            "DELETE FROM interview_words WHERE interview_id = ?",
            "DELETE FROM external_links WHERE ref IN (SELECT external_ref FROM interviews WHERE id = ?)",
            "UPDATE external_recordings SET interview_id = NULL WHERE interview_id = ?",
            "DELETE FROM interviews WHERE id = ?",
        ] {
            interviewWrite("deleteInterview", sql) { $0.bindText(id, at: 1) }
        }
    }

    /// Deletes interviews that started before `date`; returns how many.
    @discardableResult
    func deleteInterviews(startedBefore date: Date) -> Int {
        let ids = interviewRead("interviewsBefore", "SELECT id FROM interviews WHERE started_at < ?",
                                bind: { $0.bindMillis(date, at: 1) }, row: { $0.columnText(0) ?? "" })
        ids.forEach { deleteInterview(id: $0) }
        return ids.count
    }

    /// Interviews that were started but never ended.
    func unendedInterviewIDs() -> [String] {
        interviewRead("unendedInterviews", "SELECT id FROM interviews WHERE ended_at IS NULL",
                      row: { $0.columnText(0) ?? "" })
    }

    /// Deletes every interview, its words, AI answers and scores (roles stay).
    @discardableResult
    func deleteAllInterviews() -> Int {
        deleteInterviews(startedBefore: .distantFuture)
    }

    private static func interviewRow(_ row: SQLiteStatement) -> InterviewRecord {
        InterviewRecord(
            id: row.columnText(0) ?? "", workspaceID: row.columnText(1), roleTitle: row.columnText(2) ?? "",
            candidateName: row.columnText(3) ?? "", consentConfirmedAt: row.columnOptionalDate(4),
            startedAt: row.columnDate(5), endedAt: row.columnOptionalDate(6),
            overallPercent: row.columnIsNull(7) ? nil : row.columnInt(7),
            flaggedCount: row.columnInt(8), questionCount: row.columnInt(9),
            wasInterrupted: row.columnBool(10), externalRef: row.columnText(11),
            scoredFrom: row.columnText(12).flatMap(ScoredFrom.init(rawValue:))
        )
    }

    private static func optionalSeconds(_ row: SQLiteStatement, _ index: Int32) -> TimeInterval? {
        row.columnIsNull(index) ? nil : seconds(row.columnInt64(index))
    }
}

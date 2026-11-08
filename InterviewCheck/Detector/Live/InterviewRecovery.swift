import Foundation
import InterviewCheckKit

/// Finishes interviews that never ended because the app quit or crashed
/// mid-call. At the next launch each open answer is closed and scored from
/// the saved words and AI answers (no network), and the interview is marked
/// as interrupted so the report can say so.
enum InterviewRecovery {
    @discardableResult
    static func finishUnended(database: SessionDatabase, weights: CheatScoreWeights,
                              finished: @escaping @Sendable ([String]) -> Void = { _ in }) -> Int {
        let ids = database.unendedInterviewIDs()
        ids.forEach { finish($0, database: database, weights: weights) }
        if !ids.isEmpty { finished(ids) }
        return ids.count
    }

    static func finish(_ id: String, database: SessionDatabase, weights: CheatScoreWeights) {
        guard let report = database.loadInterviewReport(id: id) else { return }
        let words = database.loadInterviewWords(interviewID: id)
        let evaluator = AnswerEvaluator(weights: weights)
        var finals = report.questions.compactMap { report.scores[$0.id] }.filter(\.isFinal)

        for (index, question) in report.questions.enumerated() where report.scores[question.id]?.isFinal != true {
            let window = QuestionTracker.resolve(
                words: words, markedAt: question.markedAt,
                lowerBound: index > 0 ? report.questions[index - 1].markedAt : 0,
                // Answer Done already closed it; otherwise the next question does.
                closedAt: question.closedAt ?? (index + 1 < report.questions.count ? report.questions[index + 1].markedAt : nil)
            )
            var closed = question
            if closed.text.isEmpty { closed.text = window.questionText }
            closed.questionEnd = window.questionEnd
            closed.answerStart = window.answerStart
            closed.answerEnd = window.answerEnd
            closed.answerText = window.answerWords.map(\.text).joined(separator: " ")
            closed.closedAt = question.closedAt ?? window.answerEnd ?? question.markedAt
            database.saveInterviewQuestion(closed)
            guard !window.answerWords.isEmpty else { continue }

            // Words after the last save were lost, so the answer may be cut short.
            let score = evaluator.evaluate(questionText: closed.text, window: window,
                                           references: report.references[question.id] ?? [], hasTimingGap: true,
                                           measuresFluency: report.interview.scoredFrom != .transcript)
            let record = AnswerScoreRecord(
                questionID: question.id, percent: score.percent, confidence: score.confidence,
                reasons: score.reasons, counterpoints: score.counterpoints, followUps: score.followUps,
                metrics: AnswerMetrics(score: score, timingGap: true), isFinal: true
            )
            database.saveAnswerScore(record)
            finals.append(record)
        }

        var interview = report.interview
        let lastActivity = max(words.last?.end ?? 0, report.questions.last?.markedAt ?? 0)
        interview.endedAt = interview.startedAt.addingTimeInterval(lastActivity)
        interview.wasInterrupted = true
        interview.questionCount = report.questions.count
        interview.flaggedCount = finals.filter { $0.percent >= 70 }.count
        interview.overallPercent = InterviewSummary.overall(finals)
        database.saveInterview(interview)
    }
}

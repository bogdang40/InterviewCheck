import XCTest
import InterviewCheckKit
@testable import InterviewCheck

final class AnswerLabelTests: XCTestCase {
    func testLabelsRoundTripFeedTheTunerAndGoWithTheInterview() {
        let path = NSTemporaryDirectory() + "labels-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = SessionDatabase(databasePath: path)
        let interview = InterviewRecord(id: "i1", workspaceID: nil, roleTitle: "", candidateName: "A",
                                        consentConfirmedAt: nil, startedAt: Date())
        database.saveInterview(interview)
        database.saveInterviewQuestion(InterviewQuestionRecord(id: "q1", interviewID: "i1", ordinal: 1, text: "Q",
                                                               source: .live, markedAt: 0))
        let score = CheatScorer.score(
            timing: TimingSignal.evaluate(answerWords: [], questionEnd: 0, questionText: ""),
            fluency: FluencySignal.evaluate(answerWords: [], from: nil), similarity: nil,
            judge: JudgeResult(likelihood: 80, confidence: "high", evidence: [], followUpQuestions: []),
            hasTimingGap: false)
        database.saveAnswerScore(AnswerScoreRecord(questionID: "q1", percent: score.percent, confidence: score.confidence,
                                                   reasons: [], counterpoints: [], followUps: [],
                                                   metrics: AnswerMetrics(score: score, timingGap: false), isFinal: true))

        database.saveAnswerLabel(.aiAssisted, questionID: "q1")
        XCTAssertEqual(database.loadAnswerLabels(interviewID: "i1"), ["q1": .aiAssisted])
        let labeled = database.loadLabeledAnswers()
        XCTAssertEqual(labeled.count, 1)
        XCTAssertEqual(labeled.first?.wasAIAssisted, true)
        XCTAssertEqual(labeled.first?.components.judge ?? 0, 0.8, accuracy: 1e-9)

        database.saveAnswerLabel(nil, questionID: "q1")
        XCTAssertTrue(database.loadAnswerLabels(interviewID: "i1").isEmpty)

        database.saveAnswerLabel(.ownAnswer, questionID: "q1")
        database.deleteInterview(id: "i1")
        XCTAssertTrue(database.loadLabeledAnswers().isEmpty)
    }
}

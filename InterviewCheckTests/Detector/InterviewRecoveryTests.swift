import XCTest
import InterviewCheckKit
@testable import InterviewCheck

final class InterviewRecoveryTests: XCTestCase {
    private typealias F = DetectorFixtures

    func testUnendedInterviewIsClosedScoredAndMarked() throws {
        let path = NSTemporaryDirectory() + "recovery-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = SessionDatabase(databasePath: path)
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        database.saveInterview(InterviewRecord(id: "i1", workspaceID: nil, roleTitle: "Backend", candidateName: "Sam",
                                               consentConfirmedAt: started, startedAt: started))

        // One question asked, the candidate read an answer, then the app died.
        let question = F.words(F.question, side: .interviewer, start: 5)
        let answer = F.readingAnswer(after: question.last!.end)
        database.appendInterviewWords(question + answer, interviewID: "i1", origin: 0)
        database.saveInterviewQuestion(InterviewQuestionRecord(id: "q1", interviewID: "i1", ordinal: 1, text: "",
                                                               source: .live, markedAt: question.last!.end + 0.3))
        database.saveReferenceAnswer(ReferenceAnswerRecord(id: "r1", questionID: "q1", provider: .openai,
                                                           model: "gpt-5.2", promptName: "Copilot", text: F.aiAnswer,
                                                           firstSentenceSeconds: 2.5, totalSeconds: 8))
        // A finished interview is left alone.
        database.saveInterview(InterviewRecord(id: "done", workspaceID: nil, roleTitle: "", candidateName: "B",
                                               consentConfirmedAt: nil, startedAt: started, endedAt: started))
        XCTAssertEqual(database.unendedInterviewIDs(), ["i1"])

        XCTAssertEqual(InterviewRecovery.finishUnended(database: database, weights: CheatScoreWeights()), 1)
        XCTAssertTrue(database.unendedInterviewIDs().isEmpty)

        let report = try XCTUnwrap(database.loadInterviewReport(id: "i1"))
        XCTAssertTrue(report.interview.wasInterrupted)
        XCTAssertEqual(report.interview.endedAt?.timeIntervalSince(started) ?? 0, answer.last!.end, accuracy: 0.01)
        XCTAssertEqual(report.questions.first?.text, F.question, "the question text is filled from the words")
        XCTAssertNotNil(report.questions.first?.closedAt)
        let score = try XCTUnwrap(report.scores["q1"])
        XCTAssertTrue(score.isFinal)
        XCTAssertEqual(score.confidence, .low, "a cut-short answer is never high confidence")
        XCTAssertGreaterThanOrEqual(score.percent, 70)
        XCTAssertEqual(report.interview.overallPercent, score.percent)
        XCTAssertTrue(InterviewReportComposer.markdown(report).contains("Interrupted"))
        XCTAssertFalse(try XCTUnwrap(database.loadInterviewReport(id: "done")).interview.wasInterrupted)
    }
}

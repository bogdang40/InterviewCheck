import XCTest
@testable import InterviewCheckKit

final class RecordingQuestionFinderTests: XCTestCase {
    private typealias F = DetectorFixtures

    func testFindsEachQuestionFollowedByARealAnswer() {
        let q1 = F.words("Tell me about yourself.", side: .interviewer, start: 0)
        let a1 = F.words("I am a backend engineer with five years building payment systems in Go and Postgres", side: .candidate, start: 3)
        let q2 = F.words("Why are you leaving?", side: .interviewer, start: 12)
        let a2 = F.words("I want to work on larger systems and grow into a staff role on a platform team", side: .candidate, start: 15)
        let marks = RecordingQuestionFinder.questionMarks(in: q1 + a1 + q2 + a2)
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(marks[0], q1.last!.end, accuracy: 1e-9)
        XCTAssertEqual(marks[1], q2.last!.end, accuracy: 1e-9)
    }

    func testInterjectionsDoNotSplitAnAnswer() {
        let q = F.words("How did you scale the queue?", side: .interviewer, start: 0)
        let a1 = F.words("We sharded it by tenant and", side: .candidate, start: 3)
        let ok = F.words("Mm-hmm.", side: .interviewer, start: 6)
        let a2 = F.words("then moved retries to a separate topic so failures stopped blocking new work", side: .candidate, start: 7)
        let marks = RecordingQuestionFinder.questionMarks(in: q + a1 + ok + a2)
        XCTAssertEqual(marks.count, 1)
    }

    func testShortRepliesAreNotAnswers() {
        let q = F.words("Can you hear me okay?", side: .interviewer, start: 0)
        let a = F.words("Yes, loud and clear.", side: .candidate, start: 2)
        XCTAssertTrue(RecordingQuestionFinder.questionMarks(in: q + a).isEmpty)
    }

    func testMarksWorkWithTheQuestionTracker() {
        let q = F.words("Walk me through your last project.", side: .interviewer, start: 0)
        let a = F.words("Sure, I built the billing service that handles invoices and retries for every customer", side: .candidate, start: 4)
        let words = q + a
        let mark = RecordingQuestionFinder.questionMarks(in: words)[0]
        let window = QuestionTracker.resolve(words: words, markedAt: mark, lowerBound: nil, closedAt: nil)
        XCTAssertEqual(window.questionText, "Walk me through your last project.")
        XCTAssertEqual(window.answerWords.count, a.count)
    }
}

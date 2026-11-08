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

    func testInterjectionsInsideAnAnswerAreNotQuestions() {
        let q = F.words("How would you design a rate limiter for our API?", side: .interviewer, start: 0)
        let a1 = F.words("I would start with a token bucket for each key stored in Redis", side: .candidate, start: q.last!.end + 1)
        let nod = F.words("Right, that makes sense.", side: .interviewer, start: a1.last!.end + 0.3)
        let a2 = F.words("and then return a 429 with a retry after header when the bucket runs out", side: .candidate,
                         start: nod.last!.end + 0.3)
        let really = F.words("Really?", side: .interviewer, start: a2.last!.end + 0.3)
        let a3 = F.words("yes because it keeps the gateway simple and the limits easy to reason about for everyone", side: .candidate,
                         start: really.last!.end + 0.3)
        let marks = RecordingQuestionFinder.questionMarks(in: q + a1 + nod + a2 + really + a3)
        XCTAssertEqual(marks.count, 1, "one question, one long answer")
        XCTAssertEqual(marks.first ?? 0, q.last!.end, accuracy: 1e-9)

        // A real follow-up after an answer still counts.
        let followUp = F.words("What bucket size would you pick?", side: .interviewer, start: a3.last!.end + 1)
        let a4 = F.words("probably a hundred requests per minute with a burst of twenty for most partners", side: .candidate,
                         start: followUp.last!.end + 1)
        XCTAssertEqual(RecordingQuestionFinder.questionMarks(in: q + a1 + nod + a2 + really + a3 + followUp + a4).count, 2)
    }
}

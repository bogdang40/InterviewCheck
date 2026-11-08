import XCTest
@testable import InterviewCheckKit

final class QuestionTrackerTests: XCTestCase {
    private typealias F = DetectorFixtures

    func testQuestionEndsAtInterviewersLastWordBeforeTheAnswer() {
        let question = F.words("Thanks. How would you design a rate limiter?", side: .interviewer, start: 10)
        let questionEnd = question.last!.end
        let answer = F.words("I would use a token bucket per key", side: .candidate, start: questionEnd + 2)
        let window = QuestionTracker.resolve(words: question + answer, markedAt: questionEnd + 0.4,
                                             lowerBound: nil, closedAt: nil)
        XCTAssertEqual(window.questionText, "Thanks. How would you design a rate limiter?")
        XCTAssertEqual(window.questionEnd, questionEnd, accuracy: 1e-9)
        XCTAssertEqual(window.answerWords.count, answer.count)
        XCTAssertEqual(window.answerStart!, questionEnd + 2, accuracy: 1e-9)
    }

    func testInterviewerContinuingAfterTheKeypressExtendsTheQuestion() {
        let first = F.words("Design a rate limiter.", side: .interviewer, start: 10)
        let more = F.words("For a public API, many servers.", side: .interviewer, start: first.last!.end + 1.0)
        let answer = F.words("Sure, a token bucket", side: .candidate, start: more.last!.end + 3)
        // Pressed right after the first sentence, before the clarification.
        let window = QuestionTracker.resolve(words: first + more + answer, markedAt: first.last!.end + 0.2,
                                             lowerBound: nil, closedAt: nil)
        XCTAssertTrue(window.questionText.hasSuffix("many servers."))
        XCTAssertEqual(window.questionEnd, more.last!.end, accuracy: 1e-9)
    }

    func testBackchannelDoesNotEndTheQuestion() {
        let part1 = F.words("Imagine a public API.", side: .interviewer, start: 10)
        let ok = F.words("Okay.", side: .candidate, start: part1.last!.end + 0.3)
        let part2 = F.words("How would you limit abusive clients?", side: .interviewer, start: ok.last!.end + 0.3)
        let answer = F.words("I'd start with per key quotas", side: .candidate, start: part2.last!.end + 1)
        let window = QuestionTracker.resolve(words: part1 + ok + part2 + answer, markedAt: part2.last!.end + 0.5,
                                             lowerBound: nil, closedAt: nil)
        XCTAssertTrue(window.questionText.hasPrefix("Imagine a public API."))
        XCTAssertFalse(window.questionText.contains("Okay."))
        XCTAssertEqual(window.answerWords.first?.text, "I'd")
    }

    func testPreviousAnswerBoundsTheQuestion() {
        let oldQuestion = F.words("Tell me about yourself.", side: .interviewer, start: 0)
        let oldAnswer = F.words("I am a backend engineer with five years of experience", side: .candidate, start: 3)
        let newQuestion = F.words("Great. Now how would you design a cache?", side: .interviewer, start: 12)
        let all = oldQuestion + oldAnswer + newQuestion
        let window = QuestionTracker.resolve(words: all, markedAt: newQuestion.last!.end + 0.3,
                                             lowerBound: nil, closedAt: nil)
        XCTAssertEqual(window.questionText, "Great. Now how would you design a cache?")
    }

    func testAnswerStopsAtTheNextKeypress() {
        let question = F.words("Why this company?", side: .interviewer, start: 0)
        let answer = F.words("Because of the mission and the team", side: .candidate, start: 2)
        let next = F.words("And your biggest weakness?", side: .interviewer, start: 8)
        let late = F.words("Probably delegation", side: .candidate, start: 11)
        let window = QuestionTracker.resolve(words: question + answer + next + late, markedAt: 1.2,
                                             lowerBound: nil, closedAt: 9.5)
        XCTAssertEqual(window.answerWords.map(\.text), answer.map(\.text))
    }

    func testNoMicSpeechTimesFromTheKeypress() {
        let answer = F.words("I would cache at the edge", side: .candidate, start: 20)
        let window = QuestionTracker.resolve(words: answer, markedAt: 17, lowerBound: nil, closedAt: nil)
        XCTAssertEqual(window.questionText, "")
        XCTAssertEqual(window.questionEnd, 17, accuracy: 1e-9)
        XCTAssertEqual(window.answerWords.count, answer.count)
    }

    func testOtherRemoteSpeakersAreIgnoredWhenACandidateIsChosen() {
        let question = F.words("Walk me through your last project.", side: .interviewer, start: 0)
        let panelist = F.words("Feel free to share your screen", side: .candidate, start: 3, speaker: 1)
        let answer = F.words("Sure so I built a billing service", side: .candidate, start: 6, speaker: 0)
        let window = QuestionTracker.resolve(words: question + panelist + answer, markedAt: 2.5,
                                             lowerBound: nil, closedAt: nil,
                                             isCandidate: { $0.speakerIndex == 0 })
        XCTAssertEqual(window.answerWords.first?.text, "Sure")
    }

    func testStoredWindowKeepsOnlyThisAnswersCandidateWords() {
        let q1 = F.words("Tell me about yourself.", side: .interviewer, start: 0)
        let a1 = F.words("I build payment systems", side: .candidate, start: q1.last!.end + 1)
        let q2 = F.words("Design a rate limiter.", side: .interviewer, start: a1.last!.end + 1)
        let a2 = F.words("Well um a token bucket per key", side: .candidate, start: q2.last!.end + 4)
        let words = q1 + a1 + q2 + a2
        let window = QuestionWindow.stored(questionText: "Design a rate limiter.", questionEnd: q2.last!.end,
                                           answerStart: a2.first!.start, answerEnd: a2.last!.end, words: words)
        XCTAssertEqual(window.answerWords.map(\.text), a2.map(\.text))
        XCTAssertEqual(window.questionEnd, q2.last!.end, accuracy: 1e-9)

        // An answer still open (no end) runs to the last candidate word.
        let open = QuestionWindow.stored(questionText: "", questionEnd: q1.last!.end, answerStart: nil,
                                         answerEnd: nil, words: q1 + a1)
        XCTAssertEqual(open.answerWords.count, a1.count)
    }
}

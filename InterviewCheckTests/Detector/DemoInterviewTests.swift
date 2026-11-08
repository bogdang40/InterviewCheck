import XCTest
import InterviewCheckKit
@testable import InterviewCheck

final class DemoInterviewTests: XCTestCase {
    func testScriptMarksOneQuestionPerExchangeInOrder() {
        let words = DemoScript.words(origin: 100)
        XCTAssertEqual(words.filter(\.markAfter).count, DemoScript.exchanges.count)
        XCTAssertEqual(words.map(\.word.start), words.map(\.word.start).sorted())
        XCTAssertTrue(words.first?.word.side == .interviewer)
    }

    func testScriptedAnswersScoreHonestLowAndReadingHigh() {
        let words = DemoScript.words(origin: 0).map(\.word)
        let marks = RecordingQuestionFinder.questionMarks(in: words)
        XCTAssertEqual(marks.count, 3)
        let scores = marks.enumerated().map { index, mark -> Int in
            let window = QuestionTracker.resolve(words: words, markedAt: mark, lowerBound: index > 0 ? marks[index - 1] : nil,
                                                 closedAt: index + 1 < marks.count ? marks[index + 1] : nil)
            let reference = ReferenceText(id: UUID(), label: "AI", text: DemoScript.aiAnswer(question: window.questionText, runIndex: 0),
                                          embedding: nil)
            let timing = TimingSignal.evaluate(answerWords: window.answerWords, questionEnd: window.questionEnd,
                                               questionText: window.questionText)
            let fluency = FluencySignal.evaluate(answerWords: window.answerWords, from: timing.substantiveIndex)
            let similarity = SimilaritySignal.evaluate(answerText: window.answerWords.map(\.text).joined(separator: " "),
                                                       answerEmbedding: nil, questionText: window.questionText,
                                                       references: [reference])
            return CheatScorer.score(timing: timing, fluency: fluency, similarity: similarity, judge: nil,
                                     hasTimingGap: false).percent
        }
        XCTAssertLessThan(scores[0], 40, "the honest, halting answer")
        XCTAssertGreaterThanOrEqual(scores[1], 70, "the answer read from the AI")
    }

    func testEachPromptStyleGetsItsOwnCannedAnswer() async throws {
        let question = DemoScript.exchanges[1].question
        var answers: [String] = []
        for prompt in CheaterPromptLibrary.defaults {
            let request = CheaterPromptLibrary.request(for: prompt, question: question,
                                                       context: RoleContext(roleTitle: "", jobDescription: "", resume: ""))
            let client = DemoTextClient(provider: .openai, model: "gpt-5.2", chunkPause: 0)
            answers.append(try await client.streamText(system: request.system, user: request.user) { _ in })
        }
        XCTAssertEqual(Set(answers).count, 3, "Copilot, Talking points and STAR differ")
        XCTAssertTrue(answers[1].contains("\n- "), "talking points keep their line breaks")
    }
}

/// Restart mid-run used to reset a controller that was still scoring, which
/// froze the demo; each run now has its own controller and timeline.
@MainActor
final class DemoRestartTests: XCTestCase {
    func testRestartStartsAFreshRun() async throws {
        let demo = DemoInterview()
        demo.start()
        let first = demo.controller
        XCTAssertEqual(first.phase, .live)
        try await Task.sleep(nanoseconds: 200_000_000)
        demo.restart()
        XCTAssertFalse(demo.controller === first)
        XCTAssertEqual(demo.controller.phase, .live)
        XCTAssertEqual(first.phase, .ended)
        XCTAssertFalse(demo.isFinished)
        XCTAssertNil(demo.report)
        demo.stop()
    }
}

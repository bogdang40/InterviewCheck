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
}

import XCTest
@testable import InterviewCheckKit

final class TimingStripModelTests: XCTestCase {
    private typealias F = DetectorFixtures

    private func strip(_ words: [TimedWord], aiFirstLine: TimeInterval?) -> TimingStripModel {
        let window = QuestionWindow.stored(questionText: F.question, questionEnd: 100, answerStart: nil, answerEnd: nil,
                                           words: words)
        let timing = TimingSignal.evaluate(answerWords: window.answerWords, questionEnd: 100, questionText: F.question)
        return TimingStripModel(window: window, timing: timing, now: 130, aiFirstLine: aiFirstLine)
    }

    func testReadingRightAfterTheAIsFirstLineIsSaid() throws {
        let model = strip(F.readingAnswer(after: 100), aiFirstLine: 2.4)
        XCTAssertEqual(model.aiFirstLine, 2.4)
        XCTAssertTrue(model.summary.contains("after the fastest AI's first line"), model.summary)
    }

    func testAQuickStartIsNotTiedToTheAI() {
        let model = strip(F.honestAnswer(after: 100), aiFirstLine: 2.4)
        XCTAssertFalse(model.summary.contains("fastest AI"), model.summary)
        XCTAssertEqual(model.aiFirstLine, 2.4, "the marker still shows")
    }

    func testNoMarkerWithoutAIAnswersOrBeyondTheStrip() {
        XCTAssertNil(strip(F.readingAnswer(after: 100), aiFirstLine: nil).aiFirstLine)
        XCTAssertNil(strip(F.readingAnswer(after: 100), aiFirstLine: 40).aiFirstLine)
    }
}

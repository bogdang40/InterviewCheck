import XCTest
@testable import InterviewCheckKit

final class BaselineSignalTests: XCTestCase {
    /// Quick starts, an "um" every 14 words or so.
    private let halting = [
        AnswerStyle(latency: 1.2, wordCount: 80, hesitations: 6),
        AnswerStyle(latency: 0.9, wordCount: 60, hesitations: 4),
        AnswerStyle(latency: 1.5, wordCount: 70, hesitations: 5),
    ]

    func testLateAndPolishedAgainstAHaltingBaselineIsCalledOut() {
        let note = BaselineSignal.compare(AnswerStyle(latency: 6.1, wordCount: 90, hesitations: 0), with: halting)
        XCTAssertEqual(note, "Unlike their other answers: started after 6.1 s (usually 1.2 s), 0 hesitations per 100 words (usually 7)")
    }

    func testSmootherButOnTimeIsMilder() {
        let note = BaselineSignal.compare(AnswerStyle(latency: 1.0, wordCount: 90, hesitations: 1), with: halting)
        XCTAssertEqual(note, "Smoother than their other answers: 1 hesitation per 100 words (usually 7)")
    }

    func testAConsistentlyFluentSpeakerIsNotCalledOut() {
        let fluent = [AnswerStyle(latency: 0.8, wordCount: 80, hesitations: 1), AnswerStyle(latency: 1.0, wordCount: 60, hesitations: 0)]
        XCTAssertNil(BaselineSignal.compare(AnswerStyle(latency: 5, wordCount: 90, hesitations: 0), with: fluent))
    }

    func testAPauseAloneIsNotCalledOut() {
        XCTAssertNil(BaselineSignal.compare(AnswerStyle(latency: 7, wordCount: 90, hesitations: 6), with: halting))
    }

    func testNeedsTwoOtherAnswersAndEnoughWords() {
        XCTAssertNil(BaselineSignal.compare(AnswerStyle(latency: 6, wordCount: 90, hesitations: 0), with: [halting[0]]))
        XCTAssertNil(BaselineSignal.compare(AnswerStyle(latency: 6, wordCount: 10, hesitations: 0), with: halting))
        let short = halting.map { AnswerStyle(latency: $0.latency, wordCount: 12, hesitations: $0.hesitations) }
        XCTAssertNil(BaselineSignal.compare(AnswerStyle(latency: 6, wordCount: 90, hesitations: 0), with: short))
    }

    func testMedian() {
        XCTAssertEqual(BaselineSignal.median([1, 3, 2, 4]), 2.5)
        XCTAssertEqual(BaselineSignal.median([5, 1, 3]), 3)
        XCTAssertNil(BaselineSignal.median([]))
    }
}

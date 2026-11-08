import XCTest
@testable import memanager

final class SignalTests: XCTestCase {
    private typealias F = DetectorFixtures
    private let questionEnd: TimeInterval = 100

    // MARK: Timing

    func testHonestAnswerStartsQuickly() {
        let timing = TimingSignal.evaluate(answerWords: F.honestAnswer(after: questionEnd),
                                           questionEnd: questionEnd, questionText: F.question)
        XCTAssertEqual(timing.firstWordLatency!, 0.9, accuracy: 0.01)
        // "Um so" are skipped; "I'd" is the substantive start.
        XCTAssertEqual(timing.stallWordCount, 2)
        XCTAssertLessThan(timing.substantiveLatency!, 2)
        XCTAssertLessThan(timing.score, 0.2)
    }

    func testReadingAnswerShowsTheStallThenTheLongWait() {
        let timing = TimingSignal.evaluate(answerWords: F.readingAnswer(after: questionEnd),
                                           questionEnd: questionEnd, questionText: F.question)
        XCTAssertEqual(timing.firstWordLatency!, 2.2, accuracy: 0.01)
        XCTAssertEqual(timing.stallWordCount, 5) // "That's a great question so"
        XCTAssertEqual(timing.substantiveLatency!, 6.4, accuracy: 0.01)
        XCTAssertGreaterThan(timing.score, 0.8)
    }

    func testReadingTheQuestionBackIsNotASubstantiveStart() {
        let words = F.words("So how would I design a rate limiter for a public API ...1.0 I'd use quotas",
                            side: .candidate, start: questionEnd + 0.5)
        let timing = TimingSignal.evaluate(answerWords: words, questionEnd: questionEnd, questionText: F.question)
        // The read-back is skipped; the answer starts at "I'd use".
        XCTAssertTrue(["I'd", "use"].contains(words[timing.substantiveIndex!].text))
        XCTAssertGreaterThan(timing.substantiveLatency!, 4)
    }

    func testAnswerReusingOneQuestionWordStartsImmediately() {
        let words = F.words("A rate limit protects the database from bursts", side: .candidate,
                            start: questionEnd + 0.4)
        let timing = TimingSignal.evaluate(answerWords: words, questionEnd: questionEnd, questionText: F.question)
        XCTAssertLessThanOrEqual(timing.substantiveIndex!, 1)
    }

    func testLatencyCurveIsMonotonicUpToEightSeconds() {
        var previous = -1.0
        for tenth in 0...80 {
            let value = TimingSignal.interpolate(Double(tenth) / 10)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    // MARK: Fluency

    func testHonestAnswerSoundsHalting() {
        let words = F.honestAnswer(after: questionEnd)
        let fluency = FluencySignal.evaluate(answerWords: words, from: 2)
        XCTAssertTrue(fluency.isReliable)
        XCTAssertGreaterThanOrEqual(fluency.fillerCount, 5)
        XCTAssertGreaterThanOrEqual(fluency.restartCount, 1)
        XCTAssertGreaterThanOrEqual(fluency.longPauseCount, 3)
        XCTAssertLessThan(fluency.score, 0.45)
    }

    func testReadingAnswerSoundsSteady() {
        let words = F.readingAnswer(after: questionEnd)
        let fluency = FluencySignal.evaluate(answerWords: words, from: 5)
        XCTAssertEqual(fluency.fillerCount, 0)
        XCTAssertEqual(fluency.longPauseCount, 0)
        XCTAssertLessThan(fluency.paceVariation ?? 1, 0.2)
        XCTAssertGreaterThan(fluency.score, 0.8)
    }

    func testRestartsCountRepeatedWordsAndPhrases() {
        XCTAssertEqual(FluencySignal.countRestarts(["i", "i", "would"]), 1)
        XCTAssertEqual(FluencySignal.countRestarts(["i", "would", "i", "would", "use"]), 1)
        XCTAssertEqual(FluencySignal.countRestarts(["a", "token", "bucket"]), 0)
    }

    // MARK: Similarity

    private func reference(_ text: String, _ label: String = "GPT") -> ReferenceText {
        ReferenceText(id: UUID(), label: label, text: text, embedding: nil)
    }

    func testReadingAnswerMatchesTheAIAnswerWithSharedPhrases() {
        let spoken = F.readingAnswer(after: questionEnd).map(\.text).joined(separator: " ")
        let result = SimilaritySignal.evaluate(answerText: spoken, answerEmbedding: nil, questionText: F.question,
                                               references: [reference(F.aiAnswer)])
        XCTAssertGreaterThan(result.best!.phraseContainment, 0.6)
        XCTAssertFalse(result.best!.sharedPhrases.isEmpty)
        XCTAssertGreaterThan(result.score, 0.7)
    }

    func testHonestAnswerOnTheSameTopicMatchesWeakly() {
        let spoken = F.honestAnswer(after: questionEnd).map(\.text).joined(separator: " ")
        let result = SimilaritySignal.evaluate(answerText: spoken, answerEmbedding: nil, questionText: F.question,
                                               references: [reference(F.aiAnswer)])
        XCTAssertLessThan(result.score, 0.3)
    }

    func testAgreeingReferencesDiscountTheMatch() {
        let spoken = F.readingAnswer(after: questionEnd).map(\.text).joined(separator: " ")
        let single = SimilaritySignal.evaluate(answerText: spoken, answerEmbedding: nil, questionText: F.question,
                                               references: [reference(F.aiAnswer)])
        let agreeing = SimilaritySignal.evaluate(answerText: spoken, answerEmbedding: nil, questionText: F.question,
                                                 references: [reference(F.aiAnswer, "GPT"), reference(F.aiAnswer, "Claude")])
        XCTAssertGreaterThan(agreeing.referenceAgreement, 0.9)
        XCTAssertLessThan(agreeing.score, single.score)
    }

    func testCosine() {
        XCTAssertEqual(SimilaritySignal.cosine([1, 0], [1, 0]), 1, accuracy: 1e-9)
        XCTAssertEqual(SimilaritySignal.cosine([1, 0], [0, 1]), 0, accuracy: 1e-9)
        XCTAssertEqual(SimilaritySignal.cosine([1, 2], [1]), 0)
    }
}

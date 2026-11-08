import XCTest
@testable import InterviewCheckKit

final class CheatScorerTests: XCTestCase {
    private typealias F = DetectorFixtures
    private let questionEnd: TimeInterval = 100

    private func score(_ words: [TimedWord], judge: JudgeResult? = nil, gap: Bool = false) -> AnswerScore {
        let timing = TimingSignal.evaluate(answerWords: words, questionEnd: questionEnd, questionText: F.question)
        let fluency = FluencySignal.evaluate(answerWords: words, from: timing.substantiveIndex)
        let similarity = SimilaritySignal.evaluate(
            answerText: words.map(\.text).joined(separator: " "), answerEmbedding: nil, questionText: F.question,
            references: [ReferenceText(id: UUID(), label: "GPT-5 · Copilot", text: F.aiAnswer, embedding: nil)])
        return CheatScorer.score(timing: timing, fluency: fluency, similarity: similarity, judge: judge,
                                 hasTimingGap: gap)
    }

    func testReadingAnswerScoresHighWithReasons() {
        let result = score(F.readingAnswer(after: questionEnd))
        XCTAssertGreaterThanOrEqual(result.percent, 75)
        XCTAssertEqual(result.reasons.count, 3)
        XCTAssertTrue(result.reasons.contains { $0.contains("before the first real words") })
        XCTAssertTrue(result.reasons.contains { $0.hasPrefix("Matches the GPT-5 · Copilot answer word for word: ") }, "\(result.reasons)")
    }

    func testHonestAnswerScoresLowWithCounterpoints() {
        let result = score(F.honestAnswer(after: questionEnd))
        XCTAssertLessThanOrEqual(result.percent, 30)
        XCTAssertTrue(result.counterpoints.contains { $0.hasPrefix("Started answering within") })
    }

    func testJudgeAddsFollowUpsAndCanRaiseConfidence() {
        let judge = JudgeResult(likelihood: 85, confidence: "high",
                                evidence: ["Points in the same order as the AI answer"],
                                followUpQuestions: ["What bucket size would you pick?", "Why Lua?"])
        let result = score(F.readingAnswer(after: questionEnd), judge: judge)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.followUps.count, 2)
    }

    func testTimingGapLowersConfidence() {
        let result = score(F.readingAnswer(after: questionEnd), gap: true)
        XCTAssertEqual(result.confidence, .low)
    }

    func testShortAnswerIsLowConfidence() {
        let words = F.words("I'd use Redis", side: .candidate, start: questionEnd + 7)
        let result = score(words)
        XCTAssertEqual(result.confidence, .low)
    }

    func testEmptyAnswerScoresZero() {
        let result = CheatScorer.score(
            timing: TimingSignal.evaluate(answerWords: [], questionEnd: 0, questionText: ""),
            fluency: FluencySignal.evaluate(answerWords: [], from: nil),
            similarity: nil, judge: nil, hasTimingGap: false)
        XCTAssertEqual(result.percent, 0)
        XCTAssertEqual(result.confidence, .low)
    }

    // MARK: Judge parsing

    func testJudgeReplyParsesFromFencedJSON() {
        let reply = """
        ```json
        {"likelihood": "78", "confidence": "Medium", "evidence": ["Long pause", " "],
         "follow_up_questions": ["A", "B", "C"]}
        ```
        """
        let parsed = JudgeSignal.parse(reply)
        XCTAssertEqual(parsed?.likelihood, 78)
        XCTAssertEqual(parsed?.confidence, "medium")
        XCTAssertEqual(parsed?.evidence, ["Long pause"])
        XCTAssertEqual(parsed?.followUpQuestions, ["A", "B"])
    }

    func testJudgeReplyWithoutLikelihoodIsRejected() {
        XCTAssertNil(JudgeSignal.parse("I think they cheated."))
        XCTAssertNil(JudgeSignal.parse("{\"confidence\": \"high\"}"))
    }

    func testAnnotationMarksSilencesAndFillers() {
        let words = F.words("um ...2.0 I'd use Redis", side: .candidate, start: 101)
        let text = JudgeSignal.annotate(answerWords: words, questionEnd: 100)
        // "um" ends at 101.3; "I'd" starts 2.08 s later.
        XCTAssertEqual(text, "[um] [silence 2.1s] I'd use Redis")
    }

    func testAPauseAloneNeverFlagsAShortAnswer() {
        // "Yes, I have." eight seconds after the question, no references, no judge.
        let words = F.words("Yes, I have.", side: .candidate, start: 18)
        let timing = TimingSignal.pacedToAI(TimingSignal.evaluate(answerWords: words, questionEnd: 10, questionText: "Have you used Go?"),
                                            fastestFirstSentence: 4)
        let score = CheatScorer.score(timing: timing, fluency: FluencySignal.evaluate(answerWords: words, from: timing.substantiveIndex),
                                      similarity: nil, judge: nil, hasTimingGap: false)
        XCTAssertLessThanOrEqual(score.percent, 39)
        XCTAssertTrue(score.counterpoints.first?.hasPrefix("Too short to judge") ?? false)
        XCTAssertEqual(score.confidence, .low)
    }

    func testTranscriptScoresLeaveFluencyOut() {
        let answer = F.readingAnswer(after: 10)
        let timing = TimingSignal.evaluate(answerWords: answer, questionEnd: 10, questionText: F.question)
        let fluency = FluencySignal.evaluate(answerWords: answer, from: timing.substantiveIndex)
        XCTAssertTrue(fluency.isReliable)
        let score = CheatScorer.score(timing: timing, fluency: fluency, similarity: nil, judge: JudgeResult(likelihood: 30, confidence: "low",
                                      evidence: [], followUpQuestions: []), hasTimingGap: true, measuresFluency: false)
        XCTAssertNil(score.components.fluency)
        XCTAssertFalse(score.reasons.contains { $0.contains("very even pace") }, "no invented fluency reason")
    }
}

import XCTest
@testable import InterviewCheckKit

final class PhrasingSignalTests: XCTestCase {
    func testModelWordingScoresHigh() {
        let result = PhrasingSignal.evaluate(answerText: """
        In my previous role I led the migration to Kubernetes. Furthermore, I implemented a robust CI pipeline that \
        seamlessly integrated with our monitoring. It's worth noting that this initiative was central to reducing \
        deployment failures. Additionally, I worked across teams, which underscores my commitment to delivering \
        results in a fast-paced environment.
        """)
        XCTAssertGreaterThanOrEqual(result.score, 0.8)
        XCTAssertTrue(result.tells.contains("furthermore"))
        XCTAssertTrue(result.tells.contains("it's worth noting"))
        XCTAssertEqual(result.tells.first.map { PhrasingSignal.strong.map(\.1).contains($0) }, true,
                       "strong tells come before mild ones")
    }

    func testOrdinarySpeechStaysQuiet() {
        let result = PhrasingSignal.evaluate(answerText: """
        Um, so, honestly I, I kind of just jumped in. The build was, like, broken for two days and nobody owned it, \
        so I, uh, went through the logs, found a flaky test that hit the real network, and mocked it. We added a \
        robust retry later but mostly it was just that test.
        """)
        XCTAssertLessThan(result.score, PhrasingSignal.countsFrom)
    }

    func testSpokenStarLabelsAreAClue() {
        let result = PhrasingSignal.evaluate(answerText: """
        Situation, our checkout service was failing during the holiday sale. Task, I needed to restore it within the \
        hour. Action, I traced the retries, added backoff and rolled it out behind a flag. Result, errors dropped to \
        zero and we kept the flag as a kill switch.
        """)
        XCTAssertGreaterThanOrEqual(result.score, PhrasingSignal.countsFrom)
        XCTAssertEqual(result.tells.first, "situation \u{2026} task \u{2026} action \u{2026} result")
    }

    func testAListAloneDoesNotCount() {
        let result = PhrasingSignal.evaluate(answerText: """
        First, we measure the latency at the edge for a week. Second, we cache the hot keys in Redis close to the \
        gateway. Finally, we shed load with a token bucket when the cache misses spike, which keeps the database healthy.
        """)
        XCTAssertLessThan(result.score, PhrasingSignal.countsFrom)
        XCTAssertGreaterThan(result.score, 0)
        XCTAssertEqual(result.tells, ["first \u{2026} second \u{2026} finally"])
    }

    func testShortAnswersAreNotJudged() {
        let result = PhrasingSignal.evaluate(answerText: "Furthermore, it's worth noting the seamless, robust tapestry.")
        XCTAssertEqual(result.score, 0)
        XCTAssertTrue(result.tells.isEmpty)
    }

    func testRepeatsAreCounted() {
        XCTAssertEqual(PhrasingSignal.occurrences(of: ["furthermore"], in: ["furthermore", "a", "furthermore"]), 2)
        XCTAssertEqual(PhrasingSignal.announcedList(["so", "there", "are", "three", "key", "parts"]), "there are three key \u{2026}")
        XCTAssertNil(PhrasingSignal.starLabels(["the", "task", "situation", "action", "result"]))
    }

    func testWordingRaisesTheScoreOnlyWhenFound() {
        let words = DetectorFixtures.honestAnswer(after: 100)
        let timing = TimingSignal.evaluate(answerWords: words, questionEnd: 100, questionText: DetectorFixtures.question)
        let fluency = FluencySignal.evaluate(answerWords: words, from: timing.substantiveIndex)
        let plain = CheatScorer.score(timing: timing, fluency: fluency, similarity: nil, judge: nil, hasTimingGap: false)
        let quiet = CheatScorer.score(timing: timing, fluency: fluency, similarity: nil, judge: nil,
                                      phrasing: PhrasingResult(score: 0.1, tells: ["robust"], wordCount: 60),
                                      hasTimingGap: false)
        XCTAssertEqual(quiet.percent, plain.percent, "a little wording says nothing")
        XCTAssertNil(quiet.components.phrasing)

        let loud = CheatScorer.score(timing: timing, fluency: fluency, similarity: nil, judge: nil,
                                     phrasing: PhrasingResult(score: 1, tells: ["furthermore", "it's worth noting"], wordCount: 60),
                                     hasTimingGap: false)
        XCTAssertGreaterThan(loud.percent, plain.percent)
        XCTAssertTrue(loud.reasons.contains("Sounds written, not spoken: \u{201C}furthermore\u{201D}, \u{201C}it's worth noting\u{201D}"))
    }

    func testOldSavedWeightsGainTheNewWeight() throws {
        let old = #"{"timing":0.4,"fluency":0.2,"similarity":0.2,"judge":0.2}"#.data(using: .utf8) ?? Data()
        let weights = try JSONDecoder().decode(CheatScoreWeights.self, from: old)
        XCTAssertEqual(weights.timing, 0.4)
        XCTAssertEqual(weights.phrasing, CheatScoreWeights.default.phrasing)
    }
}

import XCTest
@testable import memanager

/// Two-tick hysteresis is the contract that keeps the pacing pill from
/// flickering against the natural noise of a conversation. These tests pin
/// down: the baseline state, the suppression of single-tick deviations, the
/// promotion on a second consecutive same-kind reading, the cancellation when
/// the deviation does not repeat, in-place confidence updates for stable
/// states, and the reset semantics that `prepareForNewSession()` relies on.
final class PacingDirectorTests: XCTestCase {

    // MARK: - Stub sampler

    private final class StubSampler: PacingSampling {
        var readings: [PacingReading] = []
        private var index = 0

        func evaluate(entries: [TranscriptEntry], now: Date) -> PacingReading {
            guard index < readings.count else {
                return PacingReading.empty
            }
            let reading = readings[index]
            index += 1
            return reading
        }
    }

    private func reading(
        wpm: Double? = nil,
        questions: Int = 0,
        utterances: Int = 0,
        gap: Double? = nil,
        candidateWPM: Double? = nil,
        trailingSilence: Double = 0,
        sampleSize: Int = 4
    ) -> PacingReading {
        PacingReading(
            timestamp: Date(),
            interviewerWordsPerMinute: wpm,
            candidateWordsPerMinute: candidateWPM,
            interviewerQuestionCount: questions,
            interviewerUtteranceCount: utterances,
            avgInterviewerUtteranceGapSeconds: gap,
            trailingSilenceSeconds: trailingSilence,
            sampleSize: sampleSize
        )
    }

    // MARK: - Baseline

    func testInitialStateIsMeasuredBaselineWithZeroConfidence() {
        let director = PacingDirector(sampler: StubSampler())
        XCTAssertEqual(director.state.kind, .measured)
        XCTAssertEqual(director.state.confidence, 0)
    }

    // MARK: - Hysteresis: single tick does not transition

    func testSingleDeviationTickDoesNotChangeKind() {
        let sampler = StubSampler()
        sampler.readings = [
            reading(wpm: 220, sampleSize: 6) // classifies as decisive
        ]
        let director = PacingDirector(sampler: sampler)

        director.evaluate(now: Date())

        XCTAssertEqual(director.state.kind, .measured, "One contrarian tick must be absorbed by the hysteresis gate")
    }

    // MARK: - Hysteresis: two consecutive ticks promote

    func testTwoConsecutiveDeviationTicksPromoteToNewKind() {
        let sampler = StubSampler()
        sampler.readings = [
            reading(wpm: 220, sampleSize: 6),
            reading(wpm: 220, sampleSize: 6)
        ]
        let director = PacingDirector(sampler: sampler)

        director.evaluate(now: Date())
        director.evaluate(now: Date())

        XCTAssertEqual(director.state.kind, .decisive, "Two consecutive same-kind readings must promote past the hysteresis gate")
        XCTAssertGreaterThan(director.state.confidence, 0)
    }

    // MARK: - Hysteresis: alternating kinds reset the pending counter

    func testAlternatingDeviationsCancelTheTransition() {
        let sampler = StubSampler()
        sampler.readings = [
            reading(wpm: 220, sampleSize: 6),                       // pending: decisive
            reading(trailingSilence: 15, sampleSize: 1),            // pending replaced: stalled
            reading(wpm: 220, sampleSize: 6)                        // pending replaced again: decisive (count = 1)
        ]
        let director = PacingDirector(sampler: sampler)

        director.evaluate(now: Date())
        director.evaluate(now: Date())
        director.evaluate(now: Date())

        XCTAssertEqual(
            director.state.kind,
            .measured,
            "If the pending kind keeps changing, hysteresis must never accumulate to the threshold"
        )
    }

    // MARK: - Same-kind readings update confidence in place

    func testSameKindReadingsRefreshConfidenceWithoutWaitingForHysteresis() {
        let sampler = StubSampler()
        sampler.readings = [
            reading(sampleSize: 1),    // measured, low density
            reading(sampleSize: 8)     // measured, max density
        ]
        let director = PacingDirector(sampler: sampler)

        director.evaluate(now: Date())
        let lowConfidence = director.state.confidence

        director.evaluate(now: Date())
        let highConfidence = director.state.confidence

        XCTAssertEqual(director.state.kind, .measured)
        XCTAssertGreaterThan(highConfidence, lowConfidence, "When kind is unchanged, confidence must update inline")
    }

    // MARK: - Reset

    func testResetReturnsToBaselineAndClearsPendingTransition() {
        let sampler = StubSampler()
        sampler.readings = [
            reading(wpm: 220, sampleSize: 6),
            reading(wpm: 220, sampleSize: 6) // promotes to decisive
        ]
        let director = PacingDirector(sampler: sampler)

        director.evaluate(now: Date())
        director.evaluate(now: Date())
        XCTAssertEqual(director.state.kind, .decisive, "Sanity check: state was promoted")

        director.reset()

        XCTAssertEqual(director.state.kind, .measured)
        XCTAssertEqual(director.state.confidence, 0)
    }

    func testResetDiscardsHalfBuiltHysteresisCount() {
        let sampler = StubSampler()
        sampler.readings = [
            reading(wpm: 220, sampleSize: 6),    // pending decisive, count=1
            reading(wpm: 220, sampleSize: 6)     // would promote on this tick if pending survived
        ]
        let director = PacingDirector(sampler: sampler)

        director.evaluate(now: Date())
        director.reset()
        director.evaluate(now: Date())

        XCTAssertEqual(
            director.state.kind,
            .measured,
            "Reset must clear pendingKind/pendingTicks so the next evaluate cannot reach the threshold from across the boundary"
        )
    }
}

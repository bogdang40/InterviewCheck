import XCTest
@testable import memanager

final class InterviewSignalEngineTests: XCTestCase {
    func testEmitComplexityNudge() {
        let engine = InterviewSignalEngine(cooldown: 1)
        let entry = TranscriptEntry(speaker: .speaker(0), text: "Can you explain the time complexity?")

        engine.consume(
            entries: [entry],
            captureState: .recording,
            enabled: true,
            now: Date()
        )

        XCTAssertEqual(engine.activeNudge?.type, .complexity)
        XCTAssertEqual(engine.activeMoment?.type, .complexity)
        XCTAssertFalse(engine.responseCards.isEmpty)
    }

    func testCooldownPreventsDuplicateNudge() {
        let engine = InterviewSignalEngine(cooldown: 60)
        let now = Date()
        let first = TranscriptEntry(speaker: .speaker(0), text: "Let's discuss trade-off decisions")
        let second = TranscriptEntry(speaker: .speaker(0), text: "What trade-off are you making here?")

        engine.consume(entries: [first], captureState: .recording, enabled: true, now: now)
        let firstID = engine.activeNudge?.id
        engine.consume(entries: [first, second], captureState: .recording, enabled: true, now: now.addingTimeInterval(5))

        XCTAssertEqual(engine.activeNudge?.id, firstID)
    }

    func testSilenceNudgeWhenNoTranscriptForThreshold() {
        let engine = InterviewSignalEngine(cooldown: 1)
        let now = Date()

        engine.evaluateSilence(
            now: now,
            lastTranscriptAt: now.addingTimeInterval(-35),
            captureState: .recording,
            enabled: true
        )

        XCTAssertEqual(engine.activeNudge?.type, .silence)
        XCTAssertEqual(engine.activeMoment?.type, .takeLead)
    }

    func testDismissClearsResponseCards() {
        let engine = InterviewSignalEngine(cooldown: 1)
        let entry = TranscriptEntry(speaker: .speaker(0), text: "What if there is an edge case?")

        engine.consume(entries: [entry], captureState: .recording, enabled: true, now: Date())
        XCTAssertFalse(engine.responseCards.isEmpty)

        engine.dismissCurrentNudge()

        XCTAssertNil(engine.activeMoment)
        XCTAssertTrue(engine.responseCards.isEmpty)
    }
}

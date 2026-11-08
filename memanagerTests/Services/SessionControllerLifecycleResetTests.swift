import XCTest
@testable import memanager

/// Regression coverage for the cross-session state-leak bug in
/// `SessionController.prepareForNewSession()`. Pacing is session-local and
/// must reset. Practice cards are now cross-session training data and must
/// survive the reset.
@MainActor
final class SessionControllerLifecycleResetTests: XCTestCase {
    private var controller: SessionController { SessionController.shared }

    override func setUp() {
        super.setUp()
        PacingDirector.shared.reset()
        PracticeStore.shared.reset()
        controller.resetSessionStateForTesting()
    }

    override func tearDown() {
        PacingDirector.shared.reset()
        PracticeStore.shared.reset()
        super.tearDown()
    }

    func testPrepareForNewSessionResetsPacingDirectorState() {
        let anchor = Date()
        let oldUtterance = TranscriptEntry(
            speaker: .speaker(0),
            text: "Walk me through your approach.",
            timestamp: anchor
        )
        PacingDirector.shared.ingest(entries: [oldUtterance])

        let observationTime = anchor.addingTimeInterval(13)
        PacingDirector.shared.evaluate(now: observationTime)
        PacingDirector.shared.evaluate(now: observationTime)

        XCTAssertEqual(
            PacingDirector.shared.state.kind,
            .stalled,
            "Sanity check: two-tick hysteresis should have promoted state to stalled"
        )

        controller.resetSessionStateForTesting()

        XCTAssertEqual(
            PacingDirector.shared.state.kind,
            .measured,
            "prepareForNewSession() must reset PacingDirector so the next session starts at the measured baseline"
        )
        XCTAssertEqual(
            PacingDirector.shared.state.confidence,
            0,
            "Reset state must carry zero confidence so the prompt addendum stays suppressed in the first ticks"
        )
    }

    func testPrepareForNewSessionKeepsPersistentPracticeDeck() {
        let card = PracticeCard(
            sessionID: "prior-session",
            topicTag: "graphs",
            prompt: "Articulate the BFS invariant.",
            idealReasoning: "BFS visits nodes in non-decreasing distance from the source.",
            transcriptSnippet: "I think you visit neighbors first.",
            candidateAttemptSummary: "Stalled on the invariant.",
            difficulty: .medium,
            sourceEvidence: .manual
        )
        let schedule = PracticeSchedule.initial(for: card.id, difficulty: .medium)
        PracticeStore.shared.insert(card: card, schedule: schedule)

        XCTAssertFalse(PracticeStore.shared.cards.isEmpty, "Sanity check: card was seeded")

        controller.resetSessionStateForTesting()

        XCTAssertFalse(
            PracticeStore.shared.cards.isEmpty,
            "prepareForNewSession() must not delete persisted PracticeStore cards"
        )
        XCTAssertEqual(
            controller.practiceCardsDueCount,
            0,
            "The due-count badge projection must drop to zero after reset"
        )
    }
}

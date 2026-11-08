import XCTest
@testable import memanager

final class PracticeStorePersistenceTests: XCTestCase {
    func testStoreLoadsPersistedCardsSchedulesAndReviews() {
        let persistence = FakePracticePersistence()
        let card = makeCard(id: "card-1")
        let schedule = PracticeSchedule(cardID: "card-1")
        let review = PracticeReview(cardID: "card-1", grade: .correctHesitation, attemptTranscript: "attempt")
        persistence.cards = [card]
        persistence.schedules = [schedule]
        persistence.reviews = [review]

        let store = PracticeStore(persistence: persistence)

        XCTAssertEqual(store.cards, [card])
        XCTAssertEqual(store.schedules, [schedule])
        XCTAssertEqual(store.reviews, [review])
    }

    func testInsertAndRecordPersistThroughBoundary() {
        let persistence = FakePracticePersistence()
        let store = PracticeStore(persistence: persistence)
        let card = makeCard(id: "card-2")
        let initial = PracticeSchedule(cardID: "card-2")
        let updated = PracticeSchedule(cardID: "card-2", repetitionCount: 1)
        let review = PracticeReview(
            cardID: "card-2",
            grade: .perfect,
            feedback: "Grounded",
            attemptTranscript: "I would verify the invariant with an edge case."
        )

        store.insert(card: card, schedule: initial)
        store.record(review: review, newSchedule: updated)

        XCTAssertEqual(persistence.savedCards, [card])
        XCTAssertEqual(persistence.savedSchedules, [initial])
        XCTAssertEqual(persistence.savedReviews, [review])
        XCTAssertEqual(persistence.savedReviewSchedules, [updated])
    }

    func testDeckBuilderSkipsCardsForAlreadyPersistedEvidence() {
        let persistence = FakePracticePersistence()
        let existing = makeCard(id: "existing", evidence: .drill(drillID: "drill-1"))
        persistence.cards = [existing]
        persistence.schedules = [PracticeSchedule(cardID: existing.id)]

        let store = PracticeStore(persistence: persistence)
        let builder = PracticeDeckBuilder(store: store, maxCardsPerSession: 3)

        let cards = builder.build(
            sessionID: "session-1",
            drills: [
                makeDrill(id: "drill-1", kind: .tradeoff),
                makeDrill(id: "drill-2", kind: .recovery)
            ],
            transcript: [],
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.sourceEvidence, .drill(drillID: "drill-2"))
        XCTAssertEqual(persistence.savedCards.count, 1)
    }

    func testFailedReviewRetainsTheDueCardAndScheduleForRetry() {
        let persistence = FakePracticePersistence()
        let card = makeCard(id: "retry")
        let initial = PracticeSchedule(cardID: card.id, nextReviewAt: Date(timeIntervalSince1970: 0))
        persistence.cards = [card]
        persistence.schedules = [initial]
        let store = PracticeStore(persistence: persistence)
        let reviewedAt = Date(timeIntervalSince1970: 100)
        let review = PracticeReview(cardID: card.id, reviewedAt: reviewedAt, grade: .perfect, attemptTranscript: "Keep this attempt")
        let updated = PracticeSchedule(cardID: card.id, repetitionCount: 1, nextReviewAt: Date(timeIntervalSince1970: 200))
        persistence.failReview = true

        XCTAssertFalse(store.record(review: review, newSchedule: updated))
        XCTAssertEqual(store.schedules, [initial])
        XCTAssertTrue(store.reviews.isEmpty)
        XCTAssertEqual(store.dueCards(on: reviewedAt).count, 1)
        XCTAssertNotNil(store.lastError)

        persistence.failReview = false
        XCTAssertTrue(store.record(review: review, newSchedule: updated))
        XCTAssertEqual(store.reviews, [review])
        XCTAssertEqual(store.schedules, [updated])
        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.record(review: review, newSchedule: updated))
        XCTAssertEqual(store.reviews.count, 1)
        XCTAssertEqual(persistence.savedReviews.count, 1)
    }

    private func makeCard(id: String, evidence: PracticeEvidence = .manual) -> PracticeCard {
        PracticeCard(
            id: id,
            sessionID: "session-1",
            topicTag: "tradeoff",
            prompt: "Name the tradeoff.",
            idealReasoning: "State the decision, the reason, and the rejected alternative.",
            transcriptSnippet: "I picked BFS.",
            candidateAttemptSummary: "Needed a clearer tradeoff.",
            difficulty: .medium,
            sourceEvidence: evidence
        )
    }

    private func makeDrill(id: String, kind: SessionDrillKind) -> SessionDrill {
        SessionDrill(
            id: id,
            sessionId: "session-1",
            debriefId: "debrief-1",
            kind: kind,
            title: "Drill",
            prompt: "Explain the choice.",
            transcriptSpan: "I picked BFS.",
            relatedThreadId: "thread-1",
            relatedTurnId: "turn-1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private final class FakePracticePersistence: PracticePersisting {
    var cards: [PracticeCard] = []
    var schedules: [PracticeSchedule] = []
    var reviews: [PracticeReview] = []
    var savedCards: [PracticeCard] = []
    var savedSchedules: [PracticeSchedule] = []
    var savedReviews: [PracticeReview] = []
    var savedReviewSchedules: [PracticeSchedule] = []
    var archivedCardIDs: [String] = []
    var clearCount = 0
    var failReview = false

    func loadPracticeState() -> (cards: [PracticeCard], schedules: [PracticeSchedule], reviews: [PracticeReview]) {
        (cards, schedules, reviews)
    }

    func savePracticeCard(_ card: PracticeCard, schedule: PracticeSchedule) {
        savedCards.append(card)
        savedSchedules.append(schedule)
    }

    func savePracticeReview(_ review: PracticeReview, schedule: PracticeSchedule) throws {
        if failReview { throw CocoaError(.fileWriteNoPermission) }
        savedReviews.append(review)
        savedReviewSchedules.append(schedule)
    }

    func archivePracticeCard(cardID: String) {
        archivedCardIDs.append(cardID)
    }

    func clearPracticeData() {
        clearCount += 1
    }
}

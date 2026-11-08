import XCTest
@testable import memanager

/// Locks down the interview-context SM-2 algebra so the next refactor cannot
/// silently change the rep-1 / rep-2 clamp, the easiness floor and ceiling,
/// or the failure-reset behavior. Pure-function tests; no Combine, no I/O.
final class SM2PracticeSchedulerTests: XCTestCase {

    private let cardID = "card-test-fixture"
    private let reviewedAt = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: PracticeSchedule.initial

    func testInitialScheduleHardCardDueIn15Minutes() {
        let now = reviewedAt
        let schedule = PracticeSchedule.initial(for: cardID, difficulty: .hard, now: now)
        XCTAssertEqual(schedule.cardID, cardID)
        XCTAssertEqual(schedule.repetitionCount, 0)
        XCTAssertEqual(schedule.easiness, 2.5, accuracy: 0.0001)
        XCTAssertEqual(schedule.lapses, 0)
        XCTAssertNil(schedule.lastReviewedAt)
        XCTAssertEqual(schedule.nextReviewAt.timeIntervalSince(now), 0.25 * 3600, accuracy: 0.001)
    }

    func testInitialScheduleMediumCardDueIn4Hours() {
        let schedule = PracticeSchedule.initial(for: cardID, difficulty: .medium, now: reviewedAt)
        XCTAssertEqual(schedule.nextReviewAt.timeIntervalSince(reviewedAt), 4 * 3600, accuracy: 0.001)
    }

    func testInitialScheduleEasyCardDueIn24Hours() {
        let schedule = PracticeSchedule.initial(for: cardID, difficulty: .easy, now: reviewedAt)
        XCTAssertEqual(schedule.nextReviewAt.timeIntervalSince(reviewedAt), 24 * 3600, accuracy: 0.001)
    }

    // MARK: Rep 1 / Rep 2 interview-context clamp

    func testFirstSuccessfulRepetitionIsClampedToTwoDays() {
        let scheduler = SM2PracticeScheduler()
        let initial = PracticeSchedule(cardID: cardID)

        let next = scheduler.updated(current: initial, grade: .perfect, reviewedAt: reviewedAt)

        XCTAssertEqual(next.repetitionCount, 1)
        XCTAssertEqual(next.intervalDays, 2, "Rep 1 must clamp to firstInterval (2 days), not stock SM-2's 1")
        XCTAssertEqual(next.nextReviewAt.timeIntervalSince(reviewedAt), 2 * 86400, accuracy: 0.001)
        XCTAssertEqual(next.lapses, 0)
        XCTAssertEqual(next.lastReviewedAt, reviewedAt)
    }

    func testSecondSuccessfulRepetitionIsClampedToFourDays() {
        let scheduler = SM2PracticeScheduler()
        let afterRep1 = scheduler.updated(
            current: PracticeSchedule(cardID: cardID),
            grade: .perfect,
            reviewedAt: reviewedAt
        )

        let next = scheduler.updated(current: afterRep1, grade: .perfect, reviewedAt: reviewedAt)

        XCTAssertEqual(next.repetitionCount, 2)
        XCTAssertEqual(next.intervalDays, 4, "Rep 2 must clamp to secondInterval (4 days), not stock SM-2's 6")
        XCTAssertEqual(next.nextReviewAt.timeIntervalSince(reviewedAt), 4 * 86400, accuracy: 0.001)
    }

    func testThirdRepetitionUsesEasinessMultiplier() {
        let scheduler = SM2PracticeScheduler()
        var schedule = PracticeSchedule(cardID: cardID)
        schedule = scheduler.updated(current: schedule, grade: .perfect, reviewedAt: reviewedAt)
        schedule = scheduler.updated(current: schedule, grade: .perfect, reviewedAt: reviewedAt)

        let rep3 = scheduler.updated(current: schedule, grade: .correctHesitation, reviewedAt: reviewedAt)

        XCTAssertEqual(rep3.repetitionCount, 3)
        // After 2 perfects easiness is 2.5 + 0.1 + 0.1 = 2.7 (no clamp). Grade
        // 4 contributes +0.0 to easiness, so easiness stays at 2.7. Interval
        // follows the SM-2 spec, rounding the product: round(4 * 2.7) = 11.
        XCTAssertEqual(rep3.easiness, 2.7, accuracy: 0.0001)
        XCTAssertEqual(rep3.intervalDays, 11)
    }

    // MARK: Failure path

    func testFailingGradeResetsRepetitionAndIncrementsLapses() {
        let scheduler = SM2PracticeScheduler()
        var schedule = PracticeSchedule(cardID: cardID)
        schedule = scheduler.updated(current: schedule, grade: .perfect, reviewedAt: reviewedAt)
        schedule = scheduler.updated(current: schedule, grade: .perfect, reviewedAt: reviewedAt)
        XCTAssertEqual(schedule.repetitionCount, 2)
        XCTAssertEqual(schedule.lapses, 0)

        let lapsed = scheduler.updated(current: schedule, grade: .blackout, reviewedAt: reviewedAt)

        XCTAssertEqual(lapsed.repetitionCount, 0, "Failure must reset the rep counter")
        XCTAssertEqual(lapsed.intervalDays, 1, "Failure must drop the interval back to 1 day")
        XCTAssertEqual(lapsed.lapses, 1, "Lapses must increment so the analytics layer can detect chronic failures")
    }

    // MARK: Easiness floor and ceiling

    func testEasinessIsClampedAtFloorAfterRepeatedBlackouts() {
        let scheduler = SM2PracticeScheduler()
        var schedule = PracticeSchedule(cardID: cardID, easiness: 1.4)

        // A single blackout pushes easiness by approximately -0.8, well below the floor.
        schedule = scheduler.updated(current: schedule, grade: .blackout, reviewedAt: reviewedAt)

        XCTAssertEqual(schedule.easiness, PracticeSchedule.easinessFloor, accuracy: 0.0001)
        XCTAssertEqual(PracticeSchedule.easinessFloor, 1.3, "Floor must remain 1.3 to match published SM-2")
    }

    func testEasinessIsClampedAtCeilingAfterRepeatedPerfects() {
        let scheduler = SM2PracticeScheduler()
        var schedule = PracticeSchedule(cardID: cardID, easiness: 2.95)

        // Each perfect grade contributes +0.1 to easiness; after one tick we are at 3.05, clamped to 3.0.
        schedule = scheduler.updated(current: schedule, grade: .perfect, reviewedAt: reviewedAt)

        XCTAssertEqual(schedule.easiness, PracticeSchedule.easinessCeiling, accuracy: 0.0001)
        XCTAssertEqual(PracticeSchedule.easinessCeiling, 3.0, "Ceiling must remain 3.0 to prevent runaway intervals")
    }

    // MARK: Vanilla SM-2 escape hatch

    func testCustomIntervalsRecoverVanillaSM2() {
        let scheduler = SM2PracticeScheduler(firstInterval: 1, secondInterval: 6)

        let rep1 = scheduler.updated(
            current: PracticeSchedule(cardID: cardID),
            grade: .perfect,
            reviewedAt: reviewedAt
        )
        XCTAssertEqual(rep1.intervalDays, 1)

        let rep2 = scheduler.updated(current: rep1, grade: .perfect, reviewedAt: reviewedAt)
        XCTAssertEqual(rep2.intervalDays, 6)
    }
}

import Foundation

/// SM-2 state for a single card. The scheduler consumes the current schedule
/// plus a new grade and returns a new schedule; the type is immutable so
/// tests can assert exact algebra without relying on `var` state.
struct PracticeSchedule: Equatable, Hashable {
    let cardID: String
    let repetitionCount: Int
    let easiness: Double
    let intervalDays: Int
    let nextReviewAt: Date
    let lapses: Int
    let lastReviewedAt: Date?

    static let easinessFloor: Double = 1.3
    static let easinessCeiling: Double = 3.0

    init(
        cardID: String,
        repetitionCount: Int = 0,
        easiness: Double = 2.5,
        intervalDays: Int = 0,
        nextReviewAt: Date = Date(),
        lapses: Int = 0,
        lastReviewedAt: Date? = nil
    ) {
        self.cardID = cardID
        self.repetitionCount = repetitionCount
        self.easiness = easiness
        self.intervalDays = intervalDays
        self.nextReviewAt = nextReviewAt
        self.lapses = lapses
        self.lastReviewedAt = lastReviewedAt
    }

    /// Initial schedule for a freshly-authored card. New cards are due
    /// immediately so the candidate drills them during the next Studio
    /// session rather than waiting for the first SM-2 interval.
    static func initial(for cardID: String, difficulty: PracticeDifficulty, now: Date = Date()) -> PracticeSchedule {
        let offsetHours: Double
        switch difficulty {
        case .easy: offsetHours = 24
        case .medium: offsetHours = 4
        case .hard: offsetHours = 0.25
        }
        return PracticeSchedule(
            cardID: cardID,
            repetitionCount: 0,
            easiness: 2.5,
            intervalDays: 0,
            nextReviewAt: now.addingTimeInterval(offsetHours * 3600),
            lapses: 0,
            lastReviewedAt: nil
        )
    }
}

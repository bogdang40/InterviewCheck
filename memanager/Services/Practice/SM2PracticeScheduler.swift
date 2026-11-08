import Foundation

/// Implements the SM-2 spaced repetition algorithm with one interview-context
/// tweak: the first two successful repetitions are clamped to 2 and 4 days
/// (instead of the stock 1 and 6). Interviews compound fast; re-exposure
/// should happen before the next practice window.
protocol PracticeSchedulingAlgorithm {
    func updated(
        current: PracticeSchedule,
        grade: PracticeGrade,
        reviewedAt: Date
    ) -> PracticeSchedule
}

final class SM2PracticeScheduler: PracticeSchedulingAlgorithm {

    private let firstInterval: Int
    private let secondInterval: Int

    /// `firstInterval` and `secondInterval` are days. Defaults reflect the
    /// interview-compounding clamp; pass stock `1, 6` to match vanilla SM-2.
    init(firstInterval: Int = 2, secondInterval: Int = 4) {
        self.firstInterval = firstInterval
        self.secondInterval = secondInterval
    }

    func updated(
        current: PracticeSchedule,
        grade: PracticeGrade,
        reviewedAt: Date
    ) -> PracticeSchedule {
        let gradeValue = grade.rawValue
        var repetitionCount = current.repetitionCount
        var intervalDays = current.intervalDays
        var lapses = current.lapses
        var easiness = current.easiness

        if gradeValue < 3 {
            repetitionCount = 0
            intervalDays = 1
            lapses += 1
        } else {
            repetitionCount += 1
            switch repetitionCount {
            case 1:
                intervalDays = firstInterval
            case 2:
                intervalDays = secondInterval
            default:
                // SM-2 spec: I(n) = round(I(n-1) * EF). Rounding happens on
                // the product; truncating here systematically shortens
                // intervals and over-drills mature cards.
                intervalDays = max(1, Int((Double(intervalDays) * easiness).rounded()))
            }
        }

        // Stock SM-2 easiness update, clamped at floor and ceiling.
        let q = Double(gradeValue)
        easiness += 0.1 - (5 - q) * (0.08 + (5 - q) * 0.02)
        easiness = max(PracticeSchedule.easinessFloor, min(PracticeSchedule.easinessCeiling, easiness))

        let nextReviewAt = reviewedAt.addingTimeInterval(TimeInterval(intervalDays) * 86400)

        return PracticeSchedule(
            cardID: current.cardID,
            repetitionCount: repetitionCount,
            easiness: easiness,
            intervalDays: intervalDays,
            nextReviewAt: nextReviewAt,
            lapses: lapses,
            lastReviewedAt: reviewedAt
        )
    }
}

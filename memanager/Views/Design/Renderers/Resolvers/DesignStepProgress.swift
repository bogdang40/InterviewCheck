import Foundation

/// Where a section stands against its step budget: the clamped current
/// index, the "step 2 of 3" position label, and the budget badge that turns
/// green only when the section is complete.
struct DesignStepProgress: Equatable {
    let stepCount: Int
    let expectedStepCount: Int?
    let currentIndex: Int
    let isComplete: Bool

    /// `isComplete` is the completeness report's verdict when one exists;
    /// without a report the step budget alone decides.
    init(stepCount: Int, expectedStepCount: Int?, currentIndex: Int, isComplete: Bool? = nil) {
        let safeCount = max(0, stepCount)
        self.stepCount = safeCount
        self.expectedStepCount = expectedStepCount
        self.currentIndex = safeCount > 0 ? max(0, min(currentIndex, safeCount - 1)) : 0
        if let isComplete {
            self.isComplete = isComplete
        } else if let expectedStepCount {
            self.isComplete = safeCount >= expectedStepCount
        } else {
            self.isComplete = safeCount > 0
        }
    }

    var hasSteps: Bool { stepCount > 0 }
    var hasPrevious: Bool { currentIndex > 0 }
    var hasNext: Bool { currentIndex < stepCount - 1 }

    /// "step 2 of 3", as easy to say as to scan.
    var positionLabel: String {
        hasSteps ? "step \(currentIndex + 1) of \(stepCount)" : "no steps"
    }

    /// "3 of 4 steps" against the budget, or a plain count without one.
    var budgetLabel: String {
        if let expectedStepCount {
            return "\(stepCount) of \(expectedStepCount) steps"
        }
        return stepCount == 1 ? "1 step" : "\(stepCount) steps"
    }

    var budgetTone: OverlayTone {
        isComplete ? .success : .warning
    }
}

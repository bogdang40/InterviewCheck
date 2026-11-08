import Foundation

/// The four review answers a spaced repetition deck expects. Each maps
/// onto one SM2 grade so the six grade enum and its scheduler stay as
/// they are; the grader's finer grades fold back into a choice for display.
enum PracticeGradeChoice: String, CaseIterable, Identifiable {
    case again
    case hard
    case good
    case easy

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    var grade: PracticeGrade {
        switch self {
        case .again: return .incorrectHardRecall
        case .hard: return .correctDifficult
        case .good: return .correctHesitation
        case .easy: return .perfect
        }
    }

    /// The number key that triggers the choice.
    var key: String {
        switch self {
        case .again: return "1"
        case .hard: return "2"
        case .good: return "3"
        case .easy: return "4"
        }
    }

    var tone: OverlayTone {
        switch self {
        case .again: return .critical
        case .hard: return .warning
        case .good: return .success
        case .easy: return .info
        }
    }

    /// The choice a full SM2 grade lands on.
    static func choice(for grade: PracticeGrade) -> PracticeGradeChoice {
        switch grade {
        case .blackout, .incorrectHardRecall, .incorrectEasyRecall: return .again
        case .correctDifficult: return .hard
        case .correctHesitation: return .good
        case .perfect: return .easy
        }
    }
}

/// The interval each choice would schedule, computed with the scheduler
/// on the current schedule without recording anything.
struct PracticeIntervalPreview: Identifiable, Equatable {
    let choice: PracticeGradeChoice
    let intervalDays: Int

    var id: String { choice.id }

    var label: String {
        Self.label(days: intervalDays)
    }

    static func label(days: Int) -> String {
        "\(max(days, 1))d"
    }

    static func previews(
        for schedule: PracticeSchedule,
        scheduler: PracticeSchedulingAlgorithm,
        now: Date = Date()
    ) -> [PracticeIntervalPreview] {
        PracticeGradeChoice.allCases.map { choice in
            let next = scheduler.updated(current: schedule, grade: choice.grade, reviewedAt: now)
            return PracticeIntervalPreview(choice: choice, intervalDays: next.intervalDays)
        }
    }
}

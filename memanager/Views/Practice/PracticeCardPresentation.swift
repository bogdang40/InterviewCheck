import Foundation

/// Display vocabulary for practice cards.
extension PracticeDifficulty {
    var title: String {
        rawValue.capitalized
    }

    var tone: OverlayTone {
        switch self {
        case .easy: return .success
        case .medium: return .warning
        case .hard: return .critical
        }
    }
}

extension PracticeAttemptEvaluation {
    /// Passing attempts read as success, the rest as a warning nudge.
    var tone: OverlayTone {
        grade.isPassing ? .success : .warning
    }

    var title: String {
        "Suggested: \(grade.label)"
    }
}

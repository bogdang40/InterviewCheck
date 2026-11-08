import Foundation

/// One place that decides which semantic tone each Solve concept carries,
/// so a time constraint, a time complexity, and an edge case test always
/// read in the same color no matter which section shows them.
enum SolveTonePolicy {
    static func tone(for kind: Constraint.ConstraintType) -> OverlayTone {
        switch kind {
        case .time: return .warning
        case .space: return .info
        case .input: return .neutral
        case .output: return .success
        }
    }

    static func tone(for category: TestCase.TestCategory) -> OverlayTone {
        switch category {
        case .base: return .success
        case .edge: return .warning
        case .error: return .critical
        }
    }

    static func tone(for kind: ComplexityAnalysis.ComplexityType) -> OverlayTone {
        switch kind {
        case .time: return .warning
        case .space: return .info
        }
    }
}

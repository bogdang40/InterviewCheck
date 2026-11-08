import Foundation

/// What the interviewer is listening for in each Solve section, phrased
/// as the one thing to do. Follows the UMPIRE shape interviewers grade
/// against: understand, match and plan, implement, review, evaluate.
enum SolveSectionGuide {
    static func stage(for section: MentorResponse.Section) -> String {
        switch section {
        case .problem: return "Understand"
        case .clarifyingQuestions: return "Ask"
        case .implementation: return "Plan and build"
        case .tests: return "Review"
        case .complexity: return "Evaluate"
        case .systemDesign: return "Design"
        }
    }

    static func advice(for section: MentorResponse.Section) -> String {
        switch section {
        case .problem: return "Restate it in your own words, then name the key insight."
        case .clarifyingQuestions: return "Ask before you build. Confirm edge cases and constraints out loud."
        case .implementation: return "Narrate every decision while you type it."
        case .tests: return "Walk one example through the code, then the edge cases."
        case .complexity: return "State time and space, then the trade off you chose."
        case .systemDesign: return "Requirements first, then scale, then the design."
        }
    }
}

extension MentorResponse {
    /// True when at least one coding section has text.
    var hasSolveContent: Bool {
        MentorSurfaceResolver.solveSections.contains { section in
            !content(for: section).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var hasDesignContent: Bool {
        !systemDesign.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

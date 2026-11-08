import Foundation

/// Determines which type of problem solving to use
enum SolveMode {
    case algorithm      // Standard coding/algorithm problems
    case systemDesign   // System design interview questions
}

struct QuickAssistTurnFeedback {
    let turnID: String
    let accepted: Bool
    let note: String?

    var status: QuickAssistTurnFeedbackStatus {
        accepted ? .accepted : .rejected
    }
}

struct QuickAssistInterruptedAnswer: Equatable {
    enum Reason: Equatable { case cancelled, failed }
    let response: String
    let question: String
    let reason: Reason
}


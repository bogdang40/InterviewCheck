import Foundation

/// UI facing summary of the classified question family for the active turn.
/// Rendered as a chip so the candidate always sees which playbook is
/// driving the answer, and can distrust it at a glance when it is wrong.
struct QuickAssistAnswerFamilyBadge: Equatable {
    let familyName: String
    let frameworkName: String
    let isProbe: Bool
}

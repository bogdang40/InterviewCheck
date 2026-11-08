import Foundation

struct QuickAssistRecoveryAction: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case askClarifyingFollowUp
        case retryDeep
        case openTimeline
    }

    let kind: Kind
    let label: String
    let note: String?
    let suggestedQuestion: String?

    var id: String {
        "\(kind.rawValue):\(label):\(suggestedQuestion ?? "")"
    }
}

struct QuickAssistRecoveryPlan: Equatable {
    let severity: WorkstreamEventSeverity
    let title: String
    let message: String
    let actions: [QuickAssistRecoveryAction]
}

struct QuickAssistRecoveryPlannerInput {
    let call: QuickAssistCallRecord
    let relatedMemorySnippets: [RelatedMemorySnippet]
    let coachFindings: [CoachFindingRecord]
}

protocol QuickAssistRecoveryPlanning {
    func buildPlan(input: QuickAssistRecoveryPlannerInput) -> QuickAssistRecoveryPlan?
}

final class QuickAssistRecoveryPlanner: QuickAssistRecoveryPlanning {
    func buildPlan(input: QuickAssistRecoveryPlannerInput) -> QuickAssistRecoveryPlan? {
        let call = input.call
        let pinnedCount = input.relatedMemorySnippets.filter(\.isPinned).count
        let topCoachFinding = input.coachFindings.first
        let followUpQuestion = normalizedQuestion(
            call.verificationSuggestedFollowUp,
            fallback: "What assumption should I verify before continuing?"
        )

        if call.userFeedbackStatus == .rejected {
            return QuickAssistRecoveryPlan(
                severity: .warning,
                title: "Last turn was rejected",
                message: "Retry on the deep tier or open the timeline to inspect what changed before branching.",
                actions: [
                    QuickAssistRecoveryAction(
                        kind: .retryDeep,
                        label: "Retry Deep",
                        note: "Re-run the selected turn on the deeper model tier.",
                        suggestedQuestion: call.question
                    ),
                    QuickAssistRecoveryAction(
                        kind: .openTimeline,
                        label: "Open Timeline",
                        note: "Inspect the surrounding thread events before continuing.",
                        suggestedQuestion: nil
                    )
                ]
            )
        }

        if call.verificationStatus == .failed {
            return QuickAssistRecoveryPlan(
                severity: .warning,
                title: "Quick Assist could not verify this turn",
                message: "The current answer is weak against available evidence. Clarify the missing assumption or retry on the deep tier.",
                actions: [
                    QuickAssistRecoveryAction(
                        kind: .askClarifyingFollowUp,
                        label: "Ask Clarifying Follow-up",
                        note: "Use the verifier's suggested follow-up question.",
                        suggestedQuestion: followUpQuestion
                    ),
                    QuickAssistRecoveryAction(
                        kind: .retryDeep,
                        label: "Retry Deep",
                        note: "Regenerate the turn with a higher-quality budget.",
                        suggestedQuestion: call.question
                    )
                ]
            )
        }

        if call.verificationStatus == .needsReview {
            var actions = [
                QuickAssistRecoveryAction(
                    kind: .askClarifyingFollowUp,
                    label: "Clarify Then Continue",
                    note: "Use the verifier's suggested follow-up question.",
                    suggestedQuestion: followUpQuestion
                )
            ]

            if (call.routeConfidence ?? 1.0) < 0.72 || (call.unsupportedClaimCount ?? 0) > 1 {
                actions.append(
                    QuickAssistRecoveryAction(
                        kind: .retryDeep,
                        label: "Retry Deep",
                        note: "Retry the selected turn with a deeper model tier.",
                        suggestedQuestion: call.question
                    )
                )
            }

            return QuickAssistRecoveryPlan(
                severity: .warning,
                title: "This turn needs review",
                message: recoveryMessage(
                    unsupportedClaimCount: call.unsupportedClaimCount ?? 0,
                    pinnedCount: pinnedCount,
                    coachTitle: topCoachFinding?.title
                ),
                actions: actions
            )
        }

        if let routeConfidence = call.routeConfidence,
           routeConfidence < 0.58 {
            return QuickAssistRecoveryPlan(
                severity: .info,
                title: "Routing confidence was low",
                message: "This answer completed, but the route decision was weak. If it feels off, retry on the deep tier or inspect the timeline.",
                actions: [
                    QuickAssistRecoveryAction(
                        kind: .retryDeep,
                        label: "Retry Deep",
                        note: "Re-run the question with a deeper tier.",
                        suggestedQuestion: call.question
                    ),
                    QuickAssistRecoveryAction(
                        kind: .openTimeline,
                        label: "Open Timeline",
                        note: "Inspect routing, memory, and coach signals around this turn.",
                        suggestedQuestion: nil
                    )
                ]
            )
        }

        return nil
    }

    private func normalizedQuestion(_ raw: String?, fallback: String) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func recoveryMessage(
        unsupportedClaimCount: Int,
        pinnedCount: Int,
        coachTitle: String?
    ) -> String {
        var fragments: [String] = []
        if unsupportedClaimCount > 0 {
            fragments.append("\(unsupportedClaimCount) unsupported claim(s) need validation.")
        }
        if pinnedCount > 0 {
            fragments.append("Pinned memory is available for the retry.")
        }
        if let coachTitle,
           !coachTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fragments.append("Coach signal: \(coachTitle).")
        }
        if fragments.isEmpty {
            return "Ask a targeted follow-up before trusting this answer."
        }
        return fragments.joined(separator: " ")
    }
}

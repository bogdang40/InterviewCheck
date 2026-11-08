import Foundation

/// Picks the single most useful message for the banner above the composer,
/// in priority order: rejected turn, failed or unverified turn with a
/// recovery plan, coach finding, live coach nudge, verified turn, context
/// warning, then a silent ready state.
enum QuickAssistPrimaryInsightResolver {
    static func resolve(input: QuickAssistPrimaryInsightResolverInput) -> QuickAssistPrimaryInsight {
        if input.feedbackStatus == .rejected {
            if let recoveryPlan = input.recoveryPlan {
                return insight(from: recoveryPlan, tone: .critical, titleOverride: "Last turn was rejected", statusLabel: "Rejected")
            }
            return QuickAssistPrimaryInsight(
                tone: .critical,
                title: "Last turn was rejected",
                message: "Retry on the deep tier or inspect the thread timeline before continuing.",
                statusLabel: "Rejected",
                primaryActionLabel: timelineActionLabel(threadID: input.activeThreadID),
                primaryAction: timelineAction(threadID: input.activeThreadID),
                secondaryActionLabel: nil,
                secondaryAction: nil
            )
        }

        if let recoveryPlan = input.recoveryPlan,
           input.verificationRecord?.status == .failed || input.verificationRecord?.status == .needsReview {
            return insight(
                from: recoveryPlan,
                tone: input.verificationRecord?.status == .failed ? .critical : .warning,
                titleOverride: nil,
                statusLabel: input.verificationRecord?.status.displayLabel
            )
        }

        if let finding = input.coachFindings.first(where: { $0.severity == .critical }) ?? input.coachFindings.first {
            return QuickAssistPrimaryInsight(
                tone: finding.severity == .critical ? .critical : .warning,
                title: finding.title,
                message: finding.message,
                statusLabel: finding.severity.rawValue.capitalized,
                primaryActionLabel: "Use suggestion",
                primaryAction: .applyCoachSuggestion(finding.id),
                secondaryActionLabel: finding.threadId == nil ? "Dismiss" : "Open timeline",
                secondaryAction: finding.threadId.map(QuickAssistPrimaryInsightAction.openTimeline) ?? .dismissCoachFinding(finding.id)
            )
        }

        if let hubNudge = input.hubNudge {
            return QuickAssistPrimaryInsight(
                tone: .info,
                title: hubNudge.title,
                message: hubNudge.message,
                statusLabel: "Live coach",
                primaryActionLabel: "Focus question",
                primaryAction: .focusQuestion,
                secondaryActionLabel: "Dismiss",
                secondaryAction: .dismissHubNudge
            )
        }

        if let verificationRecord = input.verificationRecord, verificationRecord.status == .verified {
            return QuickAssistPrimaryInsight(
                tone: .success,
                title: "Turn looks grounded",
                message: QuickAssistRouteSummaryFormatter.format(input.routeSummary)
                    ?? "Verification is green. Follow up or branch from this turn.",
                statusLabel: verificationRecord.status.displayLabel,
                primaryActionLabel: timelineActionLabel(threadID: input.activeThreadID),
                primaryAction: timelineAction(threadID: input.activeThreadID),
                secondaryActionLabel: nil,
                secondaryAction: nil
            )
        }

        if let contextStatusMessage = input.contextStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !contextStatusMessage.isEmpty {
            return QuickAssistPrimaryInsight(
                tone: .warning,
                title: "Context needs attention",
                message: contextStatusMessage,
                statusLabel: "Context",
                primaryActionLabel: "Focus question",
                primaryAction: .focusQuestion,
                secondaryActionLabel: timelineActionLabel(threadID: input.activeThreadID),
                secondaryAction: timelineAction(threadID: input.activeThreadID)
            )
        }

        return QuickAssistPrimaryInsight(
            tone: .neutral,
            title: "Quick Assist is ready",
            message: QuickAssistRouteSummaryFormatter.format(input.routeSummary)
                ?? "Ask a focused question, then follow up or branch from the active turn.",
            statusLabel: nil,
            primaryActionLabel: "Focus question",
            primaryAction: .focusQuestion,
            secondaryActionLabel: timelineActionLabel(threadID: input.activeThreadID),
            secondaryAction: timelineAction(threadID: input.activeThreadID)
        )
    }

    private static func insight(
        from plan: QuickAssistRecoveryPlan,
        tone: OverlayTone,
        titleOverride: String?,
        statusLabel: String?
    ) -> QuickAssistPrimaryInsight {
        let primary = plan.actions.first
        let secondary = plan.actions.dropFirst().first
        return QuickAssistPrimaryInsight(
            tone: tone,
            title: titleOverride ?? plan.title,
            message: plan.message,
            statusLabel: statusLabel,
            primaryActionLabel: primary?.label,
            primaryAction: primary.map(QuickAssistPrimaryInsightAction.recovery),
            secondaryActionLabel: secondary?.label,
            secondaryAction: secondary.map(QuickAssistPrimaryInsightAction.recovery)
        )
    }

    private static func timelineActionLabel(threadID: String?) -> String? {
        guard let threadID, !threadID.isEmpty else { return nil }
        return "Open timeline"
    }

    private static func timelineAction(threadID: String?) -> QuickAssistPrimaryInsightAction? {
        guard let threadID, !threadID.isEmpty else { return nil }
        return .openTimeline(threadID)
    }
}

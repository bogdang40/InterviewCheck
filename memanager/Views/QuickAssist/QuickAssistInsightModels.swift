import Foundation

/// What the insight banner can ask the studio to do.
enum QuickAssistPrimaryInsightAction: Equatable {
    case recovery(QuickAssistRecoveryAction)
    case applyCoachSuggestion(String)
    case openTimeline(String)
    case dismissCoachFinding(String)
    case dismissHubNudge
    case focusQuestion
}

/// The one message the studio shows above the composer. A neutral tone
/// means nothing needs attention and the banner stays hidden.
struct QuickAssistPrimaryInsight: Equatable {
    let tone: OverlayTone
    let title: String
    let message: String
    let statusLabel: String?
    let primaryActionLabel: String?
    let primaryAction: QuickAssistPrimaryInsightAction?
    let secondaryActionLabel: String?
    let secondaryAction: QuickAssistPrimaryInsightAction?

    /// Neutral insights describe a calm state; the banner renders nothing.
    var isSilent: Bool {
        tone == .neutral
    }
}

struct QuickAssistPrimaryInsightResolverInput {
    let feedbackStatus: QuickAssistTurnFeedbackStatus
    let verificationRecord: QuickAssistVerificationRecord?
    let recoveryPlan: QuickAssistRecoveryPlan?
    let coachFindings: [CoachFindingRecord]
    let hubNudge: HubNudge?
    let routeSummary: String?
    let contextStatusMessage: String?
    let activeThreadID: String?
}

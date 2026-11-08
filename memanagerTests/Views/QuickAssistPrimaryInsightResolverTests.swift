import XCTest
@testable import memanager

final class QuickAssistPrimaryInsightResolverTests: XCTestCase {
    func testRejectedFeedbackUsesRecoveryPlanBeforeCoachSignals() {
        let recoveryPlan = QuickAssistRecoveryPlan(
            severity: .warning,
            title: "This turn needs review",
            message: "Retry with a deeper model or inspect the timeline.",
            actions: [
                QuickAssistRecoveryAction(kind: .retryDeep, label: "Retry Deep", note: "Retry on the deeper tier.", suggestedQuestion: "What changed?"),
                QuickAssistRecoveryAction(kind: .openTimeline, label: "Open Timeline", note: nil, suggestedQuestion: nil)
            ]
        )
        let insight = QuickAssistPrimaryInsightResolver.resolve(
            input: input(
                feedbackStatus: .rejected,
                verificationRecord: QuickAssistVerificationRecord(status: .needsReview, confidence: 0.42, unsupportedClaimCount: 2, missingQuestions: [], suggestedFollowUp: nil),
                recoveryPlan: recoveryPlan,
                coachFindings: [finding(severity: .critical)]
            )
        )

        XCTAssertEqual(insight.title, "Last turn was rejected")
        XCTAssertEqual(insight.tone, .critical)
        XCTAssertFalse(insight.isSilent)
        XCTAssertEqual(insight.primaryAction, .recovery(recoveryPlan.actions[0]))
    }

    func testFailedVerificationUsesRecoveryPlanWithFailedStatus() {
        let recoveryPlan = QuickAssistRecoveryPlan(
            severity: .warning,
            title: "Quick Assist could not verify this turn",
            message: "Clarify the missing assumption or retry.",
            actions: [QuickAssistRecoveryAction(kind: .askClarifyingFollowUp, label: "Ask Clarifying Follow-up", note: nil, suggestedQuestion: "Which assumption needs proof?")]
        )
        let insight = QuickAssistPrimaryInsightResolver.resolve(
            input: input(
                verificationRecord: QuickAssistVerificationRecord(status: .failed, confidence: 0.15, unsupportedClaimCount: 3, missingQuestions: ["What evidence supports this?"], suggestedFollowUp: "Which assumption needs proof?"),
                recoveryPlan: recoveryPlan
            )
        )

        XCTAssertEqual(insight.title, recoveryPlan.title)
        XCTAssertEqual(insight.statusLabel, "Failed")
        XCTAssertEqual(insight.tone, .critical)
        XCTAssertEqual(insight.primaryAction, .recovery(recoveryPlan.actions[0]))
    }

    func testCriticalCoachFindingWinsWhenNoRecoveryPlanExists() {
        let critical = finding(severity: .critical)
        let insight = QuickAssistPrimaryInsightResolver.resolve(input: input(coachFindings: [critical]))

        XCTAssertEqual(insight.title, critical.title)
        XCTAssertEqual(insight.statusLabel, "Critical")
        XCTAssertEqual(insight.primaryAction, .applyCoachSuggestion(critical.id))
        XCTAssertEqual(insight.secondaryAction, .openTimeline("thread-1"))
    }

    func testVerifiedTurnFormatsRouteSummaryIntoWords() {
        let insight = QuickAssistPrimaryInsightResolver.resolve(
            input: input(
                verificationRecord: QuickAssistVerificationRecord(status: .verified, confidence: 0.91, unsupportedClaimCount: 0, missingQuestions: [], suggestedFollowUp: nil),
                routeSummary: "Mode: Auto | Resolved: Clarify | Intent: Clarify | Tier: FAST | Context: transcript"
            )
        )

        XCTAssertEqual(insight.tone, .success)
        XCTAssertEqual(insight.message, "Mode Auto resolved as Clarify, Intent Clarify, Tier Fast")
        XCTAssertFalse(insight.message.contains("|"))
    }

    func testContextStatusWarningShowsWhenNothingElseNeedsAttention() {
        let insight = QuickAssistPrimaryInsightResolver.resolve(input: input(contextStatusMessage: "Screenshots were skipped: the provider rejected the image."))

        XCTAssertEqual(insight.tone, .warning)
        XCTAssertEqual(insight.title, "Context needs attention")
        XCTAssertEqual(insight.primaryAction, .focusQuestion)
        XCTAssertFalse(insight.isSilent)
    }

    func testFallbackInsightIsSilentAndKeepsComposerAsPrimaryAction() {
        let insight = QuickAssistPrimaryInsightResolver.resolve(input: input(routeSummary: "Mode: Conversation | Tier: FAST"))

        XCTAssertEqual(insight.title, "Quick Assist is ready")
        XCTAssertTrue(insight.isSilent)
        XCTAssertEqual(insight.message, "Mode Conversation, Tier Fast")
        XCTAssertEqual(insight.primaryAction, .focusQuestion)
        XCTAssertEqual(insight.secondaryAction, .openTimeline("thread-1"))
    }

    private func input(
        feedbackStatus: QuickAssistTurnFeedbackStatus = .none,
        verificationRecord: QuickAssistVerificationRecord? = nil,
        recoveryPlan: QuickAssistRecoveryPlan? = nil,
        coachFindings: [CoachFindingRecord] = [],
        hubNudge: HubNudge? = nil,
        routeSummary: String? = nil,
        contextStatusMessage: String? = nil
    ) -> QuickAssistPrimaryInsightResolverInput {
        QuickAssistPrimaryInsightResolverInput(
            feedbackStatus: feedbackStatus,
            verificationRecord: verificationRecord,
            recoveryPlan: recoveryPlan,
            coachFindings: coachFindings,
            hubNudge: hubNudge,
            routeSummary: routeSummary,
            contextStatusMessage: contextStatusMessage,
            activeThreadID: "thread-1"
        )
    }

    private func finding(severity: WorkstreamEventSeverity) -> CoachFindingRecord {
        CoachFindingRecord(
            sessionId: "session-1",
            threadId: "thread-1",
            issueType: .quickAssistFailureBurst,
            severity: severity,
            title: "Stalled recovery",
            message: "Use the coach suggestion now.",
            suggestedQuestion: "What changed in the last attempt?",
            suggestedContext: "",
            evidence: [],
            dedupeKey: "coach"
        )
    }
}

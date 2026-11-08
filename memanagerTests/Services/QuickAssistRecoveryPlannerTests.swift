import XCTest
@testable import memanager

final class QuickAssistRecoveryPlannerTests: XCTestCase {
    private let planner = QuickAssistRecoveryPlanner()

    func testRejectedTurnProducesRetryPlan() {
        let call = QuickAssistCallRecord(
            sessionId: "session",
            threadId: "thread",
            turnId: UUID().uuidString,
            provider: "openai",
            model: "gpt-test",
            status: "success",
            question: "Why is this failing?",
            responseText: "Try a dictionary.",
            contextMode: .implementationContext,
            modelTier: .fast,
            questionSource: .manual,
            verificationStatus: .needsReview,
            userFeedbackStatus: .rejected
        )

        let plan = planner.buildPlan(
            input: QuickAssistRecoveryPlannerInput(
                call: call,
                relatedMemorySnippets: [],
                coachFindings: []
            )
        )

        XCTAssertEqual(plan?.title, "Last turn was rejected")
        XCTAssertEqual(plan?.actions.first?.kind, .retryDeep)
    }

    func testNeedsReviewPlanPrefersClarifyingFollowUp() {
        let call = QuickAssistCallRecord(
            sessionId: "session",
            threadId: "thread",
            turnId: UUID().uuidString,
            provider: "openai",
            model: "gpt-test",
            status: "success",
            question: "How do I continue?",
            responseText: "It should probably work.",
            contextMode: .conversation,
            modelTier: .fast,
            questionSource: .manual,
            routeConfidence: 0.61,
            verificationStatus: .needsReview,
            unsupportedClaimCount: 2,
            verificationSuggestedFollowUp: "Which assumption should I validate first?"
        )

        let plan = planner.buildPlan(
            input: QuickAssistRecoveryPlannerInput(
                call: call,
                relatedMemorySnippets: [],
                coachFindings: []
            )
        )

        XCTAssertEqual(plan?.actions.first?.kind, .askClarifyingFollowUp)
        XCTAssertEqual(plan?.actions.first?.suggestedQuestion, "Which assumption should I validate first?")
    }

    func testVerifiedHighConfidenceTurnNeedsNoRecoveryPlan() {
        let call = QuickAssistCallRecord(
            sessionId: "session",
            threadId: "thread",
            turnId: UUID().uuidString,
            provider: "openai",
            model: "gpt-test",
            status: "success",
            question: "What is the issue?",
            responseText: "Add a guard and re-run the failing test.",
            contextMode: .implementationContext,
            modelTier: .deep,
            questionSource: .manual,
            routeConfidence: 0.91,
            verificationStatus: .verified,
            verificationConfidence: 0.9
        )

        let plan = planner.buildPlan(
            input: QuickAssistRecoveryPlannerInput(
                call: call,
                relatedMemorySnippets: [],
                coachFindings: []
            )
        )

        XCTAssertNil(plan)
    }
}

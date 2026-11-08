import XCTest
@testable import memanager

final class QuickAssistExperimentServicesTests: XCTestCase {
    func testRunnerGeneratesCurrentDeepAndAlternateCandidates() {
        let runner = QuickAssistExperimentRunner()
        let context = QuickAssistExperimentContext(
            baseCall: QuickAssistCallRecord(
                sessionId: "session",
                provider: "Claude",
                model: "haiku"
            ),
            selectedIntent: .conversation,
            routeConfidence: 0.44,
            availableProviders: [.openai],
            currentProvider: .claude
        )

        let plans = runner.candidatePlans(for: context)

        XCTAssertEqual(plans.map(\.role), [.currentRoute, .sameProviderDeep, .alternateProvider])
    }

    func testOutcomeScorerRewardsVerificationAndLatency() {
        let scorer = QuickAssistOutcomeScorer()
        let fastVerified = QuickAssistCallRecord(
            sessionId: "session",
            provider: "Claude",
            model: "haiku",
            durationMs: 900,
            verificationStatus: .verified,
            unsupportedClaimCount: 0,
            userFeedbackStatus: .accepted
        )
        let slowNeedsReview = QuickAssistCallRecord(
            sessionId: "session",
            provider: "OpenAI",
            model: "gpt-5",
            durationMs: 4_500,
            verificationStatus: .needsReview,
            unsupportedClaimCount: 2,
            userFeedbackStatus: .none
        )

        let fastScore = scorer.score(call: fastVerified, preferredProvider: nil)
        let slowScore = scorer.score(call: slowNeedsReview, preferredProvider: nil)

        XCTAssertGreaterThan(fastScore.total, slowScore.total)
    }
}

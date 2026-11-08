import XCTest
@testable import memanager

final class QuickAssistIntentRouterTests: XCTestCase {
    private let router = QuickAssistIntentRouter()
    private let composer = QuickAssistCapabilityComposer()
    private let policyEngine = QuickAssistRoutingPolicyEngine()
    private let answerVerifier = QuickAssistAnswerVerifier()

    func testSystemDesignIntentDetectedFromArchitectureLanguage() {
        let resolved = makeResolved(mode: .conversation)
        let result = router.routeIntent(
            question: "How would you design this architecture for 10M users?",
            transcript: "",
            extraContext: "",
            hasVisualEvidence: false,
            resolvedContext: resolved
        )

        XCTAssertEqual(result.intent, .systemDesign)
        XCTAssertGreaterThan(result.confidence, 0.8)
    }

    func testDebugIntentDetectedFromFailureLanguage() {
        let resolved = makeResolved(mode: .implementationContext)
        let result = router.routeIntent(
            question: "This function is broken and throws an exception. How do I fix it?",
            transcript: "",
            extraContext: "",
            hasVisualEvidence: false,
            resolvedContext: resolved
        )

        XCTAssertEqual(result.intent, .debug)
        XCTAssertGreaterThan(result.confidence, 0.8)
    }

    func testCapabilityComposerDeepensSystemDesign() {
        let resolved = makeResolved(mode: .conversation)
        let intent = QuickAssistIntentResolution(
            intent: .systemDesign,
            confidence: 0.9,
            signals: ["query=system_design_terms"]
        )

        let composition = composer.compose(intentResolution: intent, resolvedContext: resolved)
        XCTAssertEqual(composition.contextModeOverride, .systemDesignContext)
        XCTAssertEqual(composition.modelTierOverride, .deep)
        XCTAssertEqual(composition.outputContractOverride?.responseShape, .architecture)
    }

    func testProjectBriefIntentDetectedFromImplementationPlanningLanguage() {
        let resolved = makeResolved(mode: .implementationContext)
        let result = router.routeIntent(
            question: "Give me an implementation brief with relevant files and tests.",
            transcript: "",
            extraContext: "",
            hasVisualEvidence: false,
            resolvedContext: resolved
        )

        XCTAssertEqual(result.intent, .projectBrief)
        XCTAssertGreaterThan(result.confidence, 0.85)
        XCTAssertTrue(result.signals.contains("query=project_brief_terms"))
    }

    func testCapabilityComposerRequiresProjectBriefEvidenceContract() {
        let resolved = makeResolved(mode: .conversation)
        let intent = QuickAssistIntentResolution(
            intent: .projectBrief,
            confidence: 0.9,
            signals: ["query=project_brief_terms"]
        )

        let composition = composer.compose(intentResolution: intent, resolvedContext: resolved)

        XCTAssertEqual(composition.contextModeOverride, .implementationContext)
        XCTAssertEqual(composition.modelTierOverride, .deep)
        XCTAssertEqual(composition.outputContractOverride?.responseShape, .implementation)
        XCTAssertEqual(
            composition.outputContractOverride?.requiredElements,
            ["relevant_files", "cited_evidence", "proposed_edits", "risks", "tests"]
        )
        XCTAssertTrue(composition.promptAddendum?.contains("read-only implementation brief") == true)
    }

    func testScreenshotOnlyFallbackRoutesToWalkthrough() {
        let resolved = makeResolved(mode: .conversation)
        let result = router.routeIntent(
            question: "",
            transcript: "",
            extraContext: "",
            hasVisualEvidence: true,
            resolvedContext: resolved
        )

        XCTAssertEqual(result.intent, .walkthrough)
        XCTAssertTrue(result.signals.contains("fallback=screenshot_only_no_text"))
        XCTAssertGreaterThan(result.confidence, 0.8)
    }

    func testPolicyEngineHonorsManualOverride() {
        let resolved = makeResolved(mode: .implementationContext)
        let base = QuickAssistIntentResolution(
            intent: .conversation,
            confidence: 0.6,
            signals: ["default=conversation"]
        )

        let decision = policyEngine.evaluate(
            baseIntentResolution: base,
            resolvedContext: resolved,
            recentCalls: [],
            questionSource: .manual,
            isFollowUp: false,
            routeOverrideIntent: .debug
        )

        XCTAssertEqual(decision.intentResolution.intent, .debug)
        XCTAssertEqual(decision.intentResolution.confidence, 1.0, accuracy: 0.0001)
        XCTAssertEqual(decision.routeOverrideIntent, .debug)
    }

    func testPolicyEngineEscalatesTierAfterFailureBurst() {
        let resolved = makeResolved(mode: .conversation)
        let base = QuickAssistIntentResolution(
            intent: .walkthrough,
            confidence: 0.72,
            signals: ["query=walkthrough_terms"]
        )
        let failures = [
            QuickAssistCallRecord(sessionId: "s1", provider: "OpenAI", model: "gpt-5.2", status: "error"),
            QuickAssistCallRecord(sessionId: "s1", provider: "OpenAI", model: "gpt-5.2", status: "error"),
            QuickAssistCallRecord(sessionId: "s1", provider: "OpenAI", model: "gpt-5.2", durationMs: 8000, status: "success")
        ]

        let decision = policyEngine.evaluate(
            baseIntentResolution: base,
            resolvedContext: resolved,
            recentCalls: failures,
            questionSource: .manual,
            isFollowUp: true,
            routeOverrideIntent: nil
        )

        guard case .some(.deep) = decision.modelTierOverride else {
            return XCTFail("Expected deep model tier override after repeated failures")
        }
        XCTAssertTrue(decision.intentResolution.confidence > base.confidence)
        XCTAssertTrue(decision.decisionVector.contains("recent_failures=2"))
    }

    func testAnswerVerifierMarksLowEvidenceClaimsAsNeedsReview() {
        let evidence = QuickAssistEvidencePack(
            contextMode: .conversation,
            modelTier: .fast,
            questionSource: .none,
            transcriptLength: 0,
            questionLength: 0,
            extraContextLength: 0,
            relatedMemoryCount: 0,
            screenshotCount: 0,
            routeConfidence: 0.4,
            routeReason: "default",
            routeOverrideIntent: nil
        )

        let verification = answerVerifier.verify(
            responseText: "This always guarantees O(1) and definitely works for every case.",
            question: "",
            evidencePack: evidence
        )

        XCTAssertEqual(verification.status, .needsReview)
        XCTAssertGreaterThan(verification.unsupportedClaimCount, 0)
        XCTAssertFalse(verification.missingQuestions.isEmpty)
        XCTAssertNotNil(verification.suggestedFollowUp)
    }

    func testAnswerVerifierMarksHighEvidenceGroundedAnswerAsVerified() {
        let evidence = QuickAssistEvidencePack(
            contextMode: .implementationContext,
            modelTier: .deep,
            questionSource: .manual,
            transcriptLength: 240,
            questionLength: 48,
            extraContextLength: 72,
            relatedMemoryCount: 2,
            screenshotCount: 1,
            routeConfidence: 0.92,
            routeReason: "debug",
            routeOverrideIntent: nil
        )

        let verification = answerVerifier.verify(
            responseText: "I would first isolate the null input path, add a guard for empty arrays, and then verify the fix with the failing test and one edge-case test.",
            question: "Why is this function crashing on empty input?",
            evidencePack: evidence
        )

        XCTAssertEqual(verification.status, .verified)
        XCTAssertEqual(verification.unsupportedClaimCount, 0)
        XCTAssertTrue(verification.missingQuestions.isEmpty)
    }

    func testAnswerVerifierMarksNonAnswerAsFailed() {
        let evidence = QuickAssistEvidencePack(
            contextMode: .conversation,
            modelTier: .fast,
            questionSource: .manual,
            transcriptLength: 0,
            questionLength: 32,
            extraContextLength: 0,
            relatedMemoryCount: 0,
            screenshotCount: 0,
            routeConfidence: 0.2,
            routeReason: "fallback",
            routeOverrideIntent: nil
        )

        let verification = answerVerifier.verify(
            responseText: "I don't know.",
            question: "What edge case is missing?",
            evidencePack: evidence
        )

        XCTAssertEqual(verification.status, .failed)
        XCTAssertNotNil(verification.suggestedFollowUp)
    }

    private func makeResolved(mode: QuickAssistContextMode) -> QuickAssistContextResolver.ResolvedContext {
        QuickAssistContextResolver.ResolvedContext(
            contextMode: mode,
            sectionContext: "",
            solveHistorySummary: nil,
            inferredComplexity: .moderate,
            suggestedModelTier: .fast,
            tokenBudget: nil
        )
    }
}

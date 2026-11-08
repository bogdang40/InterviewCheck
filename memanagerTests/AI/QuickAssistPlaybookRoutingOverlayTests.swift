import XCTest
@testable import memanager

final class QuickAssistPlaybookRoutingOverlayTests: XCTestCase {

    private let overlay = QuickAssistPlaybookRoutingOverlay()

    private let baseResolution = QuickAssistIntentResolution(
        intent: .walkthrough,
        confidence: 0.82,
        signals: ["query=walkthrough_terms"]
    )

    private let baseComposition = QuickAssistCapabilityComposition(
        contextModeOverride: nil,
        complexityOverride: .deep,
        modelTierOverride: .deep,
        outputContractOverride: nil,
        promptAddendum: "base guidance",
        intentManifest: "intent=walkthrough"
    )

    private func resolvedContext() -> QuickAssistContextResolver.ResolvedContext {
        QuickAssistContextResolver.ResolvedContext(
            contextMode: .conversation,
            sectionContext: "",
            solveHistorySummary: nil,
            inferredComplexity: .moderate,
            suggestedModelTier: .fast,
            tokenBudget: nil
        )
    }

    private func apply(
        interactionMode: QuickAssistInteractionMode = .technical,
        questionSource: QuickAssistQuestionSource = .manual,
        question: String,
        transcript: String = "",
        preferredIntent: QuickAssistIntent? = nil,
        previousFamilyID: String? = nil
    ) -> QuickAssistPlaybookRoutingDecision {
        overlay.apply(
            baseIntentResolution: baseResolution,
            baseComposition: baseComposition,
            interactionMode: interactionMode,
            questionSource: questionSource,
            question: question,
            transcript: transcript,
            extraContext: "",
            threadModePreferredIntent: preferredIntent,
            previousFamilyID: previousFamilyID,
            resolvedContext: resolvedContext()
        )
    }

    func testAutoThreadResumeQuestionRoutesToSpokenPlaybook() {
        let decision = apply(question: "Walk me through your resume")

        XCTAssertEqual(decision.familyResolution?.playbook.id, "self_intro")
        XCTAssertEqual(decision.promptInteractionMode, .behavioural)
        XCTAssertEqual(decision.intentResolution.intent, .conversation)
        XCTAssertEqual(decision.composition.contextModeOverride, .conversation)
        XCTAssertTrue(decision.composition.answerPlaybookContract?.contains("Present Past Future") ?? false)
    }

    func testTechnicalFamilyKeepsTechnicalPromptMode() {
        let decision = apply(question: "Write a function to merge two sorted lists")

        XCTAssertEqual(decision.familyResolution?.playbook.id, "coding_algorithm")
        XCTAssertEqual(decision.promptInteractionMode, .technical)
        XCTAssertEqual(decision.intentResolution.intent, .walkthrough)
        XCTAssertTrue(decision.composition.answerPlaybookContract?.contains("REACTO") ?? false)
    }

    func testWeakEvidenceKeepsLegacyRouteWithBreadcrumbs() {
        let decision = apply(question: "", transcript: "Speaker 1: we touched on latency budgets\nMe: right")

        XCTAssertEqual(decision.intentResolution.intent, baseResolution.intent)
        XCTAssertEqual(decision.composition.promptAddendum, "base guidance")
        XCTAssertNil(decision.composition.answerPlaybookContract)
        XCTAssertEqual(decision.promptInteractionMode, .technical)
        XCTAssertNotNil(decision.familyResolution)
        XCTAssertTrue(decision.intentResolution.signals.contains(where: { $0.hasPrefix("family=") }))
    }

    func testNoFamilyEvidencePassesThroughUntouched() {
        let decision = apply(question: "Thanks, that sounds good to me")

        XCTAssertNil(decision.familyResolution)
        XCTAssertEqual(decision.intentResolution.signals, baseResolution.signals)
        XCTAssertEqual(decision.composition.promptAddendum, "base guidance")
    }

    func testExplicitPickerMismatchRespectsUserChoice() {
        let decision = apply(
            question: "What are your salary expectations?",
            preferredIntent: .systemDesign
        )

        XCTAssertEqual(decision.intentResolution.intent, baseResolution.intent)
        XCTAssertNil(decision.composition.answerPlaybookContract)
        XCTAssertEqual(decision.familyResolution?.playbook.id, "salary_comp")
    }

    func testExplicitPickerMatchLetsFamilyDrive() {
        let decision = apply(
            question: "Write a function to reverse a string",
            preferredIntent: .walkthrough
        )

        XCTAssertEqual(decision.intentResolution.intent, .walkthrough)
        XCTAssertTrue(decision.composition.answerPlaybookContract?.contains("REACTO") ?? false)
    }

    func testBehaviouralModeAlwaysDrivesWithSpokenFallback() {
        let decision = apply(
            interactionMode: .behavioural,
            question: "Something with no cues at all"
        )

        XCTAssertEqual(decision.familyResolution?.playbook.id, "behavioral_story")
        XCTAssertEqual(decision.promptInteractionMode, .behavioural)
        XCTAssertTrue(decision.composition.answerPlaybookContract?.contains("STAR-L") ?? false)
    }

    func testBehaviouralAutoSideQuestionInheritsProbePlaybook() {
        let decision = apply(
            interactionMode: .behavioural,
            questionSource: .auto,
            question: "Based on my latest transcript, infer the side question",
            previousFamilyID: "behavioral_story"
        )

        XCTAssertEqual(decision.familyResolution?.playbook.id, "follow_up_probe")
        XCTAssertTrue(decision.familyResolution?.isProbe ?? false)
        XCTAssertTrue(decision.composition.answerPlaybookContract?.contains("Stay consistent") ?? false)
    }

    func testProbeInheritsFamilyAcrossTurns() {
        let decision = apply(
            question: "Why did you choose that tradeoff?",
            previousFamilyID: "system_design"
        )

        XCTAssertEqual(decision.familyResolution?.playbook.id, "follow_up_probe")
        XCTAssertEqual(decision.familyResolution?.secondaryFamilyID, "system_design")
        XCTAssertEqual(decision.promptInteractionMode, .behavioural)
    }
}

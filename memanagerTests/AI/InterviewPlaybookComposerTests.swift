import XCTest
@testable import memanager

final class InterviewPlaybookComposerTests: XCTestCase {

    private let composer = InterviewPlaybookComposer()

    private func resolvedContext(
        mode: QuickAssistContextMode = .conversation
    ) -> QuickAssistContextResolver.ResolvedContext {
        QuickAssistContextResolver.ResolvedContext(
            contextMode: mode,
            sectionContext: "",
            solveHistorySummary: nil,
            inferredComplexity: .moderate,
            suggestedModelTier: .fast,
            tokenBudget: nil
        )
    }

    private func resolution(
        familyID: String,
        confidence: Double = 0.84,
        signals: [String] = ["family=test"],
        secondaryFamilyID: String? = nil,
        isProbe: Bool = false
    ) -> InterviewFamilyResolution {
        guard let playbook = InterviewPlaybookCatalog.playbook(id: familyID) else {
            fatalError("Unknown playbook \(familyID)")
        }
        return InterviewFamilyResolution(
            playbook: playbook,
            confidence: confidence,
            signals: signals,
            secondaryFamilyID: secondaryFamilyID,
            isProbe: isProbe
        )
    }

    func testSpokenFamilyComposesConversationalFastLane() {
        let composition = composer.compose(
            resolution: resolution(familyID: "behavioral_story"),
            resolvedContext: resolvedContext(mode: .implementationContext)
        )

        XCTAssertEqual(composition.contextModeOverride, .conversation)
        XCTAssertEqual(composition.complexityOverride, .moderate)
        XCTAssertEqual(composition.modelTierOverride, .fast)
        XCTAssertEqual(composition.outputContractOverride?.responseShape, .conversational)
        XCTAssertEqual(
            composition.outputContractOverride?.requiredElements,
            ["beat_situation", "beat_task", "beat_action", "beat_result", "beat_lesson"]
        )
        XCTAssertNil(composition.promptAddendum)
        XCTAssertTrue(composition.answerPlaybookContract?.contains("STAR-L") ?? false)
        XCTAssertTrue(composition.answerPlaybookContract?.contains(InterviewAnswerPlaybook.sayFirstLabel) ?? false)
    }

    func testSystemDesignFamilyComposesArchitectureLane() {
        let composition = composer.compose(
            resolution: resolution(familyID: "system_design"),
            resolvedContext: resolvedContext()
        )

        XCTAssertEqual(composition.contextModeOverride, .systemDesignContext)
        XCTAssertEqual(composition.complexityOverride, .deep)
        XCTAssertEqual(composition.modelTierOverride, .deep)
        XCTAssertEqual(composition.outputContractOverride?.responseShape, .architecture)
    }

    func testTechnicalNonDesignFamilyKeepsResolvedContext() {
        let composition = composer.compose(
            resolution: resolution(familyID: "coding_algorithm"),
            resolvedContext: resolvedContext(mode: .implementationContext)
        )

        XCTAssertNil(composition.contextModeOverride)
        XCTAssertEqual(composition.outputContractOverride?.responseShape, .implementation)
    }

    func testProbeAddendumAnchorsToInheritedFramework() {
        let composition = composer.compose(
            resolution: resolution(
                familyID: "follow_up_probe",
                secondaryFamilyID: "behavioral_story",
                isProbe: true
            ),
            resolvedContext: resolvedContext()
        )

        XCTAssertTrue(composition.answerPlaybookContract?.contains("STAR-L") ?? false)
        XCTAssertTrue(composition.answerPlaybookContract?.contains("Stay consistent") ?? false)
    }

    func testCompoundAddendumMentionsSecondaryFamily() {
        let composition = composer.compose(
            resolution: resolution(
                familyID: "project_deep_dive",
                secondaryFamilyID: "product_metrics"
            ),
            resolvedContext: resolvedContext()
        )

        XCTAssertTrue(composition.answerPlaybookContract?.contains("Product metrics") ?? false)
        XCTAssertTrue(composition.answerPlaybookContract?.contains("not forgotten") ?? false)
    }

    func testManifestCarriesFamilyAndConfidence() {
        let composition = composer.compose(
            resolution: resolution(familyID: "estimation", confidence: 0.92),
            resolvedContext: resolvedContext()
        )

        XCTAssertTrue(composition.intentManifest.contains("family=estimation"))
        XCTAssertTrue(composition.intentManifest.contains("confidence=0.92"))
        XCTAssertTrue(composition.intentManifest.contains("framework=Structured Estimation"))
    }
}

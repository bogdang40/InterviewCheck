import XCTest
@testable import memanager

final class SettingsManagerQuickAssistPromptResolutionTests: XCTestCase {
    func testIrrelevantLargePromptIsExcluded() {
        let hugePrompt = String(repeating: "Mariana minerals autonomy stack platform notes. ", count: 220)

        let resolved = SettingsManager.resolveQuickAssistPromptText(
            hugePrompt,
            transcript: "Me: implement a sliding window algorithm for this string problem",
            question: "Can you write the function?",
            extraContext: ""
        )

        XCTAssertEqual(resolved.status, .ignoredIrrelevant)
        XCTAssertEqual(resolved.text, "")
        XCTAssertEqual(resolved.appliedLength, 0)
    }

    func testRelevantPromptIsIncluded() {
        let prompt = "Mariana minerals supply chain architecture focus with extraction telemetry and logistics."
        let resolved = SettingsManager.resolveQuickAssistPromptText(
            prompt,
            transcript: "Me: let's reason about minerals extraction telemetry and logistics constraints",
            question: "How should we design Mariana supply chain architecture?",
            extraContext: ""
        )

        XCTAssertEqual(resolved.status, .applied)
        XCTAssertEqual(resolved.text, prompt)
        XCTAssertEqual(resolved.appliedLength, prompt.count)
    }

    func testOversizedRelevantPromptIsIncludedWithoutTruncation() {
        let oversizedPrompt = Array(
            repeating: "telemetry pipeline architecture mariana logistics",
            count: 160
        ).joined(separator: " ")
        let resolved = SettingsManager.resolveQuickAssistPromptText(
            oversizedPrompt,
            transcript: "Me: design telemetry pipeline for mariana logistics architecture",
            question: "",
            extraContext: ""
        )

        XCTAssertEqual(resolved.status, .applied)
        XCTAssertEqual(resolved.appliedLength, oversizedPrompt.count)
        XCTAssertEqual(resolved.text, oversizedPrompt)
        XCTAssertEqual(resolved.originalLength, resolved.appliedLength)
    }
}

final class SettingsManagerOpenAIGuardTests: XCTestCase {
    func testOpenAIGuardToggleOnlyAffectsOpenAIProvider() {
        let settings = SettingsManager.shared
        let originalGuard = settings.openAIVoiceGuardEnabled
        defer { settings.openAIVoiceGuardEnabled = originalGuard }

        settings.openAIVoiceGuardEnabled = false
        XCTAssertFalse(settings.shouldApplyVoiceGuard(for: .openai))
        XCTAssertTrue(settings.shouldApplyVoiceGuard(for: .claude))
        XCTAssertTrue(settings.shouldApplyVoiceGuard(for: .azureOpenAI))

        settings.openAIVoiceGuardEnabled = true
        XCTAssertTrue(settings.shouldApplyVoiceGuard(for: .openai))
    }

    func testOpenAIDisplayModeCanSwitchBetweenResponseAndGuarded() {
        let settings = SettingsManager.shared
        let originalMode = settings.openAIQuickAssistDisplayMode
        defer { settings.openAIQuickAssistDisplayMode = originalMode }

        settings.openAIQuickAssistDisplayMode = .response
        XCTAssertEqual(settings.openAIQuickAssistDisplayMode, .response)

        settings.openAIQuickAssistDisplayMode = .guarded
        XCTAssertEqual(settings.openAIQuickAssistDisplayMode, .guarded)
    }

    func testQuickAssistInteractionModePersistsSelection() {
        let settings = SettingsManager.shared
        let originalMode = settings.quickAssistInteractionMode
        defer { settings.quickAssistInteractionMode = originalMode }

        settings.quickAssistInteractionMode = .behavioural
        XCTAssertEqual(settings.quickAssistInteractionMode, .behavioural)

        settings.quickAssistInteractionMode = .technical
        XCTAssertEqual(settings.quickAssistInteractionMode, .technical)
    }

    func testOpenAIReasoningEffortsPersistAndNormalizeAcrossModelChanges() {
        let settings = SettingsManager.shared
        let originalSolveModel = settings.selectedModel(for: .openai)
        let originalQuickModel = settings.quickAssistModel(for: .openai)
        let originalSolveEffort = settings.openAISolveReasoningEffort(forModel: originalSolveModel)
        let originalQuickEffort = settings.openAIQuickReasoningEffort(forModel: originalQuickModel)
        let startingVersion = settings.providerConfigurationVersion

        defer {
            settings.setSelectedModel(originalSolveModel, for: .openai)
            settings.setQuickAssistModel(originalQuickModel, for: .openai)
            settings.setOpenAISolveReasoningEffort(originalSolveEffort, forModel: originalSolveModel)
            settings.setOpenAIQuickReasoningEffort(originalQuickEffort, forModel: originalQuickModel)
        }

        settings.setSelectedModel("gpt-5.4", for: .openai)
        settings.setQuickAssistModel("gpt-5.2", for: .openai)
        settings.setOpenAISolveReasoningEffort(.xhigh, forModel: "gpt-5.4")
        settings.setOpenAIQuickReasoningEffort(.none, forModel: "gpt-5.2")

        XCTAssertEqual(settings.openAISolveReasoningEffort(forModel: "gpt-5.4"), .xhigh)
        XCTAssertEqual(settings.openAIQuickReasoningEffort(forModel: "gpt-5.2"), .none)
        XCTAssertGreaterThan(settings.providerConfigurationVersion, startingVersion)

        settings.setSelectedModel("gpt-5", for: .openai)
        XCTAssertEqual(settings.openAISolveReasoningEffort(forModel: "gpt-5"), .medium)
    }
}

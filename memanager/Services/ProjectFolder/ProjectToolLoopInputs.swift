import Foundation

/// Translates a `QuickAssistContext` into the flat (system, user text, images) triple that
/// `ProjectToolLoopRunner` needs. Lives here so the runner does not depend on the Quick Assist
/// surface and so Quick Assist does not need to know about tool loop internals.
enum ProjectToolLoopInputs {
    struct Values {
        let systemPrompt: String
        let userPromptText: String
        let imagesBase64: [String]
        let rootDescriptor: ProjectToolRootDescriptor
        let promptContract: ProjectToolPromptContract
    }

    static func derive(from context: QuickAssistContext, rootDescriptor: ProjectToolRootDescriptor) -> Values {
        let language = SettingsManager.shared.preferredLanguage
        let promptContract = ProjectToolPromptContract(rootDescriptor: rootDescriptor)
        let baseSystemPrompt = PromptBuilder.buildQuickAssistSystemPrompt(
            language: language,
            contextMode: context.contextMode,
            interactionMode: context.interactionMode
        )
        let baseUserPromptText = PromptBuilder.buildQuickAssistPrompt(
            transcript: context.transcript,
            question: context.question,
            extraContext: context.extraContext,
            realtimePrompt: context.realtimePrompt,
            hasImages: !context.screenshots.isEmpty,
            interactionMode: context.interactionMode,
            previousResponse: context.previousResponse,
            contextManifest: context.contextEnvelope?.manifest,
            contextMode: context.contextMode,
            outputContract: context.outputContract,
            conversationHistory: context.conversationHistory,
            solveContextSummary: context.solveHistorySummary,
            complexity: context.complexity,
            intent: context.hubIntent,
            routeReason: context.routeReason,
            intentManifest: context.intentManifest,
            routeOverrideIntent: context.routeOverrideIntent,
            evidencePackManifest: context.evidencePackManifest,
            capabilityPromptAddendum: context.capabilityPromptAddendum,
            retrievedMemorySnippets: context.retrievedMemorySnippets
        )
        let systemPrompt = [baseSystemPrompt, promptContract.systemAddendum]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        let userPromptText = [promptContract.userAddendum, baseUserPromptText]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
        return Values(
            systemPrompt: systemPrompt,
            userPromptText: userPromptText,
            imagesBase64: context.screenshots,
            rootDescriptor: rootDescriptor,
            promptContract: promptContract
        )
    }
}

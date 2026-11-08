import Foundation

struct QuickAssistCapabilityComposition {
    let contextModeOverride: QuickAssistContextMode?
    let complexityOverride: QuickAssistComplexity?
    let modelTierOverride: QuickAssistModelTier?
    let outputContractOverride: QuickAssistOutputContract?
    let promptAddendum: String?
    let intentManifest: String
    /// Response format contract from a classified interview playbook.
    /// Rendered as its own labeled prompt block, separate from the softer
    /// capability guidance channel. Nil when no playbook drives the turn.
    var answerPlaybookContract: String? = nil
}

final class QuickAssistCapabilityComposer {
    func compose(
        intentResolution: QuickAssistIntentResolution,
        resolvedContext: QuickAssistContextResolver.ResolvedContext
    ) -> QuickAssistCapabilityComposition {
        let intent = intentResolution.intent
        let summary = "intent=\(intent.rawValue), confidence=\(String(format: "%.2f", intentResolution.confidence)), signals=\(intentResolution.reason)"

        switch intent {
        case .systemDesign:
            return QuickAssistCapabilityComposition(
                contextModeOverride: .systemDesignContext,
                complexityOverride: .deep,
                modelTierOverride: .deep,
                outputContractOverride: QuickAssistOutputContract(
                    detailLevel: .detailed,
                    enforceFirstPerson: true,
                    responseShape: .architecture,
                    requiredElements: ["trade_off", "capacity"]
                ),
                promptAddendum: "Prioritize architecture reasoning, explicit trade-offs, and scaling bottlenecks.",
                intentManifest: summary
            )
        case .debug:
            return QuickAssistCapabilityComposition(
                contextModeOverride: resolvedContext.contextMode == .conversation ? .implementationContext : nil,
                complexityOverride: .deep,
                modelTierOverride: .deep,
                outputContractOverride: QuickAssistOutputContract(
                    detailLevel: .detailed,
                    enforceFirstPerson: true,
                    responseShape: .implementation,
                    requiredElements: ["root_cause", "verification"]
                ),
                promptAddendum: "Call out likely root causes, verification steps, and minimal safe fixes.",
                intentManifest: summary
            )
        case .walkthrough:
            return QuickAssistCapabilityComposition(
                contextModeOverride: nil,
                complexityOverride: .deep,
                modelTierOverride: .deep,
                outputContractOverride: QuickAssistOutputContract(
                    detailLevel: .detailed,
                    enforceFirstPerson: true,
                    responseShape: .structured,
                    requiredElements: ["problem_restatement", "step_by_step", "concrete_solution", "code_if_applicable"]
                ),
                promptAddendum: "Infer the full question from available evidence and provide a concrete solution, not coaching. Use explicit speakable steps and include at least one trade-off when relevant.",
                intentManifest: summary
            )
        case .clarify:
            return QuickAssistCapabilityComposition(
                contextModeOverride: .conversation,
                complexityOverride: .moderate,
                modelTierOverride: .fast,
                outputContractOverride: QuickAssistOutputContract(
                    detailLevel: .concise,
                    enforceFirstPerson: true,
                    responseShape: .conversational,
                    requiredElements: ["clarifying_questions"]
                ),
                promptAddendum: "Lead with the highest-value clarifying question and a concise follow-up answer path.",
                intentManifest: summary
            )
        case .projectBrief:
            return QuickAssistCapabilityComposition(
                contextModeOverride: .implementationContext,
                complexityOverride: .deep,
                modelTierOverride: .deep,
                outputContractOverride: QuickAssistOutputContract(
                    detailLevel: .detailed,
                    enforceFirstPerson: false,
                    responseShape: .implementation,
                    requiredElements: ["relevant_files", "cited_evidence", "proposed_edits", "risks", "tests"]
                ),
                promptAddendum: """
                Project brief mode: produce a read-only implementation brief grounded in project tools.
                Include relevant files with line references, cited evidence snippets, proposed edits, risks, and exact test commands.
                Do not claim that files were changed, do not run code, and do not suggest write or shell tools.
                """,
                intentManifest: summary
            )
        case .conversation:
            return QuickAssistCapabilityComposition(
                contextModeOverride: nil,
                complexityOverride: nil,
                modelTierOverride: nil,
                outputContractOverride: nil,
                promptAddendum: nil,
                intentManifest: summary
            )
        }
    }
}

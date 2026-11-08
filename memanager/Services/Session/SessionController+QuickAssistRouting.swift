import Foundation

struct QuickAssistRequestRoute {
    let effectiveInteractionMode: QuickAssistInteractionMode
    let behaviouralStyleDecision: BehaviouralResponseStyleDecision?
    let routingPolicyDecision: QuickAssistRoutingPolicyDecision?
    let playbookDecision: QuickAssistPlaybookRoutingDecision
    let effectiveMode: QuickAssistContextMode
    let effectiveTier: QuickAssistModelTier
    let effectiveComplexity: QuickAssistComplexity
    let effectiveBudget: Int?
    let resolvedThreadMode: QuickAssistThreadMode
    var intentResolution: QuickAssistIntentResolution { playbookDecision.intentResolution }
    var composition: QuickAssistCapabilityComposition { playbookDecision.composition }
    var promptInteractionMode: QuickAssistInteractionMode { playbookDecision.promptInteractionMode }
}

extension SessionController {
    @MainActor
    func resolveQuickAssistRequestRoute(
        threadID: String,
        effectiveQuestion: String,
        effectiveQuestionSource: QuickAssistQuestionSource,
        selectedThreadMode: QuickAssistThreadMode,
        activeRouteOverrideIntent: QuickAssistIntent?,
        resolved: QuickAssistContextResolver.ResolvedContext,
        hasVisualEvidence: Bool,
        isFollowUp: Bool,
        mode: QuickAssistContextMode,
        forceTier: QuickAssistModelTier?
    ) -> QuickAssistRequestRoute {
        let effectiveInteractionMode = selectedThreadMode.interactionMode
        let behaviouralStyleDecision = effectiveInteractionMode == .behavioural
            ? behaviouralResponseStyleResolver.resolve(
                question: effectiveQuestion,
                transcript: session.transcript,
                questionSource: effectiveQuestionSource
            )
            : nil

        let baseIntentResolution: QuickAssistIntentResolution
        let baseComposition: QuickAssistCapabilityComposition
        let routingPolicyDecision: QuickAssistRoutingPolicyDecision?
        if effectiveInteractionMode == .behavioural {
            let styleDecision = behaviouralStyleDecision ?? .starPlus
            let isStarPlusStyle = styleDecision.style == .starPlus
            let behaviouralRequiredElements: [String] = isStarPlusStyle
                ? ["star_situation", "star_task", "star_action", "star_result", "star_reflection"]
                : []
            let behaviouralPromptAddendum: String = {
                if isStarPlusStyle {
                    return """
                    Behavioural mode: answer in STAR+ format with light labels.
                    Use this order: Situation, Task, Action, Result, Reflection.
                    Keep each section to 1-3 speakable sentences.
                    Reflection must include what I learned and how I'd apply it next time.
                    Keep this conversational and avoid code or Mermaid unless explicitly requested.
                    """
                }
                return """
                Behavioural mode exception (\(styleDecision.exceptionReason?.rawValue ?? "conversational")):
                keep this response conversational without forcing STAR+ section labels.
                Avoid code or Mermaid unless explicitly requested.
                """
            }()
            let behaviouralIntentSignals: [String] = {
                var signals = ["interaction_mode=behavioural", "behavioural_style=\(styleDecision.style.rawValue)"]
                if let reason = styleDecision.exceptionReason?.rawValue {
                    signals.append("behavioural_exception=\(reason)")
                }
                return signals
            }()
            baseIntentResolution = QuickAssistIntentResolution(
                intent: .conversation,
                confidence: 1.0,
                signals: behaviouralIntentSignals
            )
            baseComposition = QuickAssistCapabilityComposition(
                contextModeOverride: nil,
                complexityOverride: .moderate,
                modelTierOverride: .fast,
                outputContractOverride: QuickAssistOutputContract(
                    detailLevel: .concise,
                    enforceFirstPerson: true,
                    responseShape: isStarPlusStyle ? .structured : .conversational,
                    requiredElements: behaviouralRequiredElements
                ),
                promptAddendum: behaviouralPromptAddendum,
                intentManifest: "intent=conversation, confidence=1.00, signals=\(behaviouralIntentSignals.joined(separator: ","))"
            )
            routingPolicyDecision = nil
        } else if settings.hubRouterEnabled {
            let autoIntentResolution = quickAssistIntentRouter.routeIntent(
                question: effectiveQuestion,
                transcript: session.transcript,
                extraContext: quickAssistExtraContext,
                hasVisualEvidence: hasVisualEvidence,
                resolvedContext: resolved
            )
            let seededIntentResolution = seededTechnicalIntentResolution(
                baseIntentResolution: autoIntentResolution,
                selectedMode: selectedThreadMode
            )
            let policyDecision = routingPolicyEngine.evaluate(
                baseIntentResolution: seededIntentResolution,
                resolvedContext: resolved,
                recentCalls: workstreamTimelineRepository.loadQuickAssistCalls(threadId: threadID),
                questionSource: effectiveQuestionSource,
                isFollowUp: isFollowUp,
                routeOverrideIntent: nil
            )
            baseIntentResolution = policyDecision.intentResolution
            baseComposition = quickAssistCapabilityComposer.compose(
                intentResolution: policyDecision.intentResolution,
                resolvedContext: resolved
            )
            routingPolicyDecision = policyDecision
        } else {
            let disabledIntent = activeRouteOverrideIntent ?? .conversation
            let disabledConfidence = activeRouteOverrideIntent == nil ? 0.5 : 1.0
            var disabledSignals = ["router=disabled"]
            if let activeRouteOverrideIntent {
                disabledSignals.append("thread_mode_preference=\(activeRouteOverrideIntent.rawValue)")
            }
            let disabledResolution = QuickAssistIntentResolution(
                intent: disabledIntent,
                confidence: disabledConfidence,
                signals: disabledSignals
            )
            baseIntentResolution = disabledResolution
            baseComposition = quickAssistCapabilityComposer.compose(
                intentResolution: disabledResolution,
                resolvedContext: resolved
            )
            routingPolicyDecision = QuickAssistRoutingPolicyDecision(
                policyVersion: "qa_policy_v2",
                intentResolution: disabledResolution,
                contextModeOverride: nil,
                modelTierOverride: nil,
                routeOverrideIntent: activeRouteOverrideIntent,
                decisionVector: "router=disabled,selected_intent=\(disabledResolution.intent.rawValue),override=\(activeRouteOverrideIntent?.rawValue ?? "none")"
            )
        }

        // Interview playbook overlay: classify the question family and let
        // the matched playbook drive the response contract wherever the
        // evidence is strong. The legacy route above remains the fallback.
        let playbookDecision = playbookRoutingOverlay.apply(
            baseIntentResolution: baseIntentResolution,
            baseComposition: baseComposition,
            interactionMode: effectiveInteractionMode,
            questionSource: effectiveQuestionSource,
            question: effectiveQuestion,
            transcript: session.transcript,
            extraContext: quickAssistExtraContext,
            threadModePreferredIntent: activeRouteOverrideIntent,
            previousFamilyID: quickAssistLastFamilyByThread[threadID],
            resolvedContext: resolved
        )
        let intentResolution = playbookDecision.intentResolution
        let composition = playbookDecision.composition

        // Use explicit mode if user set one (Cmd+Option+1/2), otherwise use resolver
        let effectiveMode: QuickAssistContextMode
        let effectiveTier: QuickAssistModelTier
        let effectiveComplexity: QuickAssistComplexity
        let effectiveBudget: Int?
        if effectiveInteractionMode == .behavioural {
            // The playbook composition may deepen the lane for substantial
            // narrative families (project deep dives, people management).
            effectiveMode = .conversation
            effectiveTier = forceTier ?? composition.modelTierOverride ?? .fast
            effectiveComplexity = composition.complexityOverride ?? .moderate
            effectiveBudget = nil
        } else {
            if mode != .conversation {
                effectiveMode = mode
            } else if let modeOverride = routingPolicyDecision?.contextModeOverride ?? composition.contextModeOverride {
                effectiveMode = modeOverride
            } else {
                effectiveMode = resolved.contextMode
            }

            // Use forceTier if provided (Cmd+Option+/), otherwise use resolver suggestion
            effectiveTier = forceTier
                ?? routingPolicyDecision?.modelTierOverride
                ?? composition.modelTierOverride
                ?? resolved.suggestedModelTier
            effectiveComplexity = composition.complexityOverride ?? resolved.inferredComplexity
            effectiveBudget = resolved.tokenBudget
        }
        quickAssistActiveTier = effectiveTier
        let resolvedThreadMode: QuickAssistThreadMode = {
            if effectiveInteractionMode == .behavioural {
                return .behavioural
            }
            return resolvedTechnicalThreadMode(
                intent: intentResolution.intent,
                contextMode: effectiveMode
            )
        }()
        quickAssistResolvedMode = resolvedThreadMode
        let behaviouralRouteStyleSummary: String = {
            guard let styleDecision = behaviouralStyleDecision else { return "" }
            if let reason = styleDecision.exceptionReason?.rawValue {
                return " | Style: \(styleDecision.style.routeLabel) (\(reason))"
            }
            return " | Style: \(styleDecision.style.routeLabel)"
        }()
        let routingPolicySummary: String = {
            guard effectiveInteractionMode != .behavioural,
                  let decision = routingPolicyDecision else {
                return ""
            }
            let preferenceSummary = activeRouteOverrideIntent.map { " | Preference: \($0.displayName)" } ?? ""
            return " | Policy: \(decision.policyVersion) (\(String(format: "%.2f", decision.intentResolution.confidence)))\(preferenceSummary)"
        }()
        let modeSummary: String = {
            if resolvedThreadMode == selectedThreadMode {
                return "Mode: \(selectedThreadMode.displayName)"
            }
            return "Mode: \(selectedThreadMode.displayName) | Resolved: \(resolvedThreadMode.displayName)"
        }()
        let familyRouteSummary: String = {
            guard let family = playbookDecision.familyResolution else { return "" }
            return " | Family: \(family.playbook.displayName) (\(family.playbook.frameworkName))"
        }()
        quickAssistRouteSummary = "\(modeSummary) | Intent: \(intentResolution.intent.displayName) | Tier: \(effectiveTier == .deep ? "DEEP" : "FAST") | Context: \(effectiveMode.rawValue)\(familyRouteSummary)\(behaviouralRouteStyleSummary)\(routingPolicySummary)"

        return QuickAssistRequestRoute(
            effectiveInteractionMode: effectiveInteractionMode,
            behaviouralStyleDecision: behaviouralStyleDecision,
            routingPolicyDecision: routingPolicyDecision,
            playbookDecision: playbookDecision,
            effectiveMode: effectiveMode,
            effectiveTier: effectiveTier,
            effectiveComplexity: effectiveComplexity,
            effectiveBudget: effectiveBudget,
            resolvedThreadMode: resolvedThreadMode
        )
    }
}

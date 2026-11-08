import Foundation

extension SessionController {
    func setQuickAssistRouteOverride(_ intent: QuickAssistIntent?) {
        setQuickAssistThreadMode(QuickAssistThreadMode(preferredIntent: intent))
    }
    func setQuickAssistThreadMode(_ mode: QuickAssistThreadMode) {
        let previousMode = quickAssistSelectedMode
        guard let threadID = activeQuickAssistThreadID ?? quickAssistCoordinator.activeThreadId else {
            quickAssistSelectedMode = mode
            quickAssistRouteOverrideIntent = mode.preferredIntent
            self.logger.logDebugEvent(
                category: "quick_assist",
                name: "thread_mode_updated",
                details: "thread=none, previous=\(previousMode.rawValue), selected=\(mode.rawValue), resolved=\(quickAssistResolvedMode?.rawValue ?? "none")"
            )
            return
        }
        quickAssistSelectedModeByThread[threadID] = mode
        quickAssistSelectedMode = mode
        quickAssistRouteOverrideIntent = mode.preferredIntent
        if let summaryIndex = quickAssistThreadSummaries.firstIndex(where: { $0.id == threadID }) {
            var summary = quickAssistThreadSummaries[summaryIndex]
            summary = QuickAssistThreadSummary(
                id: summary.id,
                title: summary.title,
                createdAt: summary.createdAt,
                updatedAt: Date(),
                selectedMode: mode,
                originSessionId: summary.originSessionId,
                parentThreadId: summary.parentThreadId,
                branchedFromTurnId: summary.branchedFromTurnId,
                turnCount: summary.turnCount,
                lastTurnAt: summary.lastTurnAt,
                previewText: summary.previewText
            )
            quickAssistThreadSummaries[summaryIndex] = summary
        }
        self.logger.updateQuickAssistThreadSelectedMode(
            threadId: threadID,
            selectedMode: mode
        )
        self.logger.logDebugEvent(
            category: "quick_assist",
            name: "thread_mode_updated",
            details: "thread=\(threadID), previous=\(previousMode.rawValue), selected=\(mode.rawValue), resolved=\(quickAssistResolvedMode?.rawValue ?? "none")"
        )
    }
    func cycleQuickAssistThreadMode() {
        let modes = QuickAssistThreadMode.allCases
        guard !modes.isEmpty else { return }

        let currentMode: QuickAssistThreadMode
        if let threadID = activeQuickAssistThreadID ?? quickAssistCoordinator.activeThreadId {
            currentMode = resolvedQuickAssistSelectedMode(for: threadID)
        } else {
            currentMode = quickAssistSelectedMode
        }

        let currentIndex = modes.firstIndex(of: currentMode) ?? 0
        let nextIndex = (currentIndex + 1) % modes.count
        let nextMode = modes[nextIndex]
        self.logger.logDebugEvent(
            category: "hotkey",
            name: "quick_assist_cycle_mode_applied",
            details: "thread=\((activeQuickAssistThreadID ?? quickAssistCoordinator.activeThreadId) ?? "none"), from=\(currentMode.rawValue), to=\(nextMode.rawValue), quickAssistVisible=\(isQuickAssistViewVisible)"
        )
        setQuickAssistThreadMode(nextMode)
    }
    func resolvedQuickAssistSelectedMode(for threadID: String) -> QuickAssistThreadMode {
        if let stored = quickAssistSelectedModeByThread[threadID] {
            return stored
        }
        if let summary = quickAssistThreadSummaries.first(where: { $0.id == threadID }) {
            quickAssistSelectedModeByThread[threadID] = summary.selectedMode
            return summary.selectedMode
        }
        return .auto
    }
    func resolvedThreadMode(
        for turn: QuickAssistThread.Turn?,
        fallbackIntent: QuickAssistIntent?
    ) -> QuickAssistThreadMode? {
        if let fallbackIntent {
            return QuickAssistThreadMode(preferredIntent: fallbackIntent)
        }

        guard let turn else { return nil }
        if turn.contextMode == .systemDesignContext {
            return .systemDesign
        }
        return .conversation
    }
    func resolvedTechnicalThreadMode(
        intent: QuickAssistIntent,
        contextMode: QuickAssistContextMode
    ) -> QuickAssistThreadMode {
        if contextMode == .systemDesignContext || intent == .systemDesign {
            return .systemDesign
        }
        return QuickAssistThreadMode(preferredIntent: intent)
    }
    func seededTechnicalIntentResolution(
        baseIntentResolution: QuickAssistIntentResolution,
        selectedMode: QuickAssistThreadMode
    ) -> QuickAssistIntentResolution {
        guard let preferredIntent = selectedMode.preferredIntent else {
            return baseIntentResolution
        }

        var signals = baseIntentResolution.signals
        signals.append("thread_mode_preference=\(preferredIntent.rawValue)")

        if baseIntentResolution.intent == preferredIntent {
            return QuickAssistIntentResolution(
                intent: baseIntentResolution.intent,
                confidence: baseIntentResolution.confidence,
                signals: signals
            )
        }

        if preferredIntent == .projectBrief {
            signals.append("thread_mode_seed_applied")
            return QuickAssistIntentResolution(
                intent: preferredIntent,
                confidence: 1.0,
                signals: signals
            )
        }

        if baseIntentResolution.confidence < 0.85 {
            signals.append("thread_mode_seed_applied")
            return QuickAssistIntentResolution(
                intent: preferredIntent,
                confidence: max(baseIntentResolution.confidence, 0.72),
                signals: signals
            )
        }

        signals.append("thread_mode_seed_overruled")
        return QuickAssistIntentResolution(
            intent: baseIntentResolution.intent,
            confidence: baseIntentResolution.confidence,
            signals: signals
        )
    }
}

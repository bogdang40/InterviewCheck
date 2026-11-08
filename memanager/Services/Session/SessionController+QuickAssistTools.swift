import Foundation

extension SessionController {
    @MainActor
    func markQuickAssistFlowEventsChanged() {
        quickAssistFlowRevision &+= 1
    }
    @MainActor
    func appendToolCallEvent(_ event: ProjectToolCallEvent) {
        markQuickAssistFlowEventsChanged()
        if event.phase == .started {
            quickAssistToolCallEvents.append(event)
            return
        }
        if let index = quickAssistToolCallEvents.lastIndex(where: { $0.callID == event.callID && $0.phase == .started }) {
            quickAssistToolCallEvents[index] = event
        } else {
            quickAssistToolCallEvents.append(event)
        }
    }
    @MainActor
    func appendReasoningEvent(_ event: ProjectToolReasoningEvent) {
        markQuickAssistFlowEventsChanged()
        quickAssistReasoningEvents.append(event)
    }
    /// Availability state for the project tool loop on the active Quick Assist thread.
    /// Used by the top chrome pill to show the real bound root or the exact reason tools are disabled.
    var quickAssistToolAvailability: QuickAssistToolAvailability {
        quickAssistToolAvailabilityResolver.resolve(for: session, providerType: settings.selectedProvider)
    }
    var quickAssistLiveToolTrace: QuickAssistToolTrace? {
        refreshQuickAssistFlowCacheIfNeeded()
        return quickAssistFlowCachedToolTrace
    }
    /// Combines the live tool trace with the model's narrated thoughts into a
    /// single ordered timeline. When no reasoning has landed yet the flow
    /// degrades to just the executed tools so the UI still lights up.
    var quickAssistLiveReasoningFlow: QuickAssistReasoningFlow? {
        refreshQuickAssistFlowCacheIfNeeded()
        return quickAssistFlowCachedReasoningFlow
    }
    /// Rebuilds the presented trace and reasoning flow only when an event has
    /// actually landed since the last read; both values are then served from
    /// cache for the (frequent) body passes in between.
    private func refreshQuickAssistFlowCacheIfNeeded() {
        guard quickAssistFlowCachedRevision != quickAssistFlowRevision else { return }
        quickAssistFlowCachedRevision = quickAssistFlowRevision

        let trace = toolTracePresenter.present(events: quickAssistToolCallEvents)
        quickAssistFlowCachedToolTrace = trace.isEmpty ? nil : trace

        guard !trace.isEmpty || !quickAssistReasoningEvents.isEmpty else {
            quickAssistFlowCachedReasoningFlow = nil
            return
        }
        let fragments = quickAssistReasoningEvents.map { event in
            QuickAssistReasoningFlowBuilder.Fragment.thought(
                text: event.text,
                iteration: event.iteration,
                precedesCallID: event.precedesCallID
            )
        } + trace.steps.map { step in
            QuickAssistReasoningFlowBuilder.Fragment.toolCall(
                id: step.id,
                iteration: step.iteration
            )
        }
        let flow = reasoningFlowBuilder.build(
            turnID: nil,
            fragments: fragments,
            traceSteps: trace.steps
        )
        quickAssistFlowCachedReasoningFlow = flow.isEmpty ? nil : flow
    }
}

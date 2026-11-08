import SwiftUI
import WebKit

extension MermaidDiagramView.Coordinator {
    func handleCorruptionEvent(event: MermaidCorruptionEvent, contextID: String?) {
        let decision = recoveryDecisionForMermaidCorruptionEvent(event)
        guard case .immediateRecovery(let forceBootstrapReload) = decision else { return }
        let resolvedContext = contextID ?? activeRenderContextID ?? activeRenderPayload?.contextID ?? lastRequestedPayload?.contextID
        SessionLogger.shared.logMermaidEvent(
            name: "render_corruption_event_detected",
            details: "id=\(diagramId ?? "unknown"), event=\(event.rawValue), eventContext=\(contextID ?? "none"), resolvedContext=\(resolvedContext ?? "none"), forceBootstrap=\(forceBootstrapReload), hasSuccessfulPaint=\(renderState.hasSuccessfulPaint)",
            isError: true
        )

        guard let resolvedContext else {
            SessionLogger.shared.logMermaidEvent(
                name: "render_corruption_recovery_unavailable",
                details: "id=\(diagramId ?? "unknown"), event=\(event.rawValue), reason=missing_context",
                isError: true
            )
            return
        }

        if renderContinuation != nil {
            finishActiveRender(outcome: .failure, suppressAutomaticRetry: true)
        }

        let didDispatch = dispatchRecoveryRender(
            reason: "corruption_\(event.rawValue)",
            forceBootstrapReload: forceBootstrapReload
        )
        guard didDispatch else {
            SessionLogger.shared.logMermaidEvent(
                name: "render_corruption_recovery_unavailable",
                details: "id=\(diagramId ?? "unknown"), event=\(event.rawValue), context=\(resolvedContext), reason=dispatch_unavailable",
                isError: true
            )
            return
        }

        SessionLogger.shared.logMermaidEvent(
            name: "render_corruption_recovery_dispatched",
            details: "id=\(diagramId ?? "unknown"), event=\(event.rawValue), context=\(resolvedContext), forceBootstrap=\(forceBootstrapReload)"
        )
    }

    func shouldScheduleAutomaticRetry(contextID: String) -> Bool {
        guard let payload = lastRequestedPayload,
              payload.contextID == contextID else {
            return false
        }

        let nextAttempt = (retryAttemptsByContextID[contextID] ?? 0) + 1
        guard nextAttempt <= maxAutomaticRetries else { return false }
        retryAttemptsByContextID[contextID] = nextAttempt
        return true
    }

    func scheduleAutomaticRetry(contextID: String) {
        guard let payload = lastRequestedPayload,
              payload.contextID == contextID else { return }
        let attempt = retryAttemptsByContextID[contextID] ?? 0
        let delayMs = attempt <= 1 ? 180 : 420

        scheduledRetryTask?.cancel()
        scheduledRetryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000) }
            catch { return }
            DispatchQueue.main.async {
                guard let self, !self.isCleanedUp else { return }
                guard self.renderContinuation == nil else { return }
                guard self.lastRequestedPayload?.contextID == contextID else { return }
                self.markRenderEnqueued(
                    contextID: contextID,
                    payload: payload,
                    policy: self.lastRequestedPolicy
                )
                self.scheduleRender(
                    payload: payload,
                    diagramID: payload.diagramID,
                    renderContextID: contextID,
                    policy: self.lastRequestedPolicy
                )
                SessionLogger.shared.logMermaidEvent(
                    name: "render_auto_retry_dispatched",
                    details: "id=\(self.diagramId ?? "unknown"), context=\(contextID), attempt=\(attempt), delayMs=\(delayMs)"
                )
            }
        }
    }

    @discardableResult
    func dispatchRecoveryRender(
        reason: String,
        forceBootstrapReload: Bool = false
    ) -> Bool {
        guard !isCleanedUp else { return false }
        guard renderContinuation == nil else { return false }
        guard let payload = lastRequestedPayload else { return false }

        if forceBootstrapReload {
            let knownHeight = self.webView?.contentHeight ?? minHeight
            loadBootstrapDocument(
                minHeight: max(knownHeight, minHeight),
                reason: reason,
                force: true
            )
        }

        markRenderEnqueued(
            contextID: payload.contextID,
            payload: payload,
            policy: lastRequestedPolicy
        )
        scheduleRender(
            payload: payload,
            diagramID: payload.diagramID,
            renderContextID: payload.contextID,
            policy: .immediate
        )
        SessionLogger.shared.logMermaidEvent(
            name: "render_recovery_dispatched",
            details: "id=\(diagramId ?? "unknown"), context=\(payload.contextID), reason=\(reason), mode=urgent_immediate, forceBootstrap=\(forceBootstrapReload)"
        )
        return true
    }

}

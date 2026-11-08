import SwiftUI
import WebKit

extension MermaidDiagramView.Coordinator {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isCleanedUp else { return }
        bootstrapLoadInFlight = false
        SessionLogger.shared.logMermaidEvent(
            name: "didFinishNavigation",
            details: "id=\(diagramId ?? "unknown")"
        )

        scheduleBridgeRecoveryAfterNavigationIfNeeded()
    }

    func scheduleBridgeRecoveryAfterNavigationIfNeeded() {
        guard renderContinuation != nil else { return }
        guard !bridgeReady else { return }

        let context = activeRenderContextID ?? pendingBridgeReadyPayload?.contextID ?? "none"
        bridgeReadyRecoveryTask?.cancel()
        bridgeReadyRecoveryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 220_000_000) }
            catch { return }
            DispatchQueue.main.async {
                guard let self, !self.isCleanedUp else { return }
                guard self.activeRenderContextID == context else { return }
                guard self.renderContinuation != nil else { return }
                guard !self.bridgeReady else { return }

                let activeContext = self.activeRenderContextID ??
                    self.pendingBridgeReadyPayload?.contextID ??
                    "none"
                let attempt = (self.bridgeRecoveryReloadAttemptByContext[activeContext] ?? 0) + 1
                self.bridgeRecoveryReloadAttemptByContext[activeContext] = attempt
                SessionLogger.shared.logMermaidEvent(
                    name: "render_bridge_not_ready_recovery",
                    details: "id=\(self.diagramId ?? "unknown"), context=\(activeContext), attempt=\(attempt)",
                    isError: true
                )

                let knownHeight = self.webView?.contentHeight ?? self.minHeight
                self.loadBootstrapDocument(
                    minHeight: max(knownHeight, self.minHeight),
                    reason: "bridge_ready_missing_after_navigation",
                    force: true
                )

                if attempt >= 2 {
                    self.finishActiveRender(outcome: .failure)
                }
            }
        }

        SessionLogger.shared.logMermaidEvent(
            name: "render_bridge_not_ready_wait",
            details: "id=\(diagramId ?? "unknown"), context=\(context), delayMs=220"
        )
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isCleanedUp else { return }
        SessionLogger.shared.logMermaidEvent(
            name: "web_content_process_terminated",
            details: "id=\(diagramId ?? "unknown"), hasRecoverablePayload=\(lastRequestedPayload != nil)",
            isError: true
        )
        bridgeReady = false
        bootstrapLoadInFlight = false
        handleCorruptionEvent(event: .processTerminated, contextID: activeRenderContextID)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isCleanedUp else {
            SessionLogger.shared.logMermaidEvent(
                name: "didFail_ignored",
                details: "id=\(diagramId ?? "unknown"), cleaned up, error=\(error.localizedDescription)"
            )
            return
        }
        bootstrapLoadInFlight = false
        SessionLogger.shared.logMermaidEvent(
            name: "didFail",
            details: "id=\(diagramId ?? "unknown"), error=\(error.localizedDescription)",
            isError: true
        )
        handleCorruptionEvent(event: .navigationFailed, contextID: activeRenderContextID)
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isCleanedUp else {
            SessionLogger.shared.logMermaidEvent(
                name: "didFailProvisional_ignored",
                details: "id=\(diagramId ?? "unknown"), cleaned up, error=\(error.localizedDescription)"
            )
            return
        }
        bootstrapLoadInFlight = false
        SessionLogger.shared.logMermaidEvent(
            name: "didFailProvisionalNavigation",
            details: "id=\(diagramId ?? "unknown"), error=\(error.localizedDescription)",
            isError: true
        )
        handleCorruptionEvent(event: .provisionalNavigationFailed, contextID: activeRenderContextID)
    }
    
}

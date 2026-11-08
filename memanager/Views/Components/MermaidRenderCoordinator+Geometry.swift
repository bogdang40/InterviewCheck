import SwiftUI
import WebKit

extension MermaidDiagramView.Coordinator {
    enum GeometryRefreshResult: Equatable {
        case keptCurrent
        case restoredLastGood
        case noLastGood
        case bridgeUnavailable
        case failed(String)
    }

    func handleOverlayGeometryChange(_ notification: Notification) {
        guard !isCleanedUp else { return }
        guard isLikelyVisibleForRecovery else { return }

        let reason = notification.userInfo?["reason"] as? String ?? "unknown"
        if renderContinuation != nil {
            pendingGeometryRecoveryReason = reason
            schedulePendingGeometryRecoveryDrain()
            SessionLogger.shared.logMermaidEvent(
                name: "render_overlay_geometry_deferred",
                details: "id=\(diagramId ?? "unknown"), reason=\(reason)"
            )
            return
        }

        processOverlayGeometryRecovery(reason: reason)
    }

    func processOverlayGeometryRecovery(reason: String) {
        let now = Date()
        guard now.timeIntervalSince(lastGeometryRecoveryAt) >= geometryRecoveryCooldown else { return }
        lastGeometryRecoveryAt = now

        let context = activeRenderContextID ?? lastRequestedPayload?.contextID ?? "none"
        let requestID = renderRequestID
        let token = activeRenderToken
        SessionLogger.shared.logMermaidEvent(
            name: "render_overlay_geometry_event",
            details: "id=\(diagramId ?? "unknown"), reason=\(reason), context=\(context)"
        )

        attemptBridgeGeometryRefresh(reason: reason, contextID: context) { [weak self] refreshResult in
            guard let self, !self.isCleanedUp else { return }
            guard self.renderRequestID == requestID, self.activeRenderToken == token,
                  (self.activeRenderContextID ?? self.lastRequestedPayload?.contextID ?? "none") == context else { return }

            switch refreshResult {
            case .keptCurrent, .restoredLastGood:
                SessionLogger.shared.logMermaidEvent(
                    name: "render_overlay_geometry_refresh_applied",
                    details: "id=\(self.diagramId ?? "unknown"), reason=\(reason), context=\(context)"
                )
                return
            case .bridgeUnavailable, .noLastGood, .failed:
                let didDispatch = self.dispatchRecoveryRender(
                    reason: "overlay_geometry_\(reason)",
                    forceBootstrapReload: false
                )
                guard didDispatch else {
                    SessionLogger.shared.logMermaidEvent(
                        name: "render_corruption_recovery_unavailable",
                        details: "id=\(self.diagramId ?? "unknown"), event=overlay_geometry_\(reason), context=\(context), reason=dispatch_unavailable",
                        isError: true
                    )
                    return
                }
            }
        }
    }

    func schedulePendingGeometryRecoveryDrain() {
        guard !pendingGeometryRecoveryDrainScheduled else { return }
        pendingGeometryRecoveryDrainScheduled = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            self.pendingGeometryRecoveryDrainScheduled = false
            guard !self.isCleanedUp else { return }
            guard self.isLikelyVisibleForRecovery else { return }
            guard let reason = self.pendingGeometryRecoveryReason else { return }

            if self.renderContinuation != nil {
                self.schedulePendingGeometryRecoveryDrain()
                return
            }

            self.pendingGeometryRecoveryReason = nil
            self.processOverlayGeometryRecovery(reason: "deferred_\(reason)")
        }
    }

    func attemptBridgeGeometryRefresh(
        reason: String,
        contextID: String,
        completion: @escaping (GeometryRefreshResult) -> Void
    ) {
        guard let webView else {
            completion(.bridgeUnavailable)
            return
        }

        let escapedContext = javaScriptSingleQuoted(contextID)
        let escapedReason = javaScriptSingleQuoted(reason)
        let script = """
        (function() {
            const bridge = window.__memanagerBridge;
            if (!bridge || typeof bridge.recoverFromGeometry !== 'function') {
                return 'bridge_unavailable';
            }
            return bridge.recoverFromGeometry('\(escapedContext)', '\(escapedReason)');
        })();
        """

        webView.evaluateJavaScript(script) { result, error in
            guard error == nil else {
                completion(.failed(error?.localizedDescription ?? "unknown_error"))
                return
            }

            guard let raw = result as? String else {
                completion(.failed("unexpected_result"))
                return
            }

            switch raw {
            case "kept_current":
                completion(.keptCurrent)
            case "restored_last_good":
                completion(.restoredLastGood)
            case "no_last_good":
                completion(.noLastGood)
            case "bridge_unavailable", "missing_active":
                completion(.bridgeUnavailable)
            default:
                completion(.failed("result_\(raw)"))
            }
        }
    }

    func javaScriptSingleQuoted(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: " ")
    }

    var isLikelyVisibleForRecovery: Bool {
        guard let webView else { return false }
        guard webView.window != nil else { return false }
        return !webView.isHiddenOrHasHiddenAncestor
    }

}

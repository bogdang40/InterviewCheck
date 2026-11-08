import SwiftUI
import WebKit

extension MermaidDiagramView.Coordinator {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        receiveScriptMessage(name: message.name, body: message.body)
    }

    func receiveScriptMessage(name: String, body: Any) {
        // Guard against callbacks after cleanup to prevent crashes
        guard !isCleanedUp else {
            SessionLogger.shared.logMermaidEvent(
                name: "message_ignored",
                details: "id=\(diagramId ?? "unknown"), cleaned up, message=\(name)"
            )
            return
        }
        
        if name == "mermaidStatus" {
            guard let payload = body as? [String: Any],
                  let eventName = payload["name"] as? String else {
                SessionLogger.shared.logMermaidEvent(
                    name: "status_invalid_payload",
                    details: "id=\(diagramId ?? "unknown"), body=\(body)",
                    isError: true
                )
                return
            }

            let details = payload["details"] as? String ?? ""
            let contextID = payload["contextID"] as? String
            let isErrorEvent = eventName.contains("error") || eventName.contains("fallback")
            SessionLogger.shared.logMermaidEvent(
                name: eventName,
                details: "id=\(diagramId ?? "unknown"), context=\(contextID ?? "none"), details=\(details)",
                isError: isErrorEvent
            )

            if eventName == "bridge_ready" {
                bridgeReady = true
                bootstrapLoadInFlight = false
                bridgeReadyRecoveryTask?.cancel()
                bridgeReadyRecoveryTask = nil
                if let contextID = activeRenderContextID {
                    bridgeRecoveryReloadAttemptByContext.removeValue(forKey: contextID)
                }
                if let payload = pendingBridgeReadyPayload,
                   payload.contextID == activeRenderContextID {
                    pendingBridgeReadyPayload = nil
                    DispatchQueue.main.async { [weak self] in
                        self?.dispatchRenderPayload(payload, bootstrapReloadAttempt: 0)
                    }
                }
                return
            }

            if let corruptionEvent = MermaidCorruptionEvent.fromStatusEvent(eventName) {
                if contextID == nil || contextID == activeRenderContextID {
                    handleCorruptionEvent(event: corruptionEvent, contextID: contextID)
                }
                return
            }

            guard let contextID, contextID == activeRenderContextID else { return }
            let successEvents: Set<String> = [
                "render_primary_success",
                "render_repair_success",
                "render_kept_last_good"
            ]

            if successEvents.contains(eventName) {
                lastSuccessStatusContextID = contextID
                if lastHeightAckContextID == contextID {
                    let token = activeRenderToken
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.isCleanedUp,
                              self.activeRenderContextID == contextID,
                              self.activeRenderToken == token else { return }
                        self.finishActiveRender(outcome: .success)
                    }
                }
            }
            return
        }

        guard name == "mermaidHeight" else { return }

        let heightValue: CGFloat?
        let contextID: String?

        if let payload = body as? [String: Any] {
            if let number = payload["height"] as? NSNumber {
                heightValue = CGFloat(truncating: number)
            } else if let doubleValue = payload["height"] as? Double {
                heightValue = CGFloat(doubleValue)
            } else if let intValue = payload["height"] as? Int {
                heightValue = CGFloat(intValue)
            } else {
                heightValue = nil
            }
            contextID = payload["contextID"] as? String
        } else if let number = body as? NSNumber {
            heightValue = CGFloat(truncating: number)
            contextID = activeRenderContextID
        } else if let doubleValue = body as? Double {
            heightValue = CGFloat(doubleValue)
            contextID = activeRenderContextID
        } else if let intValue = body as? Int {
            heightValue = CGFloat(intValue)
            contextID = activeRenderContextID
        } else {
            heightValue = nil
            contextID = activeRenderContextID
        }

        guard let heightValue, heightValue.isFinite, heightValue > 0 else {
            SessionLogger.shared.logMermaidEvent(
                name: "message_invalid_height",
                details: "id=\(diagramId ?? "unknown"), body=\(body)",
                isError: true
            )
            return
        }

        guard let contextID, acceptsHeight(for: contextID) else { return }
        let token = activeRenderToken
        let requestID = renderRequestID
        let adjusted = max(heightValue, minHeight)
        SessionLogger.shared.logMermaidEvent(
            name: "height_received",
            details: "id=\(diagramId ?? "unknown"), context=\(contextID), height=\(adjusted)"
        )

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCleanedUp else {
                SessionLogger.shared.logMermaidEvent(
                    name: "height_update_cancelled",
                    details: "id=\(self?.diagramId ?? "unknown"), cleaned up during dispatch"
                )
                return
            }
            guard self.acceptsHeight(for: contextID), self.renderRequestID == requestID,
                  self.activeRenderToken == token else { return }
            self.webView?.contentHeight = adjusted
            // Geometry refreshes resize an already completed diagram without
            // acknowledging or completing another render attempt.
            guard self.activeRenderContextID == contextID else { return }
            self.lastHeightAckContextID = contextID
            if self.lastSuccessStatusContextID == contextID {
                self.finishActiveRender(outcome: .success)
            }
        }
    }

    private func acceptsHeight(for contextID: String) -> Bool {
        if let activeRenderContextID { return activeRenderContextID == contextID }
        return renderContinuation == nil && renderState.pendingRenderContextID == nil
            && !renderState.needsReload
            && renderState.lastSuccessfulRenderContextID == contextID
            && lastRequestedPayload?.contextID == contextID
    }

}

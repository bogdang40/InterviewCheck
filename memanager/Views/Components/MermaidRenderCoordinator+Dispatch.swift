import SwiftUI
import WebKit

extension MermaidDiagramView.Coordinator {
    func scheduleRender(
        payload: MermaidRenderPayload,
        diagramID: String,
        renderContextID: String,
        policy: MermaidRenderPolicy
    ) {
        switch policy {
        case .immediate:
            Task { [weak self] in
                guard let self else { return }
                _ = await self.loadAndAwaitCompletion(
                    payload: payload,
                    token: UUID(),
                    renderContextID: renderContextID
                )
            }
        case .systemDesignAdaptiveSerial(let slotID):
            let requestID = "\(viewInstanceID).\(diagramID).\(UUID().uuidString)"
            Task { [self] in
                let decision = await adaptiveScheduler.enqueue(
                    slotID: slotID,
                    requestID: requestID
                )

                switch decision {
                case .superseded:
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.isCleanedUp else { return }
                        guard self.activeRenderContextID == renderContextID else { return }
                        self.renderState = reduceMermaidRenderLifecycleState(
                            self.renderState,
                            event: .superseded(contextID: renderContextID)
                        )
                        self.activeRenderContextID = nil
                        SessionLogger.shared.logMermaidEvent(
                            name: "render_superseded_pending",
                            details: "id=\(self.diagramId ?? "unknown"), context=\(renderContextID)"
                        )
                    }
                    return
                case .dispatch(let token, _):
                    let started = Date()
                    let outcome = await loadAndAwaitCompletion(
                        payload: payload,
                        token: token,
                        renderContextID: renderContextID
                    )
                    let durationMs = Int(Date().timeIntervalSince(started) * 1000)
                    await adaptiveScheduler.reportCompletion(
                        token: token,
                        durationMs: durationMs,
                        outcome: outcome.schedulerOutcome
                    )
                }
            }
        }
    }

    func loadAndAwaitCompletion(
        payload: MermaidRenderPayload,
        token: UUID,
        renderContextID: String
    ) async -> MermaidRenderOutcome {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                guard !self.isCleanedUp else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                guard self.lastRequestedPayload?.contextID == renderContextID else {
                    continuation.resume(returning: .cancelled)
                    return
                }

                // Cancel any prior wait if a new render token is started for this view.
                if self.renderContinuation != nil {
                    self.finishActiveRender(outcome: .cancelled)
                }

                self.activeRenderToken = token
                self.activeRenderContextID = renderContextID
                self.activeRenderPayload = payload
                self.lastSuccessStatusContextID = nil
                self.lastHeightAckContextID = nil
                self.renderContinuation = continuation

                self.renderTimeoutTask?.cancel()
                self.renderTimeoutTask = Task { [weak self] in
                    guard let self else { return }
                    do { try await Task.sleep(nanoseconds: self.renderTimeoutNanos) }
                    catch { return }
                    DispatchQueue.main.async {
                        self.finishActiveRender(for: token, outcome: .timeout)
                    }
                }

                self.dispatchRenderPayload(payload, bootstrapReloadAttempt: 0)
            }
        }
    }

    func dispatchRenderPayload(
        _ payload: MermaidRenderPayload,
        bootstrapReloadAttempt: Int
    ) {
        guard !isCleanedUp, activeRenderContextID == payload.contextID else { return }
        guard let webView else {
            finishActiveRender(outcome: .failure)
            return
        }

        if !bridgeReady {
            pendingBridgeReadyPayload = payload
            if !bootstrapLoadInFlight {
                loadBootstrapDocument(
                    minHeight: CGFloat(payload.minHeight),
                    reason: "dispatch_wait_bridge",
                    force: false
                )
            }
            SessionLogger.shared.logMermaidEvent(
                name: "render_waiting_for_bridge",
                details: "id=\(diagramId ?? "unknown"), context=\(payload.contextID), bootstrapInFlight=\(bootstrapLoadInFlight)"
            )
            return
        }

        guard let payloadLiteral = payload.javascriptObjectLiteral() else {
            SessionLogger.shared.logMermaidEvent(
                name: "render_payload_encoding_failed",
                details: "id=\(diagramId ?? "unknown"), context=\(payload.contextID)",
                isError: true
            )
            finishActiveRender(outcome: .failure)
            return
        }

        pendingBridgeReadyPayload = nil
        let script = """
        (function() {
            const bridge = window.__memanagerBridge;
            if (!bridge || typeof bridge.render !== 'function') {
                throw new Error('bridge_not_ready');
            }
            bridge.render(\(payloadLiteral));
            return "dispatch_ok";
        })();
        """

        let token = activeRenderToken
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let self, !self.isCleanedUp else { return }
            guard self.activeRenderContextID == payload.contextID,
                  self.activeRenderToken == token else { return }
            guard let error else { return }

            let errorMessage = error.localizedDescription
            switch classifyMermaidRenderEvalFailure(
                message: errorMessage,
                bootstrapReloadAttempt: bootstrapReloadAttempt
            ) {
            case .waitForLifecycleAcks:
                SessionLogger.shared.logMermaidEvent(
                    name: "render_eval_nonfatal",
                    details: "id=\(self.diagramId ?? "unknown"), context=\(payload.contextID), bootstrapAttempt=\(bootstrapReloadAttempt), error=\(errorMessage)"
                )
                return
            case .reloadBootstrapAndRetry:
                SessionLogger.shared.logMermaidEvent(
                    name: "render_eval_reload_requested",
                    details: "id=\(self.diagramId ?? "unknown"), context=\(payload.contextID), bootstrapAttempt=\(bootstrapReloadAttempt), error=\(errorMessage)",
                    isError: true
                )
                self.loadBootstrapDocument(
                    minHeight: CGFloat(payload.minHeight),
                    reason: "render_eval_reload_requested",
                    force: true
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    guard let self, self.activeRenderToken == token else { return }
                    self.dispatchRenderPayload(payload, bootstrapReloadAttempt: bootstrapReloadAttempt + 1)
                }
                return
            case .fail:
                SessionLogger.shared.logMermaidEvent(
                    name: "render_eval_failed",
                    details: "id=\(self.diagramId ?? "unknown"), context=\(payload.contextID), bootstrapAttempt=\(bootstrapReloadAttempt), error=\(errorMessage)",
                    isError: true
                )
                self.handleCorruptionEvent(event: .evalFatal, contextID: payload.contextID)
            }
        }
    }

}

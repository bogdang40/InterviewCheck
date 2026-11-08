import SwiftUI
import WebKit

extension MermaidDiagramView {
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        typealias MermaidRenderPayload = MermaidDiagramView.MermaidRenderPayload
        weak var webView: AutoSizingWebView?
        var diagramId: String?
        var lastLoadedDiagramId: String?
        var renderState = MermaidRenderLifecycleState()
        var lastAttemptStartedAt: Date?
        let viewInstanceID = UUID().uuidString
        let minHeight: CGFloat

        /// Flag to prevent callbacks after view is dismissed
        var isCleanedUp = false
        let adaptiveScheduler = SystemDesignMermaidRenderScheduler.shared
        var bridgeReady = false
        var bootstrapLoadInFlight = false
        var activeRenderPayload: MermaidRenderPayload?
        var lastRequestedPayload: MermaidRenderPayload?
        var lastRequestedPolicy: MermaidRenderPolicy = .immediate
        var lastSuccessStatusContextID: String?
        var lastHeightAckContextID: String?
        var retryAttemptsByContextID: [String: Int] = [:]
        var scheduledRetryTask: Task<Void, Never>?
        let maxAutomaticRetries = 2
        var pendingBridgeReadyPayload: MermaidRenderPayload?
        var bridgeReadyRecoveryTask: Task<Void, Never>?
        var bridgeRecoveryReloadAttemptByContext: [String: Int] = [:]
        var overlayGeometryObserver: NSObjectProtocol?
        var lastGeometryRecoveryAt: Date = .distantPast
        let geometryRecoveryCooldown: TimeInterval = 0.35
        var pendingGeometryRecoveryReason: String?
        var pendingGeometryRecoveryDrainScheduled = false

        var activeRenderToken: UUID?
        // Retained after completion to distinguish callbacks from earlier attempts.
        var renderRequestID = UUID()
        var activeRenderContextID: String?
        var renderContinuation: CheckedContinuation<MermaidRenderOutcome, Never>?
        var renderTimeoutTask: Task<Void, Never>?
        let renderTimeoutNanos: UInt64 = 1_500_000_000

        init(minHeight: CGFloat) {
            self.minHeight = minHeight
            super.init()
            SessionLogger.shared.logMermaidEvent(
                name: "coordinator_init",
                details: "minHeight=\(minHeight)"
            )
            overlayGeometryObserver = NotificationCenter.default.addObserver(
                forName: .overlayGeometryDidChange,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleOverlayGeometryChange(notification)
            }
        }

        func markRenderEnqueued(
            contextID: String,
            payload: MermaidRenderPayload,
            policy: MermaidRenderPolicy
        ) {
            if renderContinuation != nil {
                finishActiveRender(outcome: .cancelled)
            }
            scheduledRetryTask?.cancel()
            scheduledRetryTask = nil
            renderRequestID = UUID()
            renderState = reduceMermaidRenderLifecycleState(
                renderState,
                event: .enqueue(contextID: contextID)
            )
            activeRenderContextID = contextID
            activeRenderPayload = payload
            lastRequestedPayload = payload
            lastRequestedPolicy = policy
            lastSuccessStatusContextID = nil
            lastHeightAckContextID = nil
            lastAttemptStartedAt = Date()
            pendingBridgeReadyPayload = nil
            bridgeReadyRecoveryTask?.cancel()
            bridgeReadyRecoveryTask = nil
        }

        func loadBootstrapDocument(minHeight: CGFloat, reason: String, force: Bool = false) {
            guard let webView else { return }
            if bootstrapLoadInFlight && !force {
                return
            }
            bootstrapLoadInFlight = true
            bridgeReady = false
            let hasLocalScript = Bundle.main.url(forResource: "mermaid.min", withExtension: "js") != nil
            SessionLogger.shared.logMermaidEvent(
                name: "bootstrap_load_start",
                details: "id=\(diagramId ?? "unknown"), reason=\(reason), localScript=\(hasLocalScript)"
            )
            let html = MermaidBootstrapTemplate.mermaidBootstrapHTML(minHeight: minHeight)
            webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
        }

        /// Clean up script message handler to prevent retain cycles and crashes
        func cleanup() {
            guard !isCleanedUp else {
                SessionLogger.shared.logMermaidEvent(
                    name: "cleanup_skipped",
                    details: "id=\(diagramId ?? "unknown"), already cleaned up"
                )
                return
            }
            
            SessionLogger.shared.logMermaidEvent(
                name: "cleanup_start",
                details: "id=\(diagramId ?? "unknown")"
            )

            isCleanedUp = true
            DispatchQueue.main.async { [weak self] in
                self?.finishActiveRender(outcome: .cancelled)
            }
            scheduledRetryTask?.cancel()
            scheduledRetryTask = nil
            bridgeReadyRecoveryTask?.cancel()
            bridgeReadyRecoveryTask = nil
            bridgeRecoveryReloadAttemptByContext.removeAll(keepingCapacity: true)
            pendingBridgeReadyPayload = nil
            pendingGeometryRecoveryReason = nil
            pendingGeometryRecoveryDrainScheduled = false
            if let overlayGeometryObserver {
                NotificationCenter.default.removeObserver(overlayGeometryObserver)
                self.overlayGeometryObserver = nil
            }
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "mermaidHeight")
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "mermaidStatus")

            SessionLogger.shared.logMermaidEvent(
                name: "cleanup_complete",
                details: "id=\(diagramId ?? "unknown")"
            )
        }
        
        deinit {
            SessionLogger.shared.logMermaidEvent(
                name: "coordinator_deinit",
                details: "id=\(diagramId ?? "unknown"), wasCleanedUp=\(isCleanedUp)"
            )
            cleanup()
        }
        
        func finishActiveRender(
            for expectedToken: UUID? = nil,
            outcome: MermaidRenderOutcome,
            suppressAutomaticRetry: Bool = false
        ) {
            if let expectedToken, activeRenderToken != expectedToken { return }

            let contextID = activeRenderContextID
            let hadSuccessfulPaint = renderState.hasSuccessfulPaint
            let elapsedMs: Int? = {
                guard let started = lastAttemptStartedAt else { return nil }
                return Int(Date().timeIntervalSince(started) * 1000)
            }()

            if let contextID {
                let lifecycleOutcome: MermaidRenderLifecycleCompletion
                switch outcome {
                case .success:
                    lifecycleOutcome = .success
                case .failure:
                    lifecycleOutcome = .failure
                case .timeout:
                    lifecycleOutcome = .timeout
                case .cancelled:
                    lifecycleOutcome = .cancelled
                }
                renderState = reduceMermaidRenderLifecycleState(
                    renderState,
                    event: .complete(contextID: contextID, outcome: lifecycleOutcome)
                )
            }

            if outcome == .success, let contextID {
                retryAttemptsByContextID[contextID] = 0
                let durationValue = elapsedMs ?? -1
                SessionLogger.shared.logMermaidEvent(
                    name: "render_commit_success",
                    details: "id=\(diagramId ?? "unknown"), context=\(contextID), durationMs=\(durationValue)"
                )
            }

            if outcome == .timeout {
                if hadSuccessfulPaint {
                    SessionLogger.shared.logMermaidEvent(
                        name: "render_timeout_kept_last_good",
                        details: "id=\(diagramId ?? "unknown"), context=\(contextID ?? "none"), durationMs=\(elapsedMs ?? -1)"
                    )
                } else {
                    SessionLogger.shared.logMermaidEvent(
                        name: "render_timeout_placeholder_retained",
                        details: "id=\(diagramId ?? "unknown"), context=\(contextID ?? "none"), durationMs=\(elapsedMs ?? -1)"
                    )
                }
            } else if outcome == .failure {
                if hadSuccessfulPaint {
                    SessionLogger.shared.logMermaidEvent(
                        name: "render_failure_kept_last_good",
                        details: "id=\(diagramId ?? "unknown"), context=\(contextID ?? "none"), durationMs=\(elapsedMs ?? -1)"
                    )
                } else {
                    SessionLogger.shared.logMermaidEvent(
                        name: "render_failure_placeholder_retained",
                        details: "id=\(diagramId ?? "unknown"), context=\(contextID ?? "none"), durationMs=\(elapsedMs ?? -1)"
                    )
                }
            }

            if !suppressAutomaticRetry,
               let contextID, (outcome == .failure || outcome == .timeout),
               shouldScheduleAutomaticRetry(contextID: contextID) {
                scheduleAutomaticRetry(contextID: contextID)
            }

            activeRenderToken = nil
            activeRenderContextID = nil
            activeRenderPayload = nil
            lastSuccessStatusContextID = nil
            lastHeightAckContextID = nil
            pendingBridgeReadyPayload = nil
            bridgeReadyRecoveryTask?.cancel()
            bridgeReadyRecoveryTask = nil
            if let contextID {
                bridgeRecoveryReloadAttemptByContext.removeValue(forKey: contextID)
            }
            renderTimeoutTask?.cancel()
            renderTimeoutTask = nil
            let continuation = renderContinuation
            renderContinuation = nil
            continuation?.resume(returning: outcome)
        }
    }
}

enum MermaidRenderOutcome {
    case success
    case failure
    case timeout
    case cancelled

    var schedulerOutcome: SystemDesignMermaidRenderScheduler.RenderOutcome {
        switch self {
        case .success: return .success
        case .failure: return .failure
        case .timeout: return .timeout
        case .cancelled: return .cancelled
        }
    }
}

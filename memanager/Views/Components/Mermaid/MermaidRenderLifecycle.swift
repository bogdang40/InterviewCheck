import Foundation

enum MermaidRenderPolicy: Equatable {
    case immediate
    case systemDesignAdaptiveSerial(slotID: String)
}

struct MermaidRenderLifecycleState: Equatable {
    var lastSuccessfulRenderContextID: String?
    var pendingRenderContextID: String?
    var needsReload: Bool = true
    var hasSuccessfulPaint: Bool = false
}

enum MermaidRenderLifecycleCompletion: Equatable {
    case success
    case failure
    case timeout
    case cancelled
}

enum MermaidRenderLifecycleEvent: Equatable {
    case enqueue(contextID: String)
    case superseded(contextID: String)
    case complete(contextID: String, outcome: MermaidRenderLifecycleCompletion)
}

func reduceMermaidRenderLifecycleState(
    _ state: MermaidRenderLifecycleState,
    event: MermaidRenderLifecycleEvent
) -> MermaidRenderLifecycleState {
    var next = state

    switch event {
    case .enqueue(let contextID):
        next.pendingRenderContextID = contextID
        next.needsReload = false
    case .superseded(let contextID):
        if next.pendingRenderContextID == contextID {
            next.pendingRenderContextID = nil
            next.needsReload = true
        }
    case .complete(let contextID, let outcome):
        guard next.pendingRenderContextID == contextID else { return next }
        next.pendingRenderContextID = nil
        switch outcome {
        case .success:
            next.lastSuccessfulRenderContextID = contextID
            next.needsReload = false
            next.hasSuccessfulPaint = true
        case .failure, .timeout, .cancelled:
            next.needsReload = true
        }
    }

    return next
}

enum MermaidRenderEvalDisposition: Equatable {
    case reloadBootstrapAndRetry
    case waitForLifecycleAcks
    case fail
}

enum MermaidCorruptionEvent: String, Equatable {
    case processTerminated = "web_content_process_terminated"
    case navigationFailed = "didFail"
    case provisionalNavigationFailed = "didFailProvisionalNavigation"
    case runtimeMissing = "render_runtime_missing"
    case runtimeError = "render_runtime_error"
    case heightMissingSVG = "render_height_missing_svg"
    case placeholderRetained = "render_placeholder_retained"
    case evalFatal = "render_eval_failed"

    static func fromStatusEvent(_ eventName: String) -> MermaidCorruptionEvent? {
        switch eventName {
        case "render_runtime_missing":
            return .runtimeMissing
        case "render_runtime_error":
            return .runtimeError
        case "render_height_missing_svg":
            return .heightMissingSVG
        case "render_placeholder_retained":
            return .placeholderRetained
        default:
            return nil
        }
    }
}

enum MermaidRecoveryDecision: Equatable {
    case noRecovery
    case immediateRecovery(forceBootstrapReload: Bool)
}

func recoveryDecisionForMermaidCorruptionEvent(
    _ event: MermaidCorruptionEvent
) -> MermaidRecoveryDecision {
    switch event {
    case .processTerminated,
            .navigationFailed,
            .provisionalNavigationFailed,
            .runtimeMissing,
            .evalFatal:
        return .immediateRecovery(forceBootstrapReload: true)
    case .runtimeError,
            .heightMissingSVG,
            .placeholderRetained:
        // Keep the current page alive for transient rendering/paint issues so
        // we can preserve last-good markup instead of blanking on reload.
        return .immediateRecovery(forceBootstrapReload: false)
    }
}

func classifyMermaidRenderEvalFailure(
    message: String,
    bootstrapReloadAttempt: Int
) -> MermaidRenderEvalDisposition {
    let normalized = message.lowercased()

    if normalized.contains("unsupported type") {
        // WKWebView can report this when JS returns a Promise; render can still succeed.
        return .waitForLifecycleAcks
    }

    if normalized.contains("bridge_not_ready") {
        return bootstrapReloadAttempt < 1 ? .reloadBootstrapAndRetry : .fail
    }

    if normalized.contains("javascript exception") ||
        normalized.contains("a javascript exception occurred") {
        return bootstrapReloadAttempt < 1 ? .reloadBootstrapAndRetry : .fail
    }

    return .fail
}

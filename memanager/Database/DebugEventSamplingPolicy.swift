import Foundation

/// Sampling and persistence policy for debug events: errors always persist,
/// noisy mermaid and system design lifecycle events are sampled, and a small
/// always-persist allowlist keeps the diagnostically critical ones.
struct DebugEventPolicyDecision {
    let shouldPersist: Bool
    let shouldConsoleLog: Bool
    let includeMemory: Bool
}

final class DebugEventSamplingPolicy {
    private let debugSamplingQueue = DispatchQueue(label: "com.memanager.SessionLogger.debugSampling")
    private var debugEventCounters: [String: Int] = [:]

    private static let mermaidLifecycleSampleRate = 20
    private static let systemDesignLifecycleSampleRate = 6

    private static let mermaidAlwaysPersistLifecycleEvents: Set<String> = [
        "render_commit_success",
        "render_timeout_kept_last_good",
        "render_failure_kept_last_good",
        "render_timeout_placeholder_retained",
        "render_failure_placeholder_retained",
        "render_auto_retry_dispatched",
        "render_recovery_dispatched",
        "web_content_process_terminated",
        "render_payload_encoding_failed",
        "render_eval_nonfatal",
        "render_eval_reload_requested",
        "render_eval_failed",
        "render_corruption_event_detected",
        "render_corruption_recovery_dispatched",
        "render_corruption_recovery_unavailable"
    ]

    private static let systemDesignAlwaysPersistLifecycleEvents: Set<String> = [
        "runSolveSystemDesign_start",
        "api_call_start_streaming",
        "api_call_complete",
        "streaming_to_final_view_transition_ms",
        "progressive_recovery_outcome",
        "recovery_request_start",
        "recovery_request_complete"
    ]

    private static let systemDesignSampledLifecycleEvents: Set<String> = [
        "sectionCount_updated",
        "updating_ui",
        "ui_updated",
        "partial_commit_applied",
        "partial_commit_skipped_regression",
        "partial_commit_skipped_low_signal"
    ]

    /// Stream diagnostics that matter once per request always persist; any
    /// remaining per event chatter in this category is heavily sampled
    /// (defense in depth: the per token event_seen log itself was removed).
    private static let openAIStreamSampleRate = 50
    private static let openAIStreamAlwaysPersistEvents: Set<String> = [
        "responses_stream_fallback_to_chat",
        "responses_completed_without_visible_text",
        "stream_completed",
        "visible_text_emitted"
    ]


    func decision(
        category: String,
        name: String,
        type: String,
        requestedIncludeMemory: Bool
    ) -> DebugEventPolicyDecision {
        let normalizedType = type.lowercased()
        if normalizedType == "error" {
            return DebugEventPolicyDecision(
                shouldPersist: true,
                shouldConsoleLog: true,
                includeMemory: requestedIncludeMemory
            )
        }

        if category == "mermaid", normalizedType == "lifecycle" {
            if Self.mermaidAlwaysPersistLifecycleEvents.contains(name) {
                return DebugEventPolicyDecision(
                    shouldPersist: true,
                    shouldConsoleLog: false,
                    includeMemory: false
                )
            }
            return DebugEventPolicyDecision(
                shouldPersist: shouldSampleDebugEvent(category: category, name: name, every: Self.mermaidLifecycleSampleRate),
                shouldConsoleLog: false,
                includeMemory: false
            )
        }

        if category == "system_design", normalizedType == "lifecycle" {
            if Self.systemDesignAlwaysPersistLifecycleEvents.contains(name) {
                return DebugEventPolicyDecision(
                    shouldPersist: true,
                    shouldConsoleLog: false,
                    includeMemory: false
                )
            }
            if Self.systemDesignSampledLifecycleEvents.contains(name) {
                return DebugEventPolicyDecision(
                    shouldPersist: shouldSampleDebugEvent(category: category, name: name, every: Self.systemDesignLifecycleSampleRate),
                    shouldConsoleLog: false,
                    includeMemory: false
                )
            }
            return DebugEventPolicyDecision(
                shouldPersist: true,
                shouldConsoleLog: false,
                includeMemory: false
            )
        }

        if category == "openai_stream" {
            if Self.openAIStreamAlwaysPersistEvents.contains(name) {
                return DebugEventPolicyDecision(
                    shouldPersist: true,
                    shouldConsoleLog: false,
                    includeMemory: false
                )
            }
            return DebugEventPolicyDecision(
                shouldPersist: shouldSampleDebugEvent(category: category, name: name, every: Self.openAIStreamSampleRate),
                shouldConsoleLog: false,
                includeMemory: false
            )
        }

        return DebugEventPolicyDecision(
            shouldPersist: true,
            shouldConsoleLog: false,
            includeMemory: requestedIncludeMemory
        )
    }

    private func shouldSampleDebugEvent(category: String, name: String, every: Int) -> Bool {
        guard every > 1 else { return true }
        let key = "\(category)|\(name)"
        var count = 0
        debugSamplingQueue.sync {
            count = (debugEventCounters[key] ?? 0) + 1
            debugEventCounters[key] = count
            if debugEventCounters.count > 4096 {
                debugEventCounters.removeAll(keepingCapacity: true)
            }
        }
        return count % every == 1
    }
}

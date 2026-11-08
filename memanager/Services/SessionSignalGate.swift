import Foundation

/// Decides how a proactive interview signal (nudge, moment, response card)
/// is handled given the hub toggle and the session's busy state. One place
/// for the rule that was previously copy pasted across three Combine sinks.
enum SessionSignalGate {
    enum Disposition: Equatable {
        /// Show the incoming signal.
        case apply
        /// Proactive content is disabled: clear anything showing.
        case clear
        /// The session is busy generating: keep current content, drop the update.
        case hold
    }

    static func disposition(
        proactiveNudgesEnabled: Bool,
        isLoading: Bool,
        isStreaming: Bool,
        isQuickAssistLoading: Bool,
        isMLGuideLoading: Bool
    ) -> Disposition {
        guard proactiveNudgesEnabled else {
            return .clear
        }
        if isLoading || isStreaming || isQuickAssistLoading || isMLGuideLoading {
            return .hold
        }
        return .apply
    }
}

import Foundation

/// Display vocabulary for a single Quick Assist turn in the deep dive card.
extension QuickAssistTurnFeedbackStatus {
    var tone: OverlayTone {
        switch self {
        case .accepted: return .success
        case .rejected: return .critical
        case .none: return .neutral
        }
    }

    var systemImage: String {
        switch self {
        case .accepted: return "hand.thumbsup"
        case .rejected: return "hand.thumbsdown"
        case .none: return "minus.circle"
        }
    }

    var label: String {
        switch self {
        case .accepted: return "Accepted"
        case .rejected: return "Rejected"
        case .none: return "No feedback"
        }
    }
}

enum TurnDeepDiveFormatter {
    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "n/a" }
        return String(format: "%.0f%%", fraction * 100)
    }

    static func latency(_ ms: Int?) -> String {
        guard let ms else { return "n/a" }
        return "\(ms)ms"
    }

    static func claims(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return "\(count) unsupported \(count == 1 ? "claim" : "claims")"
    }
}

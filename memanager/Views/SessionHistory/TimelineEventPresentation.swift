import Foundation

/// Display vocabulary for timeline events: severity maps onto a tone, event
/// types get a short chip title, and timestamps share one clock format.
extension WorkstreamEventSeverity {
    var tone: OverlayTone {
        switch self {
        case .info: return .info
        case .warning: return .warning
        case .critical: return .critical
        }
    }
}

extension WorkstreamEventType {
    var shortTitle: String {
        switch self {
        case .quickAssist: return "Assist"
        case .routingPolicy: return "Route"
        case .transcript: return "Transcript"
        case .screenshot: return "Screen"
        case .memory: return "Memory"
        case .memoryRetrieval: return "Retrieval"
        case .responseCard: return "Card"
        case .experiment: return "Experiment"
        case .debrief: return "Debrief"
        case .debug: return "Debug"
        case .coachFinding: return "Coach"
        }
    }
}

enum TimelineTimeFormatter {
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss"
        return formatter
    }()

    private static let shortClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    private static let clockWithPeriodFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    /// "9:41 to 9:43 AM" for a cluster of events.
    static func range(from first: Date, to last: Date) -> String {
        "\(shortClockFormatter.string(from: first)) to \(clockWithPeriodFormatter.string(from: last))"
    }
}

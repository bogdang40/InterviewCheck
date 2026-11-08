import Foundation

/// Labels for the replay pane: the header summary line, clock stamps, and
/// the evidence tag printed under a practice card.
enum ReplayPresentation {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()

    static func timeLabel(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func summaryLine(for replay: SessionReplay, hasSession: Bool) -> String {
        guard hasSession else { return "No session selected" }
        return [
            count(replay.events.count, "event", "events"),
            count(replay.turns.count, "turn", "turns"),
            count(replay.snapshots.count, "snapshot", "snapshots"),
            count(replay.practiceCards.count, "card", "cards")
        ].joined(separator: ", ")
    }

    static func evidenceLabel(for evidence: PracticeEvidence) -> String {
        switch evidence {
        case .drill(let drillID):
            return "drill \(drillID)"
        case .coachFinding(let findingID):
            return "coach \(findingID)"
        case .pacingStall(let timestamp):
            return "pacing \(timeLabel(timestamp))"
        case .lowConfidenceTranscript(let entryID):
            return "transcript \(entryID)"
        case .manual:
            return "manual"
        }
    }

    static func turnTitle(_ call: QuickAssistCallRecord) -> String {
        let trimmed = (call.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Quick Assist turn" : trimmed
    }

    static func turnMeta(_ turn: SessionReplayTurnEvidence) -> String {
        "\(turn.call.provider) \(turn.call.model), \(turn.call.contextMode.rawValue), \(count(turn.toolCalls.count, "tool call", "tool calls"))"
    }

    private static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }
}

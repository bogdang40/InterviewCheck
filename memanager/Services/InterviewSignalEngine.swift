import Foundation

enum HubNudgeType: String, Codable {
    case clarify
    case tradeoff
    case complexity
    case pushback
    case silence

    var title: String {
        switch self {
        case .clarify:
            return "Clarify Requirements"
        case .tradeoff:
            return "Surface A Trade-off"
        case .complexity:
            return "State Complexity"
        case .pushback:
            return "Handle Pushback"
        case .silence:
            return "Take The Lead"
        }
    }
}

enum ResponseCardType: String, Codable, Equatable, CaseIterable {
    case clarify
    case tradeoff
    case complexity
    case pushback
    case takeLead

    var nudgeType: HubNudgeType {
        switch self {
        case .clarify:
            return .clarify
        case .tradeoff:
            return .tradeoff
        case .complexity:
            return .complexity
        case .pushback:
            return .pushback
        case .takeLead:
            return .silence
        }
    }

    var title: String {
        nudgeType.title
    }
}

enum ResponseCardRecommendedAction: String, Codable, Equatable {
    case askClarifyingQuestion
    case explainTradeoff
    case stateComplexity
    case acknowledgePushback
    case takeLead
    case refineInQuickAssist
}

struct InterviewMoment: Identifiable, Equatable {
    let id: String
    let type: ResponseCardType
    let cueText: String
    let summary: String
    let createdAt: Date
}

struct ResponseCard: Identifiable, Equatable {
    let id: String
    let type: ResponseCardType
    let shortLine: String
    let expandedLine: String
    let teleprompterText: String
    let sourceMomentID: String
    let confidence: Double
    let recommendedAction: ResponseCardRecommendedAction
    let createdAt: Date
}

struct HubNudge: Identifiable, Equatable {
    let id = UUID()
    let type: HubNudgeType
    let title: String
    let message: String
    let createdAt: Date
}

final class InterviewSignalEngine: ObservableObject {
    static let shared = InterviewSignalEngine()

    @Published private(set) var activeNudge: HubNudge?
    @Published private(set) var activeMoment: InterviewMoment?
    @Published private(set) var responseCards: [ResponseCard] = []

    private var processedEntryIDs: Set<UUID> = []
    private var lastEmissionByType: [ResponseCardType: Date] = [:]
    private let cooldown: TimeInterval
    private let responseCardBuilder: InterviewResponseCardBuilding

    init(
        cooldown: TimeInterval = 40,
        responseCardBuilder: InterviewResponseCardBuilding = InterviewResponseCardBuilder()
    ) {
        self.cooldown = cooldown
        self.responseCardBuilder = responseCardBuilder
    }

    func consume(
        entries: [TranscriptEntry],
        captureState: AudioCaptureService.CaptureState,
        enabled: Bool,
        now: Date = Date()
    ) {
        guard enabled else {
            reset()
            return
        }

        guard captureState == .recording || captureState == .starting else {
            return
        }

        for entry in entries where !processedEntryIDs.contains(entry.id) {
            processedEntryIDs.insert(entry.id)
            maybeEmit(for: entry.text, now: now)
        }
    }

    func evaluateSilence(
        now: Date = Date(),
        lastTranscriptAt: Date?,
        captureState: AudioCaptureService.CaptureState,
        enabled: Bool
    ) {
        guard enabled else {
            reset()
            return
        }

        guard captureState == .recording || captureState == .starting else {
            return
        }

        guard let lastTranscriptAt else { return }
        if now.timeIntervalSince(lastTranscriptAt) >= 28 {
            emit(
                type: .takeLead,
                cueText: "Sustained silence from interviewer",
                now: now
            )
        }
    }

    func dismissCurrentNudge() {
        activeNudge = nil
        activeMoment = nil
        responseCards = []
    }

    func reset() {
        activeNudge = nil
        activeMoment = nil
        responseCards = []
        processedEntryIDs.removeAll()
        lastEmissionByType.removeAll()
    }

    private func maybeEmit(for text: String, now: Date) {
        let normalized = text.lowercased()

        if containsAny(normalized, terms: ["time complexity", "space complexity", "big o", "complexity"]) {
            emit(type: .complexity, cueText: text, now: now)
            return
        }

        if containsAny(normalized, terms: ["trade-off", "tradeoff", "consistency", "latency", "throughput", "availability"]) {
            emit(type: .tradeoff, cueText: text, now: now)
            return
        }

        if containsAny(normalized, terms: ["why", "how would you", "what if", "suppose", "edge case"]) {
            emit(type: .clarify, cueText: text, now: now)
            return
        }

        if containsAny(normalized, terms: ["are you sure", "that won't work", "incorrect", "doesn't scale", "not enough"]) {
            emit(type: .pushback, cueText: text, now: now)
        }
    }

    private func emit(type: ResponseCardType, cueText: String, now: Date) {
        if let previous = lastEmissionByType[type], now.timeIntervalSince(previous) < cooldown {
            return
        }

        if activeMoment?.type == type {
            return
        }

        lastEmissionByType[type] = now
        let normalizedCue = cueText.trimmingCharacters(in: .whitespacesAndNewlines)
        let moment = InterviewMoment(
            id: UUID().uuidString,
            type: type,
            cueText: normalizedCue.isEmpty ? type.title : normalizedCue,
            summary: type.title,
            createdAt: now
        )
        let cards = responseCardBuilder.buildCards(for: moment)
        activeMoment = moment
        responseCards = cards
        activeNudge = HubNudge(
            type: type.nudgeType,
            title: cards.first?.shortLine ?? type.title,
            message: cards.first?.expandedLine ?? defaultMessage(for: type),
            createdAt: now
        )
    }

    private func defaultMessage(for type: ResponseCardType) -> String {
        switch type {
        case .clarify:
            return "Ask one clarifying question, then answer with your default assumption."
        case .tradeoff:
            return "Frame the decision with a clear trade-off and why it fits the constraints."
        case .complexity:
            return "State time and space complexity explicitly."
        case .pushback:
            return "Acknowledge the concern, adjust the plan, and explain the trade-off."
        case .takeLead:
            return "Restate your assumptions and propose the next step before the interviewer asks."
        }
    }

    private func containsAny(_ text: String, terms: [String]) -> Bool {
        terms.contains { term in text.contains(term) }
    }
}

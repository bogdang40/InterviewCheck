import Foundation

/// Builds a `[PracticeCard]` from the artefacts of a finished session.
///
/// Heuristic card generation stays local and fast. `PracticeStore` persists
/// the generated cards, and evidence de-duplication keeps debrief regeneration
/// from creating the same drill twice.
final class PracticeDeckBuilder {
    private let store: PracticeStoring
    private let maxCardsPerSession: Int

    init(store: PracticeStoring, maxCardsPerSession: Int = 7) {
        self.store = store
        self.maxCardsPerSession = maxCardsPerSession
    }

    @discardableResult
    func build(
        sessionID: String,
        drills: [SessionDrill],
        transcript: [TranscriptEntry],
        now: Date = Date()
    ) -> [PracticeCard] {
        let events = PracticeEventSelector.selectEvents(
            drills: drills,
            transcript: transcript,
            maxCards: maxCardsPerSession
        )
        let existingEvidence = Set(store.cards.map(\.sourceEvidence))
        let cards = events
            .filter { !existingEvidence.contains($0.evidence) }
            .map { event -> PracticeCard in
                makeCard(sessionID: sessionID, event: event, now: now)
            }
        for card in cards {
            let schedule = PracticeSchedule.initial(
                for: card.id,
                difficulty: card.difficulty,
                now: now
            )
            store.insert(card: card, schedule: schedule)
        }
        return cards
    }

    private func makeCard(
        sessionID: String,
        event: PracticeEventSelector.Event,
        now: Date
    ) -> PracticeCard {
        let prompt = Self.articulationPrompt(for: event.topicTag)
        let idealReasoning = Self.idealReasoningStub(for: event.topicTag, snippet: event.transcriptSnippet)
        return PracticeCard(
            createdAt: now,
            sessionID: sessionID,
            topicTag: event.topicTag,
            prompt: prompt,
            idealReasoning: idealReasoning,
            transcriptSnippet: event.transcriptSnippet,
            candidateAttemptSummary: event.candidateAttempt,
            difficulty: event.difficulty,
            sourceEvidence: event.evidence
        )
    }

    private static func articulationPrompt(for topic: String) -> String {
        switch topic {
        case "clarification":
            return "Re-ask the interviewer one clarifying question that removes ambiguity from this moment."
        case "tradeoff":
            return "State the core trade-off you were weighing here, including why the alternative was rejected."
        case "depth":
            return "Walk through the time and space complexity of the approach you landed on, and name the dominating term."
        case "pacing":
            return "Deliver the answer to this moment in one breath. No filler, no hedging."
        case "recovery":
            return "Finish the thought you started. Begin with the subject and state it as a complete idea."
        default:
            return "Re-articulate your reasoning from this moment clearly, as if the interviewer just asked it again."
        }
    }

    private static func idealReasoningStub(for topic: String, snippet: String) -> String {
        """
        Anchor on the transcript snippet (\"\(snippet)\") and reframe it as a single sentence that states:
        first, the decision; second, the reason behind it; third, the trade-off it implies.
        """
    }
}

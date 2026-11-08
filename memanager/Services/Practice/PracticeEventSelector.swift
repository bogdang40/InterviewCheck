import Foundation

/// Picks the top N "fumble events" from a finished session. Pure function
/// with deterministic scoring so the test suite can pin specific orderings.
///
/// MVP sources: SessionDrill kinds + short transcript spans flagged as
/// low-confidence. Full-scope adds coach findings and Feature 1 pacing
/// stalls once those signals are flowing.
enum PracticeEventSelector {

    struct Event: Equatable {
        let topicTag: String
        let transcriptSnippet: String
        let candidateAttempt: String
        let difficulty: PracticeDifficulty
        let evidence: PracticeEvidence
        let score: Double
    }

    /// Scores and returns up to `maxCards` events. Higher score first.
    static func selectEvents(
        drills: [SessionDrill],
        transcript: [TranscriptEntry],
        maxCards: Int = 10
    ) -> [Event] {
        var events: [Event] = []
        events.append(contentsOf: drills.map(event(from:)))
        events.append(contentsOf: lowConfidenceSpans(transcript: transcript))
        return events
            .sorted { $0.score > $1.score }
            .prefix(maxCards)
            .map { $0 }
    }

    // MARK: - Helpers

    private static func event(from drill: SessionDrill) -> Event {
        let difficulty: PracticeDifficulty
        switch drill.kind {
        case .clarification, .tradeoff: difficulty = .easy
        case .recovery, .pacing: difficulty = .medium
        case .depth: difficulty = .hard
        }
        let score: Double
        switch drill.kind {
        case .depth: score = 1.0
        case .recovery: score = 0.9
        case .tradeoff: score = 0.8
        case .pacing: score = 0.7
        case .clarification: score = 0.6
        }
        return Event(
            topicTag: drill.kind.rawValue,
            transcriptSnippet: drill.transcriptSpan,
            candidateAttempt: drill.prompt,
            difficulty: difficulty,
            evidence: .drill(drillID: drill.id),
            score: score
        )
    }

    /// A simple heuristic: transcript entries that are short and end without
    /// punctuation often reflect a candidate who trailed off mid-thought.
    /// We flag these so the Studio can drill the recovery moment.
    private static func lowConfidenceSpans(transcript: [TranscriptEntry]) -> [Event] {
        let candidateEntries = transcript.filter { $0.speaker.isMe }
        var results: [Event] = []
        for entry in candidateEntries {
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 4, text.count <= 40 else { continue }
            let endsCleanly = text.last.map { ".!?".contains($0) } ?? false
            guard !endsCleanly else { continue }
            results.append(
                Event(
                    topicTag: "recovery",
                    transcriptSnippet: text,
                    candidateAttempt: text,
                    difficulty: .medium,
                    evidence: .lowConfidenceTranscript(entryID: entry.id.uuidString),
                    score: 0.5 + Double(min(text.count, 30)) / 60.0
                )
            )
        }
        return results
    }
}

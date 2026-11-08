import Foundation
@testable import InterviewCheck

/// Builds word streams on the shared clock for detector tests.
enum DetectorFixtures {
    /// Words spoken one after another starting at `start`, each `duration`
    /// long with `gap` between them. A word written as "...N" (for example
    /// "...2.5") inserts a silence of N seconds instead of a word.
    static func words(
        _ text: String,
        side: InterviewSide,
        start: TimeInterval,
        duration: TimeInterval = 0.3,
        gap: TimeInterval = 0.08,
        speaker: Int? = nil
    ) -> [TimedWord] {
        var clock = start
        var result: [TimedWord] = []
        for raw in text.split(separator: " ").map(String.init) {
            if raw.hasPrefix("..."), let pause = Double(raw.dropFirst(3)) {
                clock += pause
                continue
            }
            result.append(TimedWord(
                side: side,
                speakerIndex: side == .candidate ? (speaker ?? 0) : nil,
                text: raw,
                start: clock,
                end: clock + duration,
                confidence: 0.95,
                isFiller: FillerLexicon.isFiller(raw)
            ))
            clock += duration + gap
        }
        return result
    }

    static let question = "How would you design a rate limiter for a public API?"

    /// Starts within a second, thinks aloud, uses fillers, restarts, pauses
    /// to think, and changes pace between quick and slow stretches.
    static func honestAnswer(after questionEnd: TimeInterval) -> [TimedWord] {
        let stretches: [(text: String, duration: TimeInterval, pauseAfter: TimeInterval)] = [
            ("Um so I'd I'd probably start with um a counter per user", 0.22, 1.8),
            ("like how many calls they made in the last minute and uh if they go over we reject it", 0.2, 2.0),
            ("actually wait a fixed window has that burst problem at the edges so maybe um", 0.45, 1.6),
            ("maybe a sliding window instead hmm I'd keep it in Redis", 0.5, 0.2),
            ("because uh we have many servers and they all need to see the same count", 0.18, 1.7),
            ("and then uh return a 429 with a retry header so clients back off", 0.4, 0),
        ]
        var clock = questionEnd + 0.9
        var result: [TimedWord] = []
        for stretch in stretches {
            let words = DetectorFixtures.words(stretch.text, side: .candidate, start: clock,
                                               duration: stretch.duration, gap: 0.05)
            result += words
            clock = (words.last?.end ?? clock) + stretch.pauseAfter + 0.05
        }
        return result
    }

    /// The AI answer the reading candidate follows.
    static let aiAnswer = """
    Great question. I would implement a token bucket algorithm for each API key, stored in Redis so \
    that every gateway node shares the same state. Each bucket refills at a fixed rate and allows short \
    bursts up to its capacity. When a request arrives, the gateway atomically decrements the bucket \
    using a Lua script; if the bucket is empty, we return HTTP 429 Too Many Requests with a Retry-After \
    header. For resilience, if Redis is unavailable we fail open with a conservative local limit, and \
    we expose metrics on rejected requests per key so we can tune limits per customer tier.
    """

    /// Six seconds of silence, a stall, then a smooth, filler-free reading
    /// of `aiAnswer` at an even pace.
    static func readingAnswer(after questionEnd: TimeInterval) -> [TimedWord] {
        let stall = DetectorFixtures.words("That's a great question so", side: .candidate,
                                           start: questionEnd + 2.2, duration: 0.3, gap: 0.1)
        let body = aiAnswer.replacingOccurrences(of: "Great question. ", with: "")
        let read = DetectorFixtures.words(body, side: .candidate, start: questionEnd + 6.4, duration: 0.28, gap: 0.06)
        return stall + read
    }
}

import Foundation

/// How the candidate started answering.
struct TimingResult: Equatable {
    /// Seconds from the end of the question to the candidate's first word.
    let firstWordLatency: TimeInterval?
    /// Seconds from the end of the question to the first word that is not
    /// a filler, a stall phrase, or the question read back.
    let substantiveLatency: TimeInterval?
    /// Words spent stalling before the substantive start.
    let stallWordCount: Int
    /// The stall words themselves, for the evidence line.
    let stallText: String
    /// Index into the answer words of the substantive start.
    let substantiveIndex: Int?
    /// 0 (answered straight away) ... 1 (long silence before real words).
    let score: Double
}

/// The "Cluely pause": a candidate reading from a tool waits in silence, or
/// fills the wait with stalls, until text appears, then starts fluently.
/// This signal measures only the wait; `CheatScorer` combines it with
/// fluency, because a long pause followed by halting speech is ordinary
/// thinking.
enum TimingSignal {
    /// Latency (s) → suspicion. Linear between points.
    static let curve: [(TimeInterval, Double)] = [
        (0, 0), (1.5, 0.05), (3, 0.35), (5, 0.7), (8, 0.9), (20, 0.9), (45, 0.7),
    ]
    /// Scan no further than this many words for the substantive start.
    static let scanLimit = 40

    static func evaluate(answerWords: [TimedWord], questionEnd: TimeInterval, questionText: String) -> TimingResult {
        guard let first = answerWords.first else {
            return TimingResult(firstWordLatency: nil, substantiveLatency: nil, stallWordCount: 0,
                                stallText: "", substantiveIndex: nil, score: 0)
        }
        let normalized = answerWords.map(\.normalized)
        let questionTokens = Set(FillerLexicon.tokens(questionText)).subtracting(FillerLexicon.stopwords)
        let index = substantiveStart(in: normalized, questionTokens: questionTokens)
        let firstLatency = max(0, first.start - questionEnd)

        guard let index else {
            return TimingResult(firstWordLatency: firstLatency, substantiveLatency: nil,
                                stallWordCount: min(normalized.count, scanLimit),
                                stallText: answerWords.prefix(scanLimit).map(\.text).joined(separator: " "),
                                substantiveIndex: nil, score: interpolate(firstLatency))
        }
        let substantive = max(0, answerWords[index].start - questionEnd)
        var score = interpolate(substantive)
        // Talking to fill the wait ("great question, so...") reads as stalling.
        if index >= 3 { score = min(1, score + 0.1) }

        return TimingResult(
            firstWordLatency: firstLatency,
            substantiveLatency: substantive,
            stallWordCount: index,
            stallText: answerWords.prefix(index).map(\.text).joined(separator: " "),
            substantiveIndex: index,
            score: score
        )
    }

    /// First index that is not a filler, stall word, stall phrase or echo of
    /// the question; nil when the scan limit is reached first.
    static func substantiveStart(in words: [String], questionTokens: Set<String>) -> Int? {
        var index = 0
        let limit = min(words.count, scanLimit)
        while index < limit {
            let word = words[index]
            if word.isEmpty || FillerLexicon.fillers.contains(word) {
                index += 1
                continue
            }
            let phrase = FillerLexicon.stallPhraseLength(in: words, at: index)
            if phrase > 0 {
                index += phrase
                continue
            }
            if FillerLexicon.stallWords.contains(word) {
                index += 1
                continue
            }
            let echoable: (String) -> Bool = {
                questionTokens.contains($0) || FillerLexicon.stopwords.contains($0)
                    || FillerLexicon.fillers.contains($0) || $0.isEmpty
            }
            if echoable(word), isEcho(words, at: index, questionTokens: questionTokens) {
                // Skip the whole read-back: question words and the small
                // words between them. The first word is echoable, so this
                // always advances.
                var skipped = 0
                while index < limit, skipped < 12, echoable(words[index]) {
                    index += 1
                    skipped += 1
                }
                continue
            }
            return index
        }
        return nil
    }

    /// Reading the question back: the next eight words hold at least three
    /// content words and at least two thirds of them come from the question.
    /// A normal answer that reuses one or two question words is not an echo.
    private static func isEcho(_ words: [String], at index: Int, questionTokens: Set<String>) -> Bool {
        guard !questionTokens.isEmpty else { return false }
        let content = words[index..<min(words.count, index + 8)]
            .filter { !$0.isEmpty && !FillerLexicon.stopwords.contains($0) }
        guard content.count >= 3 else { return false }
        let echoed = content.filter { questionTokens.contains($0) }.count
        return Double(echoed) / Double(content.count) >= 2.0 / 3.0
    }

    /// A wait that matches how long the fastest AI took to produce its
    /// first sentence (plus a few seconds to start reading) adds a little.
    static func pacedToAI(_ timing: TimingResult, fastestFirstSentence: TimeInterval?) -> TimingResult {
        guard let ai = fastestFirstSentence, let latency = timing.substantiveLatency,
              latency >= 2.5, latency >= ai, latency <= ai + 5 else { return timing }
        return TimingResult(
            firstWordLatency: timing.firstWordLatency, substantiveLatency: timing.substantiveLatency,
            stallWordCount: timing.stallWordCount, stallText: timing.stallText,
            substantiveIndex: timing.substantiveIndex, score: min(1, timing.score + 0.1)
        )
    }

    static func interpolate(_ latency: TimeInterval) -> Double {
        guard let last = curve.last else { return 0 }
        if latency >= last.0 { return last.1 }
        for (lower, upper) in zip(curve, curve.dropFirst()) where latency <= upper.0 {
            let span = upper.0 - lower.0
            let fraction = span > 0 ? (latency - lower.0) / span : 0
            return lower.1 + (upper.1 - lower.1) * fraction
        }
        return last.1
    }
}

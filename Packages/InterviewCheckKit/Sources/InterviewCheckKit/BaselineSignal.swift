import Foundation

/// The parts of an answer's delivery that differ from person to person.
public struct AnswerStyle: Equatable {
    /// Seconds from the question to the first real words.
    public let latency: Double?
    public let wordCount: Int
    /// Fillers and restarts.
    public let hesitations: Int

    public init(latency: Double?, wordCount: Int, hesitations: Int) {
        self.latency = latency
        self.wordCount = wordCount
        self.hesitations = hesitations
    }

    /// Fillers and restarts per 100 words.
    public var hesitationRate: Double { wordCount > 0 ? Double(hesitations) / Double(wordCount) * 100 : 0 }
}

/// Compares one answer with the same candidate's other answers. People
/// differ: one always starts after three seconds, another says "um" every
/// few words. A switch inside one interview, from quick and halting to late
/// and polished, says more than either number alone. Shown as evidence; it
/// does not change the %.
public enum BaselineSignal {
    /// Answers shorter than this say little about someone's style.
    public static let minimumWords = 20
    /// Other answers needed before there is a "usual".
    public static let minimumOthers = 2

    public static func compare(_ answer: AnswerStyle, with others: [AnswerStyle]) -> String? {
        let usable = others.filter { $0.wordCount >= minimumWords }
        guard usable.count >= minimumOthers, answer.wordCount >= minimumWords else { return nil }
        let usualRate = median(usable.map(\.hesitationRate)) ?? 0
        let usualLatency = median(usable.compactMap(\.latency))

        // Far fewer hesitations than usual, from someone who normally has some,
        // in an answer long enough that their usual rate predicts at least three.
        let expected = usualRate * Double(answer.wordCount) / 100
        let cleaner = usualRate >= 3 && expected >= 3 && answer.hesitationRate <= usualRate / 3
        // A much later start than usual.
        var later = false
        if let latency = answer.latency, let usual = usualLatency {
            later = latency >= max(usual * 2.5, usual + 2.5)
        }
        let rate = { (value: Double) -> String in
            let count = Int(value.rounded())
            return "\(count) hesitation\(count == 1 ? "" : "s") per 100 words"
        }
        let usually = { (value: Double) in "usually \(Int(value.rounded()))" }
        if cleaner && later, let latency = answer.latency, let usual = usualLatency {
            return "Unlike their other answers: started after \(ScoreNotes.seconds(latency)) (usually \(ScoreNotes.seconds(usual))), "
                + "\(rate(answer.hesitationRate)) (\(usually(usualRate)))"
        }
        if cleaner {
            return "Smoother than their other answers: \(rate(answer.hesitationRate)) (\(usually(usualRate)))"
        }
        return nil
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

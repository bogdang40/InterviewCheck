import Foundation

/// Where a question and its answer sit on the shared clock.
public struct QuestionWindow: Equatable {
    /// What the interviewer said, joined from the question turn(s).
    public let questionText: String
    public let questionStart: TimeInterval?
    /// The end of the interviewer's last word before the candidate began
    /// answering. Falls back to the keypress time when the mic caught nothing.
    public let questionEnd: TimeInterval
    /// The candidate's words that belong to this answer, in order.
    public let answerWords: [TimedWord]

    public var answerStart: TimeInterval? { answerWords.first?.start }
    public var answerEnd: TimeInterval? { answerWords.last?.end }
}

/// Works out the question and answer around a "Question asked" keypress.
///
/// Words are grouped into turns. The question is the interviewer's speech
/// since the candidate last spoke substantially, ending with the last
/// interviewer turn that began before the keypress, plus any interviewer
/// speech that continues after it before the candidate replies. One or two
/// word replies from the candidate ("okay", "mm-hmm") followed by more
/// interviewer speech are back-channel, not an answer.
public enum QuestionTracker {
    /// The question never reaches further back than this before the keypress.
    public static let maxLookback: TimeInterval = 45
    /// A candidate turn this short, followed by the interviewer, is back-channel.
    public static let backchannelMaxWords = 2
    /// A keypress just before the interviewer's last word still counts it.
    public static let markTolerance: TimeInterval = 0.75

    public struct Turn: Equatable {
        public let side: InterviewSide
        public var words: [TimedWord]
        public var start: TimeInterval { words.first?.start ?? 0 }
        public var end: TimeInterval { words.last?.end ?? 0 }
    }

    /// - Parameters:
    ///   - words: every final word so far, either side.
    ///   - markedAt: host time of the keypress.
    ///   - lowerBound: nothing before this belongs to the question (the
    ///     previous question's keypress, or session start).
    ///   - closedAt: the answer ends here (next keypress or "Answer done").
    ///   - isCandidate: which candidate-side words count (panel calls).
    public static func resolve(
        words: [TimedWord],
        markedAt: TimeInterval,
        lowerBound: TimeInterval?,
        closedAt: TimeInterval?,
        isCandidate: (TimedWord) -> Bool = { $0.side == .candidate }
    ) -> QuestionWindow {
        let floor = max(lowerBound ?? -.infinity, markedAt - maxLookback)
        let relevant = words
            .filter { word in word.start >= floor && (closedAt.map { word.start < $0 } ?? true) }
            .filter { $0.side == .interviewer || isCandidate($0) }
            .sorted { $0.start < $1.start }
        let turns = group(relevant)

        guard let lastAsked = askedTurn(turns, markedAt: markedAt) else {
            // The mic caught no question: time the answer from the keypress.
            let answer = relevant.filter { $0.side == .candidate && $0.start >= markedAt - markTolerance }
            return QuestionWindow(questionText: "", questionStart: nil, questionEnd: markedAt, answerWords: answer)
        }

        // Extend forward over interviewer speech and back-channel replies.
        var endIndex = lastAsked
        var index = lastAsked + 1
        while index < turns.count {
            if turns[index].side == .interviewer {
                endIndex = index
            } else if !isBackchannel(turns, at: index) {
                break
            }
            index += 1
        }

        // Extend backward to where the candidate last spoke substantially.
        var startIndex = lastAsked
        while startIndex > 0 {
            let previous = startIndex - 1
            if turns[previous].side == .interviewer || isBackchannel(turns, at: previous) {
                startIndex = previous
            } else {
                break
            }
        }

        let questionTurns = turns[startIndex...endIndex].filter { $0.side == .interviewer }
        let text = questionTurns.flatMap(\.words).map(\.text).joined(separator: " ")
        let questionEnd = turns[endIndex].end
        let answer = relevant.filter { $0.side == .candidate && $0.start >= questionEnd }

        return QuestionWindow(
            questionText: text,
            questionStart: questionTurns.first?.start,
            questionEnd: questionEnd,
            answerWords: answer
        )
    }

    /// How long after an early keypress the question may still begin.
    public static let earlyMarkWindow: TimeInterval = 20
    /// An interviewer turn this short inside an answer is an interjection
    /// ("Mm-hmm", "Right"), not a question.
    public static let interjectionMaxWords = 3

    /// The interviewer turn the keypress belongs to.
    /// - The usual case: the last interviewer turn before the keypress, not
    ///   yet answered.
    /// - Pressed early (a planned question clicked, then read out): the turn
    ///   before was already answered, and the interviewer speaks right after
    ///   the keypress, before the candidate does.
    /// - Pressed late: the answer is under way; short interjections in it are
    ///   skipped back to the real question.
    static func askedTurn(_ turns: [Turn], markedAt: TimeInterval) -> Int? {
        let substantive = { (turn: Turn) in turn.side == .candidate && turn.words.count > backchannelMaxWords }
        let before = turns.lastIndex { $0.side == .interviewer && $0.start <= markedAt + markTolerance }
        let answeredBeforeMark = before.map { index in
            turns[(index + 1)...].contains { substantive($0) && $0.start < markedAt - markTolerance }
        } ?? true
        if answeredBeforeMark, let after = turns.firstIndex(where: {
            $0.side == .interviewer && $0.start > markedAt - markTolerance && $0.start <= markedAt + earlyMarkWindow
        }), !turns[..<after].contains(where: { substantive($0) && $0.start >= markedAt - markTolerance }) {
            return after
        }
        guard var asked = before else { return nil }
        if answeredBeforeMark {
            while turns[asked].words.count <= interjectionMaxWords, asked > 0, substantive(turns[asked - 1]),
                  let earlier = turns[..<(asked - 1)].lastIndex(where: { $0.side == .interviewer }) {
                asked = earlier
            }
        }
        return asked
    }

    public static func group(_ words: [TimedWord]) -> [Turn] {
        var turns: [Turn] = []
        for word in words {
            if let last = turns.indices.last, turns[last].side == word.side {
                turns[last].words.append(word)
            } else {
                turns.append(Turn(side: word.side, words: [word]))
            }
        }
        return turns
    }

    private static func isBackchannel(_ turns: [Turn], at index: Int) -> Bool {
        let turn = turns[index]
        guard turn.side == .candidate, turn.words.count <= backchannelMaxWords else { return false }
        return index + 1 < turns.count && turns[index + 1].side == .interviewer
    }
}

public extension QuestionWindow {
    /// Rebuilds a saved question's answer from the interview's stored words,
    /// for the timing strip in a report. Times share the stored time base.
    static func stored(questionText: String, questionEnd: TimeInterval, answerStart: TimeInterval?,
                       answerEnd: TimeInterval?, words: [TimedWord]) -> QuestionWindow {
        let tolerance = 0.002
        let from = (answerStart ?? questionEnd) - tolerance
        let until = (answerEnd ?? .infinity) + tolerance
        let answer = words.filter { $0.side == .candidate && $0.start >= from && $0.start <= until }
        return QuestionWindow(questionText: questionText, questionStart: nil, questionEnd: questionEnd,
                              answerWords: answer)
    }
}

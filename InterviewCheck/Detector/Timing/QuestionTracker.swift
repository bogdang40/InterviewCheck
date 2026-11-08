import Foundation

/// Where a question and its answer sit on the shared clock.
struct QuestionWindow: Equatable {
    /// What the interviewer said, joined from the question turn(s).
    let questionText: String
    let questionStart: TimeInterval?
    /// The end of the interviewer's last word before the candidate began
    /// answering. Falls back to the keypress time when the mic caught nothing.
    let questionEnd: TimeInterval
    /// The candidate's words that belong to this answer, in order.
    let answerWords: [TimedWord]

    var answerStart: TimeInterval? { answerWords.first?.start }
    var answerEnd: TimeInterval? { answerWords.last?.end }
}

/// Works out the question and answer around a "Question asked" keypress.
///
/// Words are grouped into turns. The question is the interviewer's speech
/// since the candidate last spoke substantially, ending with the last
/// interviewer turn that began before the keypress, plus any interviewer
/// speech that continues after it before the candidate replies. One or two
/// word replies from the candidate ("okay", "mm-hmm") followed by more
/// interviewer speech are back-channel, not an answer.
enum QuestionTracker {
    /// The question never reaches further back than this before the keypress.
    static let maxLookback: TimeInterval = 45
    /// A candidate turn this short, followed by the interviewer, is back-channel.
    static let backchannelMaxWords = 2
    /// A keypress just before the interviewer's last word still counts it.
    static let markTolerance: TimeInterval = 0.75

    struct Turn: Equatable {
        let side: InterviewSide
        var words: [TimedWord]
        var start: TimeInterval { words.first?.start ?? 0 }
        var end: TimeInterval { words.last?.end ?? 0 }
    }

    /// - Parameters:
    ///   - words: every final word so far, either side.
    ///   - markedAt: host time of the keypress.
    ///   - lowerBound: nothing before this belongs to the question (the
    ///     previous question's keypress, or session start).
    ///   - closedAt: the answer ends here (next keypress or "Answer done").
    ///   - isCandidate: which candidate-side words count (panel calls).
    static func resolve(
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

        guard let lastAsked = turns.lastIndex(where: {
            $0.side == .interviewer && $0.start <= markedAt + markTolerance
        }) else {
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

    static func group(_ words: [TimedWord]) -> [Turn] {
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

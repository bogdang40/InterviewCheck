import Foundation

/// Finds where questions end and answers begin in a recorded interview,
/// where nobody pressed "Question asked".
///
/// An interviewer turn counts as a question when it has at least four
/// spoken words or ends with a question mark, and the candidate then
/// answers with at least twelve words. Short interjections ("mm-hmm",
/// "right") during an answer are neither questions nor breaks.
public enum RecordingQuestionFinder {
    public static let minimumQuestionWords = 4
    public static let minimumAnswerWords = 12

    /// The host times at which each question ends (one per question).
    public static func questionMarks(in words: [TimedWord]) -> [TimeInterval] {
        let turns = QuestionTracker.group(words.sorted { $0.start < $1.start })
        var marks: [TimeInterval] = []
        for (index, turn) in turns.enumerated() where turn.side == .interviewer {
            let spoken = turn.words.filter { !$0.isFiller }.count
            let asks = spoken >= minimumQuestionWords || turn.words.last?.text.hasSuffix("?") == true
            guard asks, index + 1 < turns.count, turns[index + 1].side == .candidate else { continue }
            let answer = answerWordCount(turns, from: index + 1)
            if answer >= minimumAnswerWords { marks.append(turn.end) }
        }
        return marks
    }

    /// Spoken words in the candidate's answer starting at `start`, carrying
    /// on across short interviewer interjections.
    static func answerWordCount(_ turns: [QuestionTracker.Turn], from start: Int) -> Int {
        var count = 0
        var index = start
        while index < turns.count {
            let turn = turns[index]
            let spoken = turn.words.filter { !$0.isFiller }.count
            if turn.side == .candidate {
                count += spoken
            } else if spoken >= minimumQuestionWords || turn.words.last?.text.hasSuffix("?") == true {
                break
            }
            index += 1
        }
        return count
    }
}

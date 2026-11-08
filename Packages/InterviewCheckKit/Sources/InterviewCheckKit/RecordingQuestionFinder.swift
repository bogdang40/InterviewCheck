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
            guard isQuestion(turns, at: index), index + 1 < turns.count, turns[index + 1].side == .candidate else { continue }
            let answer = answerWordCount(turns, from: index + 1)
            if answer >= minimumAnswerWords { marks.append(turn.end) }
        }
        return marks
    }

    static let questionStarts: Set<String> = ["what", "how", "why", "when", "where", "who", "which", "can", "could", "would",
                                              "tell", "walk", "describe", "explain", "do", "did", "have", "are", "is", "talk", "give"]

    /// An interviewer turn that asks something. Right after a substantial
    /// answer, a short remark ("Really?", "Right, that makes sense.") is an
    /// interjection unless it asks a question.
    static func isQuestion(_ turns: [QuestionTracker.Turn], at index: Int) -> Bool {
        let turn = turns[index]
        guard turn.side == .interviewer else { return false }
        let spoken = turn.words.filter { !$0.isFiller }
        let asksOutright = spoken.contains { $0.text.contains("?") }
        let first = spoken.first?.normalized.trimmingCharacters(in: .punctuationCharacters) ?? ""
        let afterAnswer = index > 0 && turns[index - 1].side == .candidate
            && turns[index - 1].words.filter { !$0.isFiller }.count >= 5
        if afterAnswer {
            if spoken.count <= 2 { return false }
            if spoken.count < 8, !asksOutright, !questionStarts.contains(first) { return false }
        }
        return spoken.count >= minimumQuestionWords || asksOutright
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
            } else if isQuestion(turns, at: index) {
                break
            }
            index += 1
        }
        return count
    }
}

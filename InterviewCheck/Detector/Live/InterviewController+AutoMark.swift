import Foundation
import InterviewCheckKit

extension InterviewController {
    /// Beta: when the interviewer asked a question without pressing the key,
    /// mark it at the question's end once the candidate is clearly answering
    /// (the same rule that finds questions in recordings).
    func autoMarkIfMissed() {
        let lastMark = questions.last.map { origin + $0.markedAt } ?? origin
        // Look only past the last mark, plus a little for a question that
        // straddled it.
        let recent = timeline.words.filter { $0.start > lastMark - 1 && timeline.isCandidateOrInterviewer($0) }
        // The first question that ends after the last mark (the marked one
        // itself can show up again at the start).
        guard let questionEnd = RecordingQuestionFinder.questionMarks(in: recent).first(where: { $0 > lastMark + 1 })
        else { return }
        markQuestion(at: questionEnd, automatically: true)
    }
}

extension InterviewTimeline {
    func isCandidateOrInterviewer(_ word: TimedWord) -> Bool {
        word.side == .interviewer || isCandidate(word)
    }
}

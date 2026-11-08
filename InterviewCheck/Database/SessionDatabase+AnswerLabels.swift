import Foundation
import InterviewCheckKit

/// The interviewer's verdict on one answer.
enum AnswerLabel: String, CaseIterable, Identifiable {
    case ownAnswer = "own"
    case aiAssisted = "ai"

    var id: String { rawValue }
    var title: String { self == .ownAnswer ? "Their own answer" : "AI-assisted" }
}

extension SessionDatabase {
    /// Saves or clears (nil) the verdict for a question's answer.
    func saveAnswerLabel(_ label: AnswerLabel?, questionID: String) {
        if let label {
            interviewWrite("saveAnswerLabel",
                           "INSERT OR REPLACE INTO answer_labels (question_id, label, labeled_at) VALUES (?, ?, ?)") {
                $0.bindText(questionID, at: 1)
                $0.bindText(label.rawValue, at: 2)
                $0.bindMillis(Date(), at: 3)
            }
        } else {
            interviewWrite("clearAnswerLabel", "DELETE FROM answer_labels WHERE question_id = ?") {
                $0.bindText(questionID, at: 1)
            }
        }
    }

    func loadAnswerLabels(interviewID: String) -> [String: AnswerLabel] {
        let rows = interviewRead("loadAnswerLabels", """
            SELECT l.question_id, l.label FROM answer_labels l
            JOIN interview_questions q ON q.id = l.question_id WHERE q.interview_id = ?
            """, bind: { $0.bindText(interviewID, at: 1) }) { row in
            (row.columnText(0) ?? "", AnswerLabel(rawValue: row.columnText(1) ?? ""))
        }
        return Dictionary(rows.compactMap { id, label in label.map { (id, $0) } }, uniquingKeysWith: { $1 })
    }

    /// Saves the interviewer's note on an answer; an empty note is removed.
    func saveAnswerNote(_ note: String, questionID: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            interviewWrite("clearAnswerNote", "DELETE FROM answer_notes WHERE question_id = ?") {
                $0.bindText(questionID, at: 1)
            }
        } else {
            interviewWrite("saveAnswerNote",
                           "INSERT OR REPLACE INTO answer_notes (question_id, note, updated_at) VALUES (?, ?, ?)") {
                $0.bindText(questionID, at: 1)
                $0.bindText(trimmed, at: 2)
                $0.bindMillis(Date(), at: 3)
            }
        }
    }

    func loadAnswerNote(questionID: String) -> String {
        interviewRead("loadAnswerNote", "SELECT note FROM answer_notes WHERE question_id = ?",
                      bind: { $0.bindText(questionID, at: 1) }) { $0.columnText(0) ?? "" }.first ?? ""
    }

    func loadAnswerNotes(interviewID: String) -> [String: String] {
        let rows = interviewRead("loadAnswerNotes", """
            SELECT n.question_id, n.note FROM answer_notes n
            JOIN interview_questions q ON q.id = n.question_id WHERE q.interview_id = ?
            """, bind: { $0.bindText(interviewID, at: 1) }) { ($0.columnText(0) ?? "", $0.columnText(1) ?? "") }
        return Dictionary(rows, uniquingKeysWith: { $1 })
    }

    /// Every labeled answer whose score kept its signal values.
    func loadLabeledAnswers() -> [LabeledAnswer] {
        interviewRead("loadLabeledAnswers", """
            SELECT l.label, s.metrics FROM answer_labels l JOIN answer_scores s ON s.question_id = l.question_id
            """) { row -> LabeledAnswer? in
            guard let label = AnswerLabel(rawValue: row.columnText(0) ?? ""),
                  let metrics = Self.decode(AnswerMetrics.self, row.columnText(1)),
                  let components = metrics.components else { return nil }
            return LabeledAnswer(components: components, wasAIAssisted: label == .aiAssisted)
        }.compactMap { $0 }
    }
}

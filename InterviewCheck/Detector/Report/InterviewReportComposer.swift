import Foundation
import InterviewCheckKit

/// Writes an interview report as Markdown.
enum InterviewReportComposer {
    static func markdown(_ report: InterviewReportData) -> String {
        let interview = report.interview
        var lines = ["# Interview report: \(interview.candidateName.isEmpty ? "Candidate" : interview.candidateName)", ""]
        lines.append("- Role: \(interview.roleTitle.isEmpty ? "Not set" : interview.roleTitle)")
        lines.append("- Date: \(dateFormatter.string(from: interview.startedAt))\(duration(interview))")
        lines.append("- Candidate notified: \(interview.consentConfirmedAt.map { "yes, \(timeFormatter.string(from: $0))" } ?? "not recorded")")
        if let overall = interview.overallPercent {
            lines.append("- Overall: **\(overall)%** (\(ScoreBand(percent: overall).title.lowercased())); " +
                         "\(interview.flaggedCount) of \(interview.questionCount) answers at 70% or more")
        }
        lines += ["", "_Scores are signals to follow up on, not proof. A person should review the evidence before any decision._", ""]

        for question in report.questions {
            lines.append("## Q\(question.ordinal). \(question.text.isEmpty ? "(question not captured)" : question.text)")
            lines.append("")
            if let score = report.scores[question.id] {
                lines.append("**\(score.percent)%: \(ScoreBand(percent: score.percent).title)** (\(score.confidence.rawValue) confidence)")
                lines.append("")
                lines += score.reasons.map { "- \($0)" }
                lines += score.counterpoints.map { "- In their favour: \($0)" }
                lines.append(contentsOf: metricsLines(score.metrics))
                if !score.followUps.isEmpty {
                    lines += ["", "Follow-ups to ask:"] + score.followUps.map { "- \($0)" }
                }
            } else {
                lines.append("_Not scored (no answer captured)._")
            }
            if let verdict = report.verdicts[question.id] { lines += ["", "Your verdict: **\(verdict.title)**"] }
            if let note = report.notes[question.id], !note.isEmpty {
                lines += ["", "**Your notes**", ""] + note.components(separatedBy: .newlines).map { "> \($0)" }
            }
            lines += ["", "**Candidate's answer**", "", "> \(question.answerText.isEmpty ? "(nothing captured)" : question.answerText)", ""]
            for answer in report.references[question.id] ?? [] where answer.error == nil && !answer.text.isEmpty {
                lines.append("<details><summary>\(answer.label)\(answer.firstSentenceSeconds.map { ", first line after \(ScoreNotes.seconds($0))" } ?? "")</summary>")
                lines += ["", answer.text, "", "</details>", ""]
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func metricsLines(_ metrics: AnswerMetrics) -> [String] {
        var parts: [String] = []
        if let latency = metrics.substantiveLatency { parts.append("real answer after \(ScoreNotes.seconds(latency))") }
        parts.append("\(metrics.wordCount) words, \(metrics.fillers) fillers, \(metrics.restarts) restarts")
        if let match = metrics.bestMatchLabel, let phrases = metrics.phraseContainment {
            parts.append("closest AI: \(match) (\(Int(phrases * 100))% shared phrases)")
        }
        return ["- Measured: " + parts.joined(separator: "; ")]
    }

    private static func duration(_ interview: InterviewRecord) -> String {
        guard let end = interview.endedAt else { return "" }
        return ", \(max(1, Int(end.timeIntervalSince(interview.startedAt) / 60))) min"
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}

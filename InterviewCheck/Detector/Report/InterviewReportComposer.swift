import Foundation
import InterviewCheckKit

/// Writes an interview report as Markdown or as simple HTML (for PDF).
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
            lines += ["", "**Candidate's answer**", "", "> \(question.answerText.isEmpty ? "(nothing captured)" : question.answerText)", ""]
            for answer in report.references[question.id] ?? [] where answer.error == nil && !answer.text.isEmpty {
                lines.append("<details><summary>\(answer.label)\(answer.firstSentenceSeconds.map { ", first line after \(ScoreNotes.seconds($0))" } ?? "")</summary>")
                lines += ["", answer.text, "", "</details>", ""]
            }
        }
        return lines.joined(separator: "\n")
    }

    static func html(_ report: InterviewReportData) -> String {
        let interview = report.interview
        var body = "<h1>Interview report: \(escape(interview.candidateName.isEmpty ? "Candidate" : interview.candidateName))</h1>"
        body += "<p class=meta>\(escape(interview.roleTitle)) &middot; \(escape(dateFormatter.string(from: interview.startedAt)))"
        body += " &middot; candidate notified: \(interview.consentConfirmedAt == nil ? "not recorded" : "yes")</p>"
        if let overall = interview.overallPercent {
            body += "<p class=overall><b>\(overall)%</b> overall &middot; \(interview.flaggedCount) of \(interview.questionCount) answers flagged</p>"
        }
        body += "<p class=note>Scores are signals to follow up on, not proof.</p>"
        for question in report.questions {
            body += "<h2>Q\(question.ordinal). \(escape(question.text))</h2>"
            if let score = report.scores[question.id] {
                body += "<p class=score><b>\(score.percent)%</b> \(escape(ScoreBand(percent: score.percent).title)) (\(score.confidence.rawValue) confidence)</p><ul>"
                body += (score.reasons + score.counterpoints.map { "In their favour: \($0)" }).map { "<li>\(escape($0))</li>" }.joined()
                body += "</ul>"
                if !score.followUps.isEmpty {
                    body += "<p><i>Ask next:</i></p><ul>" + score.followUps.map { "<li>\(escape($0))</li>" }.joined() + "</ul>"
                }
            }
            body += "<blockquote>\(escape(question.answerText))</blockquote>"
            for answer in report.references[question.id] ?? [] where answer.error == nil && !answer.text.isEmpty {
                body += "<h3>\(escape(answer.label))</h3><p class=ref>\(escape(answer.text).replacingOccurrences(of: "\n", with: "<br>"))</p>"
            }
        }
        return """
        <html><head><meta charset="utf-8"><style>
        body{font:12px -apple-system,Helvetica,sans-serif;color:#203225;margin:36px;line-height:1.45}
        h1{font-size:20px;margin:0 0 4px}h2{font-size:15px;margin:22px 0 6px;border-top:1px solid #cdd8cb;padding-top:12px}
        h3{font-size:12px;margin:10px 0 2px;color:#2B653F}.meta,.note{color:#506050}.overall{font-size:14px}
        .score b{font-size:15px}blockquote{margin:8px 0;padding:8px 12px;background:#F2EFE3;border-left:3px solid #2B653F}
        .ref{color:#3E5443;font-size:11px}
        </style></head><body>\(body)</body></html>
        """
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

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
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

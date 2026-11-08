import Foundation
import InterviewCheckKit

/// Every answer from many interviews as one spreadsheet (RFC 4180 CSV).
enum InterviewCSV {
    static let header = [
        "Date", "Candidate", "Role", "Question", "Question text", "Score %", "Confidence", "Reading",
        "Real answer after (s)", "Words", "Fillers", "Closest AI answer", "Your verdict", "Your notes", "Top reason",
    ]

    static func make(_ reports: [InterviewReportData]) -> String {
        var rows = [header.map(text)]
        for report in reports {
            let interview = report.interview
            for question in report.questions {
                let score = report.scores[question.id]
                let metrics = score?.metrics
                rows.append([
                    text(dateFormatter.string(from: interview.startedAt)),
                    text(interview.candidateName),
                    text(interview.roleTitle),
                    "\(question.ordinal)",
                    text(question.text),
                    score.map { "\($0.percent)" } ?? "",
                    text(score?.confidence.rawValue ?? ""),
                    text(score.map { ScoreBand(percent: $0.percent).title } ?? "Not scored"),
                    metrics?.substantiveLatency.map { String(format: "%.1f", $0) } ?? "",
                    metrics.map { "\($0.wordCount)" } ?? "",
                    metrics.map { "\($0.fillers)" } ?? "",
                    text(metrics?.bestMatchLabel ?? ""),
                    text(report.verdicts[question.id]?.title ?? ""),
                    text(report.notes[question.id] ?? ""),
                    text(score?.reasons.first ?? ""),
                ])
            }
        }
        return rows.map { $0.joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// Quotes a text cell. Cells that a spreadsheet would run as a formula
    /// (=, +, -, @) get a leading apostrophe so they stay plain text.
    static func text(_ value: String) -> String {
        var cell = value
        if let first = cell.first, "=+-@\t\r".contains(first) { cell = "'" + cell }
        guard cell.contains(where: { ",\"\n\r".contains($0) }) || cell != value else { return cell }
        return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

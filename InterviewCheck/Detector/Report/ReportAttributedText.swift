import AppKit
import InterviewCheckKit

/// The report as formatted text for printing and PDF, built directly (no
/// HTML conversion helper involved).
enum ReportAttributedText {
    private static let ink = NSColor(srgbRed: 0.13, green: 0.20, blue: 0.15, alpha: 1)
    private static let muted = NSColor(srgbRed: 0.31, green: 0.38, blue: 0.31, alpha: 1)
    private static let accent = NSColor(srgbRed: 0.17, green: 0.40, blue: 0.25, alpha: 1)
    private static let answerFill = NSColor(srgbRed: 0.95, green: 0.94, blue: 0.89, alpha: 1)

    static func make(_ report: InterviewReportData) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let interview = report.interview
        text.append(line("Interview report: \(interview.candidateName.isEmpty ? "Candidate" : interview.candidateName)",
                         font: .systemFont(ofSize: 20, weight: .bold), after: 4))
        let meta = [interview.roleTitle, InterviewReportComposer.dateFormatter.string(from: interview.startedAt),
                    "candidate notified: \(interview.consentConfirmedAt == nil ? "not recorded" : "yes")"]
            .filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        text.append(line(meta, font: .systemFont(ofSize: 11), color: muted, after: 8))
        if let overall = interview.overallPercent {
            text.append(line("\(overall)% overall \u{00B7} \(interview.flaggedCount) of \(interview.questionCount) answers flagged",
                             font: .systemFont(ofSize: 14, weight: .semibold), after: 4))
        }
        if interview.scoredFrom == .transcript {
            text.append(line(ScoredFrom.transcriptCaveat, font: .systemFont(ofSize: 11), color: muted, after: 4))
        }
        if interview.wasInterrupted {
            text.append(line("The app closed before this interview was ended; the last answer may be cut short.",
                             font: .systemFont(ofSize: 11), color: muted, after: 4))
        }
        text.append(line("Scores are signals to follow up on, not proof.", font: .systemFont(ofSize: 11), color: muted, after: 14))

        for question in report.questions {
            text.append(line("Q\(question.ordinal). \(question.text.isEmpty ? "(question not captured)" : question.text)",
                             font: .systemFont(ofSize: 14, weight: .semibold), before: 10, after: 6))
            if let score = report.scores[question.id] {
                text.append(line("\(score.percent)% \u{00B7} \(ScoreBand(percent: score.percent).title) (\(score.confidence.rawValue) confidence)",
                                 font: .systemFont(ofSize: 12, weight: .semibold), color: accent, after: 4))
                for reason in score.reasons { text.append(bullet(reason)) }
                for point in score.counterpoints { text.append(bullet("In their favour: \(point)")) }
                if !score.followUps.isEmpty {
                    text.append(line("Ask next:", font: .systemFont(ofSize: 11, weight: .semibold), before: 4, after: 2))
                    for followUp in score.followUps { text.append(bullet(followUp)) }
                }
            }
            if let verdict = report.verdicts[question.id] {
                text.append(line("Your verdict: \(verdict.title)", font: .systemFont(ofSize: 11, weight: .semibold),
                                 before: 4, after: 2))
            }
            if let note = report.notes[question.id], !note.isEmpty {
                text.append(line("Your notes", font: .systemFont(ofSize: 10, weight: .semibold), color: muted,
                                 before: 4, after: 2))
                text.append(line(note, font: .systemFont(ofSize: 11), indent: 8, after: 4))
            }
            let references = (report.references[question.id] ?? []).filter { $0.error == nil && !$0.text.isEmpty }
            let shared = SharedWords.anyReference(answer: question.answerText, references: references.map(\.text),
                                                  question: question.text)
            text.append(line("Candidate's answer", font: .systemFont(ofSize: 10, weight: .semibold), color: muted,
                             before: 6, after: 2))
            text.append(highlighted(line(question.answerText.isEmpty ? "(nothing captured)" : question.answerText,
                                         font: .systemFont(ofSize: 11), background: answerFill, indent: 8, after: 2),
                                    words: shared.answer))
            if let summary = shared.summary {
                text.append(line("Highlighted: \(summary).", font: .systemFont(ofSize: 10), color: muted, indent: 8, after: 6))
            }
            for answer in references {
                let match = SharedWords.find(answer: question.answerText, reference: answer.text, question: question.text)
                text.append(line(answer.label, font: .systemFont(ofSize: 10, weight: .semibold), color: accent,
                                 before: 4, after: 1))
                text.append(highlighted(line(answer.text, font: .systemFont(ofSize: 10), color: muted, after: 4),
                                        words: match.reference))
            }
        }
        return text
    }

    private static func line(_ string: String, font: NSFont, color: NSColor = ink, background: NSColor? = nil,
                             indent: CGFloat = 0, before: CGFloat = 0, after: CGFloat = 0) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = before
        paragraph.paragraphSpacing = after
        paragraph.lineHeightMultiple = 1.15
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.tailIndent = indent > 0 ? -indent : 0
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        if let background { attributes[.backgroundColor] = background }
        return NSAttributedString(string: string + "\n", attributes: attributes)
    }

    /// Marks shared words the way the app does (the line's text starts at 0).
    static let highlightFill = NSColor(srgbRed: 1.0, green: 0.80, blue: 0.45, alpha: 1)

    private static func highlighted(_ line: NSAttributedString, words: Set<Int>) -> NSAttributedString {
        guard !words.isEmpty else { return line }
        let result = NSMutableAttributedString(attributedString: line)
        let string = line.string
        for range in SharedWords.highlightRanges(string, words: words) {
            result.addAttribute(.backgroundColor, value: highlightFill, range: NSRange(range, in: string))
        }
        return result
    }

    private static func bullet(_ string: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = 14
        paragraph.paragraphSpacing = 2
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
        return NSAttributedString(string: "\u{2022}\t\(string)\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: ink, .paragraphStyle: paragraph,
        ])
    }
}

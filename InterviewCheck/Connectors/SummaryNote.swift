import Foundation
import InterviewCheckConnectors
import InterviewCheckKit

/// The private note sent back to an ATS after an interview: short, framed
/// as a signal, with the interviewer's own verdicts and notes.
enum SummaryNote {
    static func make(_ report: InterviewReportData) -> String {
        let interview = report.interview
        var lines = ["\(AppBrand.name) summary for \(interview.candidateName.isEmpty ? "the candidate" : interview.candidateName)"]
        if let overall = interview.overallPercent {
            lines.append("AI-assistance signal: \(overall)% overall; \(report.flaggedLine) (70% or more).")
        }
        for question in report.questions {
            var line = "Q\(question.ordinal). \(question.text.isEmpty ? "(question not captured)" : question.text)"
            if let score = report.scores[question.id] {
                line += " \u{2014} \(score.percent)% (\(score.confidence.rawValue) confidence)"
                if let reason = score.reasons.first { line += ": \(reason)" }
            }
            if let verdict = report.verdicts[question.id] { line += " Interviewer: \(verdict.title)." }
            if let note = report.notes[question.id], !note.isEmpty { line += " Note: \(note)" }
            lines.append(line)
        }
        if interview.scoredFrom == .transcript { lines.append(ScoredFrom.transcriptCaveat) }
        lines.append("Scores are signals to follow up on, not proof. Review the evidence before any decision.")
        return lines.joined(separator: "\n")
    }
}

extension ConnectorManager {
    /// The ATS this report can send a note to, if it was prepared from one
    /// that is still connected and supports notes.
    func noteDestination(for report: InterviewReportData) -> (ExternalInterview, ConnectorKind)? {
        guard let ref = report.interview.externalRef,
              let interview = database.loadExternalLink(ref) ?? database.loadExternalInterviews(startingAfter: .distantPast)
                .first(where: { $0.id == ref }),
              account(interview.source) != nil,
              interview.source.descriptor.capabilities.contains(.notes) else { return nil }
        return (interview, interview.source)
    }

    func sendNote(_ text: String, to interview: ExternalInterview) async throws {
        guard let destination = try makeConnector(interview.source) as? NoteDestination else {
            throw ConnectorError.unsupported("\(interview.source.descriptor.name) can't take notes.")
        }
        try await destination.addNote(text, to: interview)
    }
}

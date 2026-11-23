import Foundation

/// How a report states whether the candidate was told the interview is
/// checked. Only an interviewer's confirmation counts; without one (a
/// recording scored in the background) the report says so plainly.
enum ConsentNotice {
    static let notConfirmed = "not confirmed in InterviewCheck"

    /// "yes, 10:04" or the unconfirmed wording, for the Markdown report.
    static func detail(_ confirmedAt: Date?, timeFormatter: DateFormatter) -> String {
        confirmedAt.map { "yes, \(timeFormatter.string(from: $0))" } ?? notConfirmed
    }

    /// "yes" or the unconfirmed wording, for the printed report.
    static func short(_ confirmedAt: Date?) -> String {
        confirmedAt == nil ? notConfirmed : "yes"
    }

    /// The phrase in the report header line.
    static func headline(_ confirmedAt: Date?) -> String {
        confirmedAt == nil ? "notice not confirmed" : "candidate notified"
    }
}

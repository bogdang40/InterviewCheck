import Foundation
import InterviewCheckConnectors

/// ATS and unified APIs list the whole company's interviews; only the ones
/// the interviewer is on belong in Upcoming, reminders and recording matches.
extension ConnectorManager {
    static let myEmailsKey = "interviewcheck.myEmails"

    /// Typed in Connections, plus the addresses of connected Google,
    /// Microsoft 365, Zoom or Recruitee accounts.
    var myEmails: Set<String> {
        let typed = (defaults.string(forKey: Self.myEmailsKey) ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ", ;\n"))
        let fromAccounts = accounts.map(\.label).flatMap { $0.components(separatedBy: " ") }
        return Set((typed + fromAccounts).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.contains("@") && $0.contains(".") })
    }

    var typedEmails: String {
        get { defaults.string(forKey: Self.myEmailsKey) ?? "" }
        set {
            defaults.set(newValue, forKey: Self.myEmailsKey)
            reloadCache()
        }
    }

    /// Calendar and meeting interviews are the user's own. From an ATS, an
    /// interview counts when one of its interviewers is the user, or when it
    /// names no interviewer emails (nothing to check against).
    func isMine(_ interview: ExternalInterview) -> Bool {
        guard [.ats, .unified, .mcp].contains(interview.source.descriptor.category) else { return true }
        let mine = myEmails
        let listed = interview.interviewers.compactMap { $0.email?.lowercased() }
        guard !mine.isEmpty, !listed.isEmpty else { return true }
        return listed.contains(where: mine.contains)
    }
}

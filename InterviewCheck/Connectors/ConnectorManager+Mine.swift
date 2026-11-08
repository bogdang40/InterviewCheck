import Foundation
import InterviewCheckConnectors

/// ATS and unified APIs list the whole company's interviews; only the ones
/// the interviewer is on belong in Upcoming, reminders and recording matches.
extension ConnectorManager {
    static let myEmailsKey = "interviewcheck.myEmails"
    static let showAllKey = "interviewcheck.showAllInterviews"

    /// Show every ATS interview, not only the user's own.
    var showsAllInterviews: Bool {
        get { defaults.bool(forKey: Self.showAllKey) }
        set {
            defaults.set(newValue, forKey: Self.showAllKey)
            reloadCache()
        }
    }

    /// Typed in Connections, plus the addresses of connected Google,
    /// Microsoft 365, Zoom or Recruitee accounts.
    var myEmails: Set<String> {
        let typed = (defaults.string(forKey: Self.myEmailsKey) ?? "")
            .components(separatedBy: CharacterSet(charactersIn: ", ;\n"))
        let fromAccounts = accounts.map(\.label).flatMap { $0.components(separatedBy: " ") }
        return Set((typed + fromAccounts).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.contains("@") && $0.contains(".") })
    }

    /// Names typed in Connections (entries without "@"), for sources that list
    /// interviewers by name only (Workable, Zoho Recruit, SmartRecruiters …).
    var myNames: Set<String> {
        Set((defaults.string(forKey: Self.myEmailsKey) ?? "").components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .filter { !$0.contains("@") }
            .map { InterviewMerger.normalized($0) }
            .filter { $0.split(separator: " ").count >= 2 })
    }

    var typedEmails: String {
        get { defaults.string(forKey: Self.myEmailsKey) ?? "" }
        set {
            defaults.set(newValue, forKey: Self.myEmailsKey)
            reloadCache()
        }
    }

    /// Calendar and meeting interviews are the user's own. From an ATS, an
    /// interview counts when one of its interviewers is the user: by email, or
    /// by full name when the source gives names only and a name was typed in
    /// Connections. With nothing to check against, it counts.
    func isMine(_ interview: ExternalInterview) -> Bool {
        guard !showsAllInterviews, [.ats, .unified, .mcp].contains(interview.source.descriptor.category) else { return true }
        let mine = myEmails
        let listed = interview.interviewers.compactMap { $0.email?.lowercased() }
        if !mine.isEmpty, !listed.isEmpty { return listed.contains(where: mine.contains) }
        let names = myNames
        let listedNames = interview.interviewers.map { InterviewMerger.normalized($0.name) }.filter { !$0.isEmpty }
        if listed.isEmpty, !names.isEmpty, !listedNames.isEmpty { return listedNames.contains(where: names.contains) }
        return true
    }
}

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
    func isMine(_ interview: ExternalInterview, ignoringShowAll: Bool = false) -> Bool {
        guard ignoringShowAll || !showsAllInterviews else { return true }
        guard [.ats, .unified, .mcp].contains(interview.source.descriptor.category) else { return true }
        let mine = myEmails
        let listed = interview.interviewers.compactMap { $0.email?.lowercased() }
        if !mine.isEmpty, !listed.isEmpty { return listed.contains(where: mine.contains) }
        let names = myNames
        let listedNames = interview.interviewers.map { InterviewMerger.normalized($0.name) }.filter { !$0.isEmpty }
        if listed.isEmpty, !names.isEmpty, !listedNames.isEmpty { return listedNames.contains(where: names.contains) }
        return true
    }

    /// The setup holds this interview: prepared from it, or from another copy
    /// of the same meeting (its id can change when an ATS copy comes or goes).
    func holds(_ interview: ExternalInterview, in controller: InterviewController) -> Bool {
        guard let prepared = controller.preparedFrom, controller.externalRef != nil else { return false }
        if prepared == interview.id { return true }
        guard let ref = controller.externalRef, let saved = database.loadExternalLink(ref) else { return false }
        return Self.sameInterview(saved, interview)
    }

    /// Two copies of one interview: within the merge window, not clearly two
    /// different candidates, and the same by the rule that merged them (link,
    /// email or name). The same email settles it; names that cannot be the same
    /// person ("Jane Doe" vs "Max Roe") rule it out even in a shared meeting
    /// room, while "Jane Doe", "Jane A. Doe" and "Doe, Jane" are compatible.
    static func sameInterview(_ a: ExternalInterview, _ b: ExternalInterview) -> Bool {
        if a.source == b.source, a.externalID == b.externalID { return true }
        // Two events from one calendar, mailbox or booking tool are two
        // interviews, whatever names were guessed for them. (Not for ATSs: a
        // prepared link keeps the calendar event's id under the ATS's name.)
        if a.source == b.source, ![.ats, .unified, .mcp].contains(a.source.descriptor.category) { return false }
        guard abs(a.startsAt.timeIntervalSince(b.startsAt)) <= 10 * 60 else { return false }
        if let left = a.candidate?.email?.lowercased(), let right = b.candidate?.email?.lowercased(), left == right { return true }
        let left = nameWords(a.candidate?.name), right = nameWords(b.candidate?.name)
        if !left.isEmpty, !right.isEmpty, !left.isSubset(of: right), !right.isSubset(of: left) { return false }
        return InterviewMerger.isSame(a, b, window: 10 * 60)
    }

    /// A name's words, without placeholders a title guess or ATS may put there.
    static func nameWords(_ name: String?) -> Set<String> {
        Set(InterviewMerger.normalized(name ?? "").split(separator: " ").map(String.init))
            .subtracting(["candidate", "interview", "screen", "phone", "call", "with", "for", "and", "the"])
    }
}

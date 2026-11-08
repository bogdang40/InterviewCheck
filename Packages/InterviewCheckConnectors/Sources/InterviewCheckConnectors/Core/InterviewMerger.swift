import Foundation

/// The same interview often arrives twice: from the ATS and from the
/// calendar invite the ATS sent. This keeps one, taking the ATS record
/// (candidate, job, application) and filling gaps such as the meeting link
/// from the calendar copy.
public enum InterviewMerger {
    public static func merge(_ interviews: [ExternalInterview], window: TimeInterval = 10 * 60) -> [ExternalInterview] {
        var result: [ExternalInterview] = []
        for interview in interviews.sorted(by: rank) {
            if let index = result.firstIndex(where: { isSame($0, interview, window: window) }) {
                result[index] = fill(result[index], from: interview)
            } else {
                result.append(interview)
            }
        }
        return result.sorted { $0.startsAt < $1.startsAt }
    }

    /// ATS and unified sources first, then calendars and invites.
    private static func rank(_ a: ExternalInterview, _ b: ExternalInterview) -> Bool {
        let order = { (interview: ExternalInterview) -> Int in
            switch interview.source.descriptor.category {
            case .ats, .unified, .mcp: return 0
            case .meetings, .scheduling: return 1
            case .calendar: return 2
            case .mail: return 3
            }
        }
        if order(a) != order(b) { return order(a) < order(b) }
        if a.startsAt != b.startsAt { return a.startsAt < b.startsAt }
        // A stable choice, so the merged interview keeps its id from sync to sync.
        return (a.source.rawValue, a.externalID) < (b.source.rawValue, b.externalID)
    }

    public static func isSame(_ a: ExternalInterview, _ b: ExternalInterview, window: TimeInterval) -> Bool {
        guard abs(a.startsAt.timeIntervalSince(b.startsAt)) <= window, !distinctEvents(a, b) else { return false }
        if let left = a.meetingURL.map(meetingKey), let right = b.meetingURL.map(meetingKey), left == right { return true }
        if let left = a.candidate?.email?.lowercased(), let right = b.candidate?.email?.lowercased() { return left == right }
        if let left = a.candidate.map({ normalized($0.name) }), let right = b.candidate.map({ normalized($0.name) }),
           !left.isEmpty { return left == right }
        return false
    }

    /// Two different events of one source at different times (back-to-back
    /// screens in one meeting room). The same event moved, or listed in two
    /// calendars at the same time, is not distinct: Mac Calendar and Zoom ids
    /// end in "@<start>", which is ignored.
    public static func distinctEvents(_ a: ExternalInterview, _ b: ExternalInterview) -> Bool {
        let base = { (id: String) in id.replacingOccurrences(of: #"@\d+$"#, with: "", options: .regularExpression) }
        return a.source == b.source && base(a.externalID) != base(b.externalID) && a.startsAt != b.startsAt
    }

    static func fill(_ primary: ExternalInterview, from other: ExternalInterview) -> ExternalInterview {
        var merged = primary
        if merged.meetingURL == nil { merged.meetingURL = other.meetingURL }
        if merged.endsAt == nil { merged.endsAt = other.endsAt }
        if merged.candidate == nil { merged.candidate = other.candidate }
        if merged.candidate?.email == nil { merged.candidate?.email = other.candidate?.email }
        if merged.job == nil { merged.job = other.job }
        if merged.interviewers.isEmpty { merged.interviewers = other.interviewers }
        return merged
    }

    /// Host and path without query, so links with different tracking or
    /// password parameters still match.
    static func meetingKey(_ url: URL) -> String {
        "\(url.host?.lowercased() ?? "")\(url.path.lowercased())"
    }

    public static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

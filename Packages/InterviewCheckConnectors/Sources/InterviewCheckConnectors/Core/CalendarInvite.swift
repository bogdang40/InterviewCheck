import Foundation

/// A calendar event from any source (EventKit, Google, Outlook, an .ics
/// file), before deciding whether it is an interview.
public struct CalendarEvent: Equatable, Sendable {
    public var id: String
    public var title: String
    public var startsAt: Date
    public var endsAt: Date?
    public var location: String?
    public var notes: String?
    public var url: URL?
    public var organizer: ExternalPerson?
    public var attendees: [ExternalPerson]

    public init(id: String, title: String, startsAt: Date, endsAt: Date? = nil, location: String? = nil,
                notes: String? = nil, url: URL? = nil, organizer: ExternalPerson? = nil, attendees: [ExternalPerson] = []) {
        self.id = id
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.location = location
        self.notes = notes
        self.url = url
        self.organizer = organizer
        self.attendees = attendees
    }
}

/// Decides which calendar events are interviews and reads the candidate
/// and role from the title ("Interview: Jane Doe - Backend Engineer").
public enum InterviewEventClassifier {
    static let keywords = ["interview", "phone screen", "tech screen", "technical screen", "screening call",
                           "onsite", "on-site", "hiring manager", "panel", "take-home review", "debrief with candidate",
                           "entrevista", "entretien", "vorstellungsgespr\u{00E4}ch", "interviu"]

    public static func isInterview(_ event: CalendarEvent, extraKeywords: [String] = []) -> Bool {
        let title = event.title.lowercased()
        return (keywords + extraKeywords.map { $0.lowercased() }).contains { !$0.isEmpty && title.contains($0) }
    }

    /// Candidate and role guessed from the title; the candidate falls back to
    /// the one attendee from outside the organiser's email domain.
    public static func guess(_ event: CalendarEvent) -> (candidate: String?, role: String?) {
        var title = event.title
        for prefix in [#"(?i)^\s*(re:|fwd?:|updated invitation:|invitation:|accepted:)\s*"#] {
            title = title.replacingOccurrences(of: prefix, with: "", options: .regularExpression)
        }
        // "Interview with Jane Doe for Backend Engineer"
        if let match = firstMatch(#"(?i)interview(?:\s+call)?\s+with\s+(.+?)(?:\s+(?:for|-|\x{2013}|\x{2014}|\||:)\s+(.+))?$"#, in: title) {
            return (match[0].map(clean), match[1].flatMap(cleanRole))
        }
        // "Jane Doe <> Acme | Backend Engineer Interview" / "Jane Doe - Backend Engineer - Interview"
        let parts = title.components(separatedBy: CharacterSet(charactersIn: "|\u{2013}\u{2014}"))
            .flatMap { $0.components(separatedBy: " - ") }
            .flatMap { $0.components(separatedBy: ": ") }
            .flatMap { $0.components(separatedBy: " <> ") }
            .flatMap { $0.components(separatedBy: " / ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var candidate: String?
        var roles: [String] = []
        for part in parts {
            let lower = part.lowercased()
            let isKeyword = keywords.contains { lower == $0 || lower.hasSuffix(" \($0)") || lower.hasPrefix("\($0) ") }
            if isPersonName(part), candidate == nil {
                candidate = part
            } else if !isKeyword || lower.split(separator: " ").count > 2 {
                if let stripped = cleanRole(part), !stripped.isEmpty, !isPersonName(stripped) { roles.append(stripped) }
            }
        }
        if candidate == nil { candidate = outsideAttendee(event)?.name }
        // A part that names a job ("Backend Engineer") beats a company name ("Acme").
        let role = roles.first { hasRoleWord($0) } ?? roles.first
        return (candidate, role)
    }

    public static func interview(from event: CalendarEvent, source: ConnectorKind) -> ExternalInterview {
        let (candidateName, role) = guess(event)
        // With exactly one outside guest, that guest is the candidate, whether
        // or not the calendar knows their display name.
        let outside = outsideAttendee(event)
        let candidate = (candidateName ?? outside?.name).map {
            ExternalCandidate(name: $0, email: outside?.email)
        }
        return ExternalInterview(
            source: source, externalID: event.id, title: event.title, startsAt: event.startsAt, endsAt: event.endsAt,
            meetingURL: event.url.flatMap { MeetingLinks.platform(of: $0) == .other ? nil : $0 }
                ?? MeetingLinks.first(in: [event.location, event.notes, event.url?.absoluteString]),
            candidate: candidate,
            job: role.map { ExternalJob(externalID: "", title: $0) },
            interviewers: [event.organizer].compactMap { $0 }
        )
    }

    /// The single attendee whose email domain differs from the organiser's.
    static func outsideAttendee(_ event: CalendarEvent) -> ExternalPerson? {
        guard let domain = event.organizer?.email?.split(separator: "@").last?.lowercased() else { return nil }
        let outside = event.attendees.filter {
            guard let email = $0.email?.lowercased(), let attendeeDomain = email.split(separator: "@").last else { return false }
            return attendeeDomain != domain && !email.contains("resource.calendar") && !email.hasPrefix("noreply")
        }
        return outside.count == 1 ? outside[0] : nil
    }

    static let roleWords: Set<String> = ["engineer", "engineering", "developer", "manager", "designer", "analyst", "interview",
                                         "screen", "lead", "director", "scientist", "intern", "specialist", "architect",
                                         "consultant", "senior", "staff", "head", "team", "round", "call", "sync", "chat",
                                         "onsite", "panel", "technical", "recruiter", "product", "associate", "officer",
                                         "coordinator", "administrator", "representative", "executive", "sre", "devops"]

    /// Whole words only: "Callum" and "Chatterjee" are not "call" and "chat".
    static func hasRoleWord(_ text: String) -> Bool {
        text.lowercased().components(separatedBy: CharacterSet.letters.inverted).contains { roleWords.contains($0) }
    }

    static func isPersonName(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard (2...4).contains(words.count) else { return false }
        guard !hasRoleWord(text) else { return false }
        return words.allSatisfy { word in
            guard let first = word.unicodeScalars.first else { return false }
            return CharacterSet.uppercaseLetters.contains(first) && word.count <= 20
        }
    }

    static func cleanRole(_ text: String) -> String? {
        var role = text.replacingOccurrences(of: #"(?i)\b(interview|phone screen|tech(nical)? screen|screen|onsite|round \d+|call)\b"#,
                                             with: "", options: .regularExpression)
        role = role.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-:|()")))
        return role.isEmpty ? nil : role
    }

    static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-:|()")))
    }

    static func firstMatch(_ pattern: String, in text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }
}

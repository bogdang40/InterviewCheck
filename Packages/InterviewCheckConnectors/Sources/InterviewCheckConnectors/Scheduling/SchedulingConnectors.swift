import Foundation

/// Booking-link tools many recruiters use for first-round screens. A
/// booking's invitee is the candidate; their email lets Prepare find the
/// candidate, job and résumé in a connected ATS.
enum BookingFilter {
    /// Keeps bookings whose name reads like an interview, or every booking
    /// when the account is used only for interviews.
    static func keeps(_ title: String, everyBooking: Bool, extraKeywords: [String]) -> Bool {
        everyBooking || InterviewEventClassifier.isInterview(CalendarEvent(id: "", title: title, startsAt: Date()),
                                                             extraKeywords: extraKeywords)
    }

    static func keywords(_ credentials: ConnectorCredentials) -> [String] {
        credentials["keywords"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
    }

    /// A known meeting link, or else any web link given as the location
    /// (Cal Video, a custom room).
    static func link(_ texts: [String?]) -> URL? {
        MeetingLinks.first(in: texts) ?? texts.compactMap { text in
            text.flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil }
        }.first
    }

    /// A role in the booking name ("Phone Screen - Backend Engineer").
    /// Booking names are generic ("Technical Interview", "30 Minute Meeting"),
    /// so only a part that names a job counts.
    static func job(from title: String) -> ExternalJob? {
        guard let role = InterviewEventClassifier.guess(CalendarEvent(id: "", title: title, startsAt: Date())).role,
              role.lowercased().components(separatedBy: CharacterSet.letters.inverted).contains(where: jobWords.contains) else { return nil }
        return ExternalJob(externalID: "", title: role)
    }

    static let jobWords: Set<String> = ["engineer", "developer", "manager", "designer", "analyst", "lead", "director", "scientist",
                                        "intern", "specialist", "architect", "consultant", "recruiter", "associate", "officer",
                                        "coordinator", "administrator", "representative", "executive", "sre", "devops", "accountant",
                                        "nurse", "teacher", "writer", "marketer", "salesperson", "technician", "assistant"]
}

/// Calendly API v2 with a personal access token (scope scheduled_events:read).
public struct CalendlyConnector: InterviewSource {
    public let kind = ConnectorKind.calendly
    let api: APIClient
    let everyBooking: Bool
    let extraKeywords: [String]
    /// Pages of 100 bookings read per sync.
    static let pageLimit = 10

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        let token = try credentials.required("apiKey", "personal access token")
        api = APIClient(baseURL: URL(string: "https://api.calendly.com")!, headers: ["Authorization": "Bearer \(token)"],
                        transport: transport)
        everyBooking = credentials["everyBooking"] == "true"
        extraKeywords = BookingFilter.keywords(credentials)
    }

    public func verify() async throws -> String {
        let me = try await api.getJSON("users/me")["resource"]
        return me["email"].string ?? me["name"].string ?? "Calendly"
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        guard let user = try await api.getJSON("users/me")["resource"]["uri"].string else {
            throw ConnectorError.invalidResponse("no user in users/me")
        }
        var events: [JSONValue] = []
        var next: String? = "scheduled_events"
        var query = [URLQueryItem(name: "user", value: user), URLQueryItem(name: "status", value: "active"),
                     URLQueryItem(name: "min_start_time", value: DateParsing.iso(start)),
                     URLQueryItem(name: "max_start_time", value: DateParsing.iso(end)),
                     URLQueryItem(name: "sort", value: "start_time:asc"), URLQueryItem(name: "count", value: "100")]
        var pages = 0
        while let path = next, pages < Self.pageLimit {
            let page = try await api.getJSON(path, query: query)
            events += page["collection"].array
            pages += 1
            // The next page is a full URL; only ever follow it on Calendly's own API host.
            next = page["pagination"]["next_page"].url.flatMap { $0.host == "api.calendly.com" ? $0.absoluteString : nil }
            query = []
        }
        if next != nil { SyncNotes.cut("bookings", read: events.count) }

        var interviews: [ExternalInterview] = []
        for event in events {
            guard let uri = event["uri"].string, let startsAt = event["start_time"].date,
                  event["status"].string != "canceled" else { continue }
            let title = event["name"].string ?? "Meeting"
            guard BookingFilter.keeps(title, everyBooking: everyBooking, extraKeywords: extraKeywords) else { continue }
            let uuid = URL(string: uri)?.lastPathComponent ?? uri
            let invitees = try await api.getJSON("scheduled_events/\(uuid)/invitees",
                                                 query: [URLQueryItem(name: "status", value: "active"),
                                                         URLQueryItem(name: "count", value: "100")])["collection"].array
            let invitee = invitees.first
            let answers = invitee?["questions_and_answers"].array.compactMap { $0["answer"].string } ?? []
            let location = event["location"]
            interviews.append(ExternalInterview(
                source: .calendly, externalID: uuid, title: title, startsAt: startsAt, endsAt: event["end_time"].date,
                meetingURL: BookingFilter.link([location["join_url"].string, location["location"].string]),
                candidate: invitee.flatMap { invitee in
                    invitee["name"].string.map {
                        ExternalCandidate(name: $0, email: invitee["email"].string, profileURL: Self.profileLink(in: answers))
                    }
                },
                job: BookingFilter.job(from: title),
                interviewers: event["event_memberships"].array.compactMap { member in
                    member["user_name"].string.map { ExternalPerson(name: $0, email: member["user_email"].string) }
                }
            ))
        }
        return interviews
    }

    /// A LinkedIn (or other profile) link the candidate typed into a booking question.
    static func profileLink(in answers: [String]) -> URL? {
        let links = answers.flatMap { answer in
            answer.split(whereSeparator: \.isWhitespace).compactMap { word -> URL? in
                let text = word.hasPrefix("http") ? String(word) : (word.contains("linkedin.com/") ? "https://\(word)" : "")
                return URL(string: text).flatMap { $0.host == nil ? nil : $0 }
            }
        }
        return links.first { $0.host?.contains("linkedin.com") == true } ?? links.first { $0.host?.contains("github.com") == true }
    }
}

/// Cal.com API v2 (cal.com or a self-hosted instance) with an API key.
public struct CalComConnector: InterviewSource {
    public let kind = ConnectorKind.calCom
    let api: APIClient
    let everyBooking: Bool
    let extraKeywords: [String]
    static let pageLimit = 10
    static let apiVersion = "2026-05-01"

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        let key = try credentials.required("apiKey", "API key")
        let typed = credentials["url"]?.trimmingCharacters(in: .whitespaces) ?? ""
        guard let base = URL(string: typed.isEmpty ? "https://api.cal.com/v2" : typed), base.scheme == "https" else {
            throw ConnectorError.missingCredential("API address starting with https://")
        }
        api = APIClient(baseURL: base, headers: ["Authorization": "Bearer \(key)", "cal-api-version": Self.apiVersion],
                        transport: transport)
        everyBooking = credentials["everyBooking"] == "true"
        extraKeywords = BookingFilter.keywords(credentials)
    }

    public func verify() async throws -> String {
        let me = try await api.getJSON("me")["data"]
        return me["email"].string ?? me["username"].string ?? "Cal.com"
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        var bookings: [JSONValue] = []
        // Finished ones too (the sync looks a week back to match recordings);
        // Cal.com takes one status per request.
        for status in ["upcoming", "past"] {
            bookings += try await self.bookings(status: status, from: start, to: end)
        }
        var seen = Set<String>()
        return bookings.filter { seen.insert($0["uid"].string ?? $0["id"].string ?? UUID().uuidString).inserted }
            .compactMap { booking in self.interview(booking, from: start, to: end) }
    }

    private func bookings(status: String, from start: Date, to end: Date) async throws -> [JSONValue] {
        var bookings: [JSONValue] = []
        var cursor: String?
        var pages = 0
        repeat {
            var query = [URLQueryItem(name: "status", value: status),
                         URLQueryItem(name: "afterStart", value: DateParsing.iso(start)),
                         URLQueryItem(name: "beforeEnd", value: DateParsing.iso(end.addingTimeInterval(24 * 3600))),
                         URLQueryItem(name: "sortStart", value: "asc"), URLQueryItem(name: "limit", value: "100")]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let page = try await api.getJSON("bookings", query: query)
            bookings += page["data"].array
            pages += 1
            cursor = page["pagination"]["hasMore"].bool == true ? page["pagination"]["nextCursor"].string : nil
        } while cursor != nil && pages < Self.pageLimit
        if cursor != nil { SyncNotes.cut("bookings", read: bookings.count) }
        return bookings
    }

    private func interview(_ booking: JSONValue, from start: Date, to end: Date) -> ExternalInterview? {
        guard let startsAt = booking["start"].date, startsAt >= start, startsAt <= end,
              booking["status"].string.map({ ["accepted", "awaiting_host"].contains($0) }) ?? true else { return nil }
        let title = booking["title"].string ?? "Meeting"
        guard BookingFilter.keeps(title, everyBooking: everyBooking, extraKeywords: extraKeywords) else { return nil }
        let attendee = booking["attendees"].array.first
        return ExternalInterview(
            source: .calCom, externalID: booking["uid"].string ?? booking["id"].string ?? UUID().uuidString,
            title: title, startsAt: startsAt, endsAt: booking["end"].date,
            meetingURL: BookingFilter.link([booking["location"].string, booking["meetingUrl"].string]),
            candidate: attendee.flatMap { attendee in
                attendee["name"].string.map { ExternalCandidate(name: $0, email: attendee["email"].string) }
            },
            job: BookingFilter.job(from: title),
            interviewers: booking["hosts"].array.compactMap { host in
                host["name"].string.map { ExternalPerson(name: $0, email: host["email"].string) }
            }
        )
    }
}

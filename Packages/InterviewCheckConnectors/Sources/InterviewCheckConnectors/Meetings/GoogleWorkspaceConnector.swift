import Foundation

/// Google Calendar interviews and Google Meet transcripts (Meet REST API,
/// meetings the user organised; kept by Google for 30 days).
public struct GoogleWorkspaceConnector: InterviewSource, RecordingSource {
    public let kind = ConnectorKind.google
    private let token: AccessTokenProvider
    private let transport: HTTPTransport
    private let keywords: [String]

    public init(credentials: ConnectorCredentials, transport: HTTPTransport, accessToken: AccessTokenProvider?) throws {
        guard let accessToken else { throw ConnectorError.notConnected }
        token = accessToken
        self.transport = transport
        keywords = credentials["keywords"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
    }

    private func client(_ base: String) async throws -> APIClient {
        APIClient(baseURL: URL(string: base)!, headers: ["Authorization": "Bearer \(try await token())"], transport: transport)
    }

    public func verify() async throws -> String {
        let calendar = try await client("https://www.googleapis.com/calendar/v3").getJSON("calendars/primary")
        return calendar["id"].string ?? calendar["summary"].string ?? "Google Calendar"
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        let api = try await client("https://www.googleapis.com/calendar/v3")
        var events: [JSONValue] = []
        var pageToken: String?
        for _ in 0..<5 {
            var query = [URLQueryItem(name: "timeMin", value: DateParsing.iso(start)),
                         URLQueryItem(name: "timeMax", value: DateParsing.iso(end)),
                         URLQueryItem(name: "singleEvents", value: "true"),
                         URLQueryItem(name: "orderBy", value: "startTime"),
                         URLQueryItem(name: "maxResults", value: "250")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page = try await api.getJSON("calendars/primary/events", query: query)
            events += page["items"].array
            guard let next = page["nextPageToken"].string else { break }
            pageToken = next
        }
        return events.compactMap(Self.calendarEvent)
            .filter { InterviewEventClassifier.isInterview($0, extraKeywords: keywords) }
            .map { InterviewEventClassifier.interview(from: $0, source: .google) }
    }

    static func calendarEvent(_ item: JSONValue) -> CalendarEvent? {
        guard let id = item["id"].string, item["status"].string != "cancelled",
              let startsAt = item.at("start.dateTime").date ?? item.at("start.date").date else { return nil }
        let video = item.at("conferenceData.entryPoints").array.first { $0["entryPointType"].string == "video" }
        let person = { (json: JSONValue) -> ExternalPerson in
            ExternalPerson(name: json["displayName"].string ?? json["email"].string ?? "", email: json["email"].string)
        }
        return CalendarEvent(
            id: id, title: item["summary"].string ?? "", startsAt: startsAt,
            endsAt: item.at("end.dateTime").date ?? item.at("end.date").date,
            location: item["location"].string, notes: item["description"].string.map(HTMLText.plain),
            url: video?["uri"].url ?? item["hangoutLink"].url,
            organizer: item["organizer"].isNull ? nil : person(item["organizer"]),
            attendees: item["attendees"].array.filter { $0["resource"].bool != true }.map(person)
        )
    }

    public func recordings(since: Date) async throws -> [ExternalRecording] {
        let meet = try await client("https://meet.googleapis.com/v2")
        let filter = "start_time>=\"\(DateParsing.iso(since))\""
        let records = try await meet.getJSON("conferenceRecords", query: [URLQueryItem(name: "filter", value: filter),
                                                                           URLQueryItem(name: "pageSize", value: "50")])
        var result: [ExternalRecording] = []
        for record in records["conferenceRecords"].array {
            guard let name = record["name"].string, let started = record["startTime"].date, record["endTime"].date != nil else { continue }
            let transcripts = try await meet.getJSON("\(name)/transcripts")["transcripts"].array
                .filter { $0["state"].string == "FILE_GENERATED" || $0["state"].string == "ENDED" }
            guard let transcript = transcripts.first?["name"].string else { continue }
            var components = URLComponents(string: "googlemeet://transcript")!
            components.queryItems = [URLQueryItem(name: "name", value: transcript), URLQueryItem(name: "record", value: name)]
            result.append(ExternalRecording(
                source: .google, externalID: name, title: "Google Meet", startedAt: started,
                duration: record["endTime"].date.map { $0.timeIntervalSince(started) },
                files: [ExternalFile(kind: .transcript, filename: "Google Meet transcript.vtt", url: components.url!, needsAuth: true)]
            ))
        }
        return result
    }

    /// Builds a WebVTT file from the transcript entries and participant names.
    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        let items = URLComponents(url: file.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let transcript = items.first(where: { $0.name == "name" })?.value,
              let record = items.first(where: { $0.name == "record" })?.value else { throw ConnectorError.notFound }
        let meet = try await client("https://meet.googleapis.com/v2")
        var names: [String: String] = [:]
        for participant in try await meet.getJSON("\(record)/participants", query: [URLQueryItem(name: "pageSize", value: "100")])["participants"].array {
            guard let id = participant["name"].string else { continue }
            names[id] = participant.at("signedinUser.displayName").string ?? participant.at("anonymousUser.displayName").string
                ?? participant.at("phoneUser.displayName").string
        }
        var entries: [JSONValue] = []
        var pageToken: String?
        for _ in 0..<50 {
            var query = [URLQueryItem(name: "pageSize", value: "100")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page = try await meet.getJSON("\(transcript)/entries", query: query)
            entries += page["transcriptEntries"].array
            guard let next = page["nextPageToken"].string else { break }
            pageToken = next
        }
        let origin = entries.compactMap { $0["startTime"].date }.min() ?? Date()
        let cues = entries.compactMap { entry -> TranscriptCue? in
            guard let start = entry["startTime"].date, let text = entry["text"].string else { return nil }
            return TranscriptCue(start: start.timeIntervalSince(origin),
                                 end: (entry["endTime"].date ?? start).timeIntervalSince(origin),
                                 speaker: entry["participant"].string.flatMap { names[$0] }, text: text)
        }
        let destination = folder.appendingPathComponent("Google Meet transcript.vtt")
        try WebVTT.text(cues).write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }
}

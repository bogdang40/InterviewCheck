import Foundation

/// Outlook calendar interviews and, with admin consent, Teams transcripts
/// (attendees can read them) and recordings (organiser only).
public struct MicrosoftGraphConnector: InterviewSource, RecordingSource {
    public let kind = ConnectorKind.microsoft365
    private let token: AccessTokenProvider
    private let transport: HTTPTransport
    private let keywords: [String]
    private let transcripts: Bool

    public init(credentials: ConnectorCredentials, transport: HTTPTransport, accessToken: AccessTokenProvider?) throws {
        guard let accessToken else { throw ConnectorError.notConnected }
        token = accessToken
        self.transport = transport
        keywords = credentials["keywords"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        transcripts = credentials["transcripts"] == "true"
    }

    private func client() async throws -> APIClient {
        APIClient(baseURL: URL(string: "https://graph.microsoft.com/v1.0")!,
                  headers: ["Authorization": "Bearer \(try await token())",
                            "Prefer": "outlook.timezone=\"UTC\", outlook.body-content-type=\"text\""],
                  transport: transport)
    }

    public func verify() async throws -> String {
        let me = try await client().getJSON("me")
        return me["mail"].string ?? me["userPrincipalName"].string ?? "Microsoft 365"
    }

    func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        let api = try await client()
        var rows: [JSONValue] = []
        var page = try await api.getJSON("me/calendarView", query: [
            URLQueryItem(name: "startDateTime", value: DateParsing.iso(start)),
            URLQueryItem(name: "endDateTime", value: DateParsing.iso(end)),
            URLQueryItem(name: "$select", value: "id,subject,start,end,organizer,attendees,onlineMeeting,location,bodyPreview,isCancelled"),
            URLQueryItem(name: "$orderby", value: "start/dateTime"),
            URLQueryItem(name: "$top", value: "100"),
        ])
        for index in 0..<10 {
            rows += page["value"].array
            guard let next = page["@odata.nextLink"].url else { break }
            guard index < 9 else { SyncNotes.cut("calendar events", read: rows.count); break }
            page = try JSONValue.parse(try await api.send(method: "GET", url: next, body: nil).0)
        }
        return rows.compactMap(Self.calendarEvent)
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        try await events(from: start, to: end)
            .filter { InterviewEventClassifier.isInterview($0, extraKeywords: keywords) }
            .map { InterviewEventClassifier.interview(from: $0, source: .microsoft365) }
    }

    /// Graph sends "2026-11-10T19:00:00.0000000" in UTC without a zone.
    static func utc(_ value: String?) -> Date? {
        guard var value else { return nil }
        if let dot = value.firstIndex(of: ".") { value = String(value[..<dot]) }
        return DateParsing.parse(value.hasSuffix("Z") ? value : value + "Z")
    }

    static func calendarEvent(_ item: JSONValue) -> CalendarEvent? {
        guard let id = item["id"].string, item["isCancelled"].bool != true,
              let startsAt = utc(item.at("start.dateTime").string) else { return nil }
        let person = { (json: JSONValue) -> ExternalPerson in
            ExternalPerson(name: json.at("emailAddress.name").string ?? json.at("emailAddress.address").string ?? "",
                           email: json.at("emailAddress.address").string)
        }
        return CalendarEvent(
            id: id, title: item["subject"].string ?? "", startsAt: startsAt, endsAt: utc(item.at("end.dateTime").string),
            location: item.at("location.displayName").string, notes: item["bodyPreview"].string,
            url: item.at("onlineMeeting.joinUrl").url,
            organizer: item["organizer"].isNull ? nil : person(item["organizer"]),
            attendees: item["attendees"].array.map(person)
        )
    }

    public func recordings(since: Date) async throws -> [ExternalRecording] {
        guard transcripts else { return [] }
        let api = try await client()
        let past = try await events(from: since, to: Date())
            .filter { InterviewEventClassifier.isInterview($0, extraKeywords: keywords) }
        var result: [ExternalRecording] = []
        for event in past {
            guard let joinURL = event.url?.absoluteString, MeetingLinks.platform(of: event.url!) == .teams else { continue }
            let escaped = joinURL.replacingOccurrences(of: "'", with: "''")
            guard let meeting = try? await api.getJSON("me/onlineMeetings", query: [
                URLQueryItem(name: "$filter", value: "JoinWebUrl eq '\(escaped)'"),
            ])["value"][0]["id"].string else { continue }
            var files: [ExternalFile] = []
            if let list = try? await api.getJSON("me/onlineMeetings/\(meeting)/transcripts")["value"].array {
                files += list.compactMap { $0["id"].string }.map {
                    ExternalFile(kind: .transcript, filename: "\(event.title) transcript.vtt",
                                 url: api.url("me/onlineMeetings/\(meeting)/transcripts/\($0)/content",
                                              query: [URLQueryItem(name: "$format", value: "text/vtt")]),
                                 needsAuth: true)
                }
            }
            if let list = try? await api.getJSON("me/onlineMeetings/\(meeting)/recordings")["value"].array {
                files += list.compactMap { $0["id"].string }.map {
                    ExternalFile(kind: .video, filename: "\(event.title).mp4",
                                 url: api.url("me/onlineMeetings/\(meeting)/recordings/\($0)/content"), needsAuth: true)
                }
            }
            if !files.isEmpty {
                result.append(ExternalRecording(source: .microsoft365, externalID: event.id, title: event.title,
                                                startedAt: event.startsAt, duration: event.endsAt?.timeIntervalSince(event.startsAt),
                                                meetingURL: event.url, files: files))
            }
        }
        return result
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        do {
            return try await FileDownload.save(file, into: folder, client: try await client(), transport: transport)
        } catch ConnectorError.forbidden(let detail) where detail.contains("SpeakerAttributionNotAllowed") {
            // The tenant hides speaker names: take the transcript without them.
            var api = try await client()
            api.headers["Accept"] = "application/vnd.microsoft.graph.transcript+text"
            var plain = file
            plain.url = URL(string: file.url.absoluteString.replacingOccurrences(of: "?$format=text/vtt", with: "")
                .replacingOccurrences(of: "?%24format=text/vtt", with: ""))!
            return try await FileDownload.save(plain, into: folder, client: api, transport: transport)
        } catch ConnectorError.forbidden(let detail) where detail.contains("GraphAccessToTranscriptsDisabled") {
            throw ConnectorError.forbidden("your Microsoft 365 admin has turned off transcript access for apps")
        }
    }
}

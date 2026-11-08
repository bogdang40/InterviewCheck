import Foundation

/// Webex OAuth: the company registers an Integration; PKCE is used, and the
/// integration's client secret is entered too (Webex asks for it on token calls).
public enum WebexConnectorProvider {
    /// Webex matches redirect URIs exactly, port included, so the sign-in
    /// listens on this fixed port: register http://127.0.0.1:53871/callback.
    public static let redirectPort: UInt16 = ConnectorOAuth.fixedRedirectPort
    public static let provider = OAuthProvider(
        authorizeURL: URL(string: "https://webexapis.com/v1/authorize")!,
        tokenURL: URL(string: "https://webexapis.com/v1/access_token")!,
        scopes: ["spark:people_read", "meeting:schedules_read", "meeting:transcripts_read", "meeting:recordings_read"]
    )
}

/// Webex meetings the user hosts, their invitees, and after the meeting its
/// transcript (WebVTT with speaker names) and recording audio.
public struct WebexMeetingsConnector: InterviewSource, RecordingSource {
    public let kind = ConnectorKind.webex
    private let token: AccessTokenProvider
    private let transport: HTTPTransport
    private let keywords: [String]
    /// Recording details (one call each) are read for at most this many meetings.
    static let detailLimit = 20

    public init(credentials: ConnectorCredentials, transport: HTTPTransport, accessToken: AccessTokenProvider?) throws {
        guard let accessToken else { throw ConnectorError.notConnected }
        token = accessToken
        self.transport = transport
        keywords = BookingFilter.keywords(credentials)
    }

    private func client() async throws -> APIClient {
        APIClient(baseURL: URL(string: "https://webexapis.com/v1")!, headers: ["Authorization": "Bearer \(try await token())"],
                  transport: transport)
    }

    func looksLikeInterview(_ title: String) -> Bool {
        InterviewEventClassifier.isInterview(CalendarEvent(id: "", title: title, startsAt: Date()), extraKeywords: keywords)
    }

    public func verify() async throws -> String {
        let me = try await client().getJSON("people/me")
        return me["emails"][0].string ?? me["displayName"].string ?? "Webex"
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        let api = try await client()
        let meetings = try await api.getJSON("meetings", query: [
            URLQueryItem(name: "meetingType", value: "scheduledMeeting"),
            URLQueryItem(name: "from", value: DateParsing.iso(start)), URLQueryItem(name: "to", value: DateParsing.iso(end)),
            URLQueryItem(name: "max", value: "100"),
        ])["items"].array
        var interviews: [ExternalInterview] = []
        for meeting in meetings {
            guard let id = meeting["id"].string, let startsAt = meeting["start"].date, let title = meeting["title"].string,
                  meeting["state"].string != "cancelled", looksLikeInterview(title) else { continue }
            let invitees = (try? await api.getJSON("meetingInvitees", query: [URLQueryItem(name: "meetingId", value: id),
                                                                               URLQueryItem(name: "max", value: "100")]))?["items"].array ?? []
            let host = meeting["hostEmail"].string.map { ExternalPerson(name: meeting["hostDisplayName"].string ?? $0, email: $0) }
            let event = CalendarEvent(
                id: id, title: title, startsAt: startsAt, endsAt: meeting["end"].date, notes: meeting["agenda"].string,
                url: meeting["webLink"].url, organizer: host,
                attendees: invitees.filter { $0["coHost"].bool != true && $0["panelist"].bool != true }.compactMap { invitee in
                    invitee["email"].string.map { ExternalPerson(name: invitee["displayName"].string ?? $0, email: $0) }
                }
            )
            interviews.append(InterviewEventClassifier.interview(from: event, source: .webex))
        }
        return interviews
    }

    public func recordings(since: Date) async throws -> [ExternalRecording] {
        let api = try await client()
        let window = [URLQueryItem(name: "from", value: DateParsing.iso(max(since, Date().addingTimeInterval(-30 * 86_400)))),
                      URLQueryItem(name: "to", value: DateParsing.iso(Date().addingTimeInterval(3600))),
                      URLQueryItem(name: "max", value: "100")]
        var found: [String: ExternalRecording] = [:]
        // Transcripts: WebVTT with each speaker's name.
        for transcript in try await api.getJSON("meetingTranscripts", query: window)["items"].array {
            guard let meetingID = transcript["meetingId"].string, let started = transcript["startTime"].date,
                  let topic = transcript["meetingTopic"].string, looksLikeInterview(topic),
                  transcript["status"].string.map({ $0.lowercased() == "available" }) ?? true else { continue }
            let link = transcript["vttDownloadLink"].url
                ?? transcript["id"].string.map { api.url("meetingTranscripts/\($0)/download", query: [URLQueryItem(name: "format", value: "vtt")]) }
            guard let link else { continue }
            var recording = found[meetingID] ?? ExternalRecording(source: .webex, externalID: meetingID, title: topic, startedAt: started, files: [])
            recording.files.append(ExternalFile(kind: .transcript, filename: "\(topic) transcript.vtt", url: link, needsAuth: true))
            found[meetingID] = recording
        }
        // Recordings: the audio file, through a short-lived direct link.
        let listed = try await api.getJSON("recordings", query: window)["items"].array.filter {
            $0["topic"].string.map(looksLikeInterview) == true && $0["status"].string != "deleted"
        }
        if listed.count > Self.detailLimit { SyncNotes.cut("recordings", read: Self.detailLimit) }
        for item in listed.prefix(Self.detailLimit) {
            guard let id = item["id"].string, let meetingID = item["meetingId"].string, let topic = item["topic"].string,
                  let started = item["timeRecorded"].date ?? item["createTime"].date else { continue }
            let details = try? await api.getJSON("recordings/\(id)")
            let links = details?["temporaryDirectDownloadLinks"]
            var recording = found[meetingID] ?? ExternalRecording(source: .webex, externalID: meetingID, title: topic, startedAt: started, files: [])
            recording.duration = recording.duration ?? item["durationSeconds"].double
            if let audio = links?["audioDownloadLink"].url {
                recording.files.append(ExternalFile(kind: .audio, filename: "\(topic).mp3", url: audio, needsAuth: false))
            } else if let video = links?["recordingDownloadLink"].url {
                recording.files.append(ExternalFile(kind: .video, filename: "\(topic).mp4", url: video, needsAuth: false))
            }
            found[meetingID] = recording
        }
        // The meeting's join link ties a recording to its scheduled interview.
        var results: [ExternalRecording] = []
        for var recording in found.values where !recording.files.isEmpty {
            if results.count < Self.detailLimit, recording.meetingURL == nil {
                recording.meetingURL = (try? await api.getJSON("meetings/\(recording.externalID)"))?["webLink"].url
            }
            results.append(recording)
        }
        return results.sorted { $0.startedAt > $1.startedAt }
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: try await client(), transport: transport)
    }
}

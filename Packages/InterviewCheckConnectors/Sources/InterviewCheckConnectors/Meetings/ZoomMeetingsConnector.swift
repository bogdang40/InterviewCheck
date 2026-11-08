import Foundation

/// Zoom meetings the user hosts and their cloud recordings (Pro plan): the
/// audio-only M4A is the file to score.
public struct ZoomMeetingsConnector: InterviewSource, RecordingSource {
    public let kind = ConnectorKind.zoom
    private let token: AccessTokenProvider
    private let transport: HTTPTransport
    private let keywords: [String]

    public init(credentials: ConnectorCredentials, transport: HTTPTransport, accessToken: AccessTokenProvider?) throws {
        guard let accessToken else { throw ConnectorError.notConnected }
        token = accessToken
        self.transport = transport
        keywords = credentials["keywords"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
    }

    private func client() async throws -> APIClient {
        APIClient(baseURL: URL(string: "https://api.zoom.us/v2")!, headers: ["Authorization": "Bearer \(try await token())"],
                  transport: transport)
    }

    public func verify() async throws -> String {
        let me = try await client().getJSON("users/me")
        return me["email"].string ?? "Zoom"
    }

    func looksLikeInterview(_ topic: String) -> Bool {
        InterviewEventClassifier.isInterview(CalendarEvent(id: "", title: topic, startsAt: Date()), extraKeywords: keywords)
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        let api = try await client()
        var meetings: [JSONValue] = []
        var next: String?
        for index in 0..<5 {
            var query = [URLQueryItem(name: "type", value: "upcoming"), URLQueryItem(name: "page_size", value: "100")]
            if let next { query.append(URLQueryItem(name: "next_page_token", value: next)) }
            let page = try await api.getJSON("users/me/meetings", query: query)
            meetings += page["meetings"].array
            guard let token = page["next_page_token"].string, !token.isEmpty else { break }
            if index == 4 { SyncNotes.cut("meetings", read: meetings.count) }
            next = token
        }
        return meetings.compactMap { meeting -> ExternalInterview? in
            guard let id = meeting["id"].string, let startsAt = meeting["start_time"].date, startsAt >= start, startsAt <= end,
                  let topic = meeting["topic"].string, looksLikeInterview(topic) else { return nil }
            let event = CalendarEvent(id: "\(id)@\(Int(startsAt.timeIntervalSince1970))", title: topic, startsAt: startsAt,
                                      endsAt: meeting["duration"].double.map { startsAt.addingTimeInterval($0 * 60) },
                                      notes: meeting["agenda"].string, url: meeting["join_url"].url)
            return InterviewEventClassifier.interview(from: event, source: .zoom)
        }
    }

    public func recordings(since: Date) async throws -> [ExternalRecording] {
        let api = try await client()
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        // At most one month per call.
        let from = max(since, Date().addingTimeInterval(-30 * 86_400))
        let page = try await api.getJSON("users/me/recordings", query: [
            URLQueryItem(name: "from", value: day.string(from: from)),
            URLQueryItem(name: "to", value: day.string(from: Date().addingTimeInterval(86_400))),
            URLQueryItem(name: "page_size", value: "100"),
        ])
        if let next = page["next_page_token"].string, !next.isEmpty { SyncNotes.cut("recorded meetings", read: page["meetings"].array.count) }
        return page["meetings"].array.compactMap { meeting -> ExternalRecording? in
            guard let uuid = meeting["uuid"].string ?? meeting["id"].string, let started = meeting["start_time"].date,
                  let topic = meeting["topic"].string, looksLikeInterview(topic) else { return nil }
            let files = meeting["recording_files"].array.compactMap { file -> ExternalFile? in
                guard let url = file["download_url"].url, file["status"].string != "processing" else { return nil }
                let kind: ExternalFile.Kind
                switch file["file_type"].string {
                case "M4A": kind = .audio
                case "MP4": kind = .video
                case "TRANSCRIPT": kind = .transcript
                default: return nil
                }
                let ext = file["file_extension"].string?.lowercased() ?? (kind == .transcript ? "vtt" : "m4a")
                return ExternalFile(kind: kind, filename: "\(topic).\(ext)", url: url, needsAuth: true)
            }
            guard !files.isEmpty else { return nil }
            // The meeting number links the recording to its scheduled interview.
            return ExternalRecording(source: .zoom, externalID: uuid, title: topic, startedAt: started,
                                     duration: meeting["duration"].double.map { $0 * 60 },
                                     meetingURL: meeting["id"].string.flatMap { URL(string: "https://zoom.us/j/\($0)") }, files: files)
        }
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: try await client(), transport: transport)
    }
}

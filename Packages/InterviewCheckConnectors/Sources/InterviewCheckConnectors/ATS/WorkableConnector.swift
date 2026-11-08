import Foundation

/// Workable: per-account subdomain, Bearer account token.
public struct WorkableConnector: InterviewSource, JobSource, CandidateSource, NoteDestination {
    public let kind = ConnectorKind.workable
    let api: APIClient
    private let subdomain: String
    private let memberID: String?

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        let raw = try credentials.required("subdomain", "account subdomain").lowercased()
        // Accept "acme", "acme.workable.com" or a pasted URL.
        subdomain = raw.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .components(separatedBy: ".").first ?? raw
        let token = try credentials.required("apiKey", "API access token")
        memberID = credentials["memberID"]
        api = APIClient(baseURL: URL(string: "https://\(subdomain).workable.com/spi/v3")!,
                        headers: ["Authorization": "Bearer \(token)"], transport: transport)
    }

    public func verify() async throws -> String {
        _ = try await api.get("jobs", query: [URLQueryItem(name: "limit", value: "1")])
        return "\(subdomain).workable.com"
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        var query = [URLQueryItem(name: "type", value: "interview"),
                     URLQueryItem(name: "start_date", value: DateParsing.iso(start)),
                     URLQueryItem(name: "end_date", value: DateParsing.iso(end)),
                     URLQueryItem(name: "limit", value: "100")]
        if let memberID { query.append(URLQueryItem(name: "member_id", value: memberID)) }
        var events: [JSONValue] = []
        var page = try await api.getJSON("events", query: query)
        for _ in 0..<20 {
            events += page["events"].array
            guard let next = page.at("paging.next").url else { break }
            page = try JSONValue.parse(try await api.send(method: "GET", url: next, body: nil).0)
        }
        return events.compactMap { event in
            guard let id = event["id"].string, let startsAt = event["starts_at"].date, event["cancelled"].bool != true else { return nil }
            let jobKey = event.at("job.shortcode").string ?? event.at("job.id").string
            return ExternalInterview(
                source: .workable, externalID: id, title: event["title"].string ?? "Interview", startsAt: startsAt,
                endsAt: event["ends_at"].date,
                meetingURL: event.at("conference.url").url ?? MeetingLinks.first(in: [event["description"].string]),
                candidate: event.at("candidate.name").string.map {
                    ExternalCandidate(externalID: event.at("candidate.id").string, name: $0)
                },
                job: jobKey.map { ExternalJob(externalID: $0, title: event.at("job.title").string ?? "Job") },
                applicationID: event.at("candidate.id").string,
                interviewers: event["members"].array.compactMap { $0["name"].string.map { ExternalPerson(name: $0) } }
            )
        }
    }

    public func job(id: String) async throws -> ExternalJob {
        let job = try await api.getJSON("jobs/\(id)")
        let html = job["full_description"].string
            ?? [job["description"].string, job["requirements"].string, job["benefits"].string].compactMap { $0 }.joined()
        return ExternalJob(externalID: id, title: job["title"].string ?? "Job", description: HTMLText.plain(html))
    }

    public func candidate(id: String) async throws -> ExternalCandidate {
        let json = try await api.getJSON("candidates/\(id)")["candidate"]
        var candidate = ExternalCandidate(externalID: id, name: json["name"].string ?? "Candidate", email: json["email"].string,
                                          profileURL: json["profile_url"].url)
        if let url = json["resume_url"].url {
            candidate.resume = ExternalFile(kind: .resume, filename: "\(candidate.name) resume", url: url, needsAuth: false)
        }
        return candidate
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: file.needsAuth ? api : nil, transport: api.transport)
    }

    public func addNote(_ text: String, to interview: ExternalInterview) async throws {
        guard let memberID else { throw ConnectorError.missingCredential("your Workable member ID (Connections \u{203A} Workable)") }
        guard let candidateID = interview.candidate?.externalID ?? interview.applicationID else {
            throw ConnectorError.unsupported("This interview has no Workable candidate to attach the comment to.")
        }
        _ = try await api.postJSON("candidates/\(candidateID)/comments", body: [
            "member_id": .string(memberID),
            "comment": ["body": .string(text), "policy": ["admin"]],
        ])
    }
}

extension WorkableConnector: CandidateLookup {
    public func findCandidate(email: String) async throws -> CandidateMatch? {
        guard let json = try await api.getJSON("candidates", query: [URLQueryItem(name: "email", value: email)])["candidates"][0].asObject,
              let id = json["id"].string else { return nil }
        return CandidateMatch(candidate: ExternalCandidate(externalID: id, name: json["name"].string ?? "Candidate", email: email),
                              job: json.at("job.shortcode").string.map { ExternalJob(externalID: $0, title: json.at("job.title").string ?? "Job") },
                              applicationID: id)
    }
}

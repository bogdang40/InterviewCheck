import Foundation

/// Greenhouse Harvest API v3 (v1/v2 were retired on 31 Aug 2026). Custom
/// integration credentials: Client ID + Secret, client-credentials tokens.
public struct GreenhouseConnector: InterviewSource, JobSource, CandidateSource, NoteDestination {
    public let kind = ConnectorKind.greenhouse
    static let base = URL(string: "https://harvest.greenhouse.io/v3")!
    static let tokenURL = URL(string: "https://auth.greenhouse.io/token")!

    private let token: ClientCredentialsToken
    private let transport: HTTPTransport
    private let userID: String?

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        let clientID = try credentials.required("clientID", "Client ID")
        let secret = try credentials.required("clientSecret", "Client secret")
        userID = credentials["userID"]
        token = ClientCredentialsToken(tokenURL: Self.tokenURL, clientID: clientID, clientSecret: secret,
                                       extraFields: userID.map { ["sub": $0] } ?? [:], transport: transport)
        self.transport = transport
    }

    private func client() async throws -> APIClient {
        APIClient(baseURL: Self.base, headers: ["Authorization": "Bearer \(try await token.accessToken())"], transport: transport)
    }

    public func verify() async throws -> String {
        _ = try await client().get("jobs", query: [URLQueryItem(name: "per_page", value: "1")])
        return "Greenhouse (Harvest v3)"
    }

    /// Every page of a list endpoint (cursor in the Link header).
    func list(_ path: String, _ query: [URLQueryItem], maxPages: Int = 20) async throws -> [JSONValue] {
        let api = try await client()
        var items: [JSONValue] = []
        var (data, response) = try await api.get(path, query: query)
        for _ in 0..<maxPages {
            items += try JSONValue.parse(data).array
            guard let next = APIClient.nextLink(response) else { break }
            (data, response) = try await api.send(method: "GET", url: next, body: nil)
        }
        return items
    }

    /// Looks records up by id, 50 at a time (v3 has no read-by-id routes).
    func byIDs(_ path: String, key: String = "ids", _ ids: [String]) async throws -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for chunk in Set(ids).sorted().chunked(50) where !chunk.isEmpty {
            for item in try await list(path, [URLQueryItem(name: key, value: chunk.joined(separator: ",")),
                                              URLQueryItem(name: "per_page", value: "500")]) {
                if let id = item["id"].string { result[id] = item }
            }
        }
        return result
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        let interviews = try await list("interviews", [
            URLQueryItem(name: "status", value: "scheduled"),
            URLQueryItem(name: "starts_at[gte]", value: DateParsing.iso(start)),
            URLQueryItem(name: "starts_at[lte]", value: DateParsing.iso(end)),
            URLQueryItem(name: "per_page", value: "500"),
        ])
        guard !interviews.isEmpty else { return [] }
        let applications = try await byIDs("applications", interviews.compactMap { $0["application_id"].string })
        let candidates = try await byIDs("candidates", applications.values.compactMap { $0["candidate_id"].string })
        let jobs = try await byIDs("jobs", interviews.compactMap { $0["job_id"].string })
        var interviewers: [String: [ExternalPerson]] = [:]
        for chunk in interviews.compactMap({ $0["id"].string }).chunked(50) {
            for row in try await list("interviewers", [URLQueryItem(name: "interview_ids", value: chunk.joined(separator: ","))]) {
                guard let id = row["interview_id"].string, let email = row["email"].string else { continue }
                interviewers[id, default: []].append(ExternalPerson(name: email, email: email))
            }
        }
        return interviews.compactMap { item -> ExternalInterview? in
            guard let id = item["id"].string, let startsAt = item["starts_at"].date else { return nil }
            let application = item["application_id"].string.flatMap { applications[$0] }
            let candidate = application?["candidate_id"].string.flatMap { candidates[$0] }
            let job = item["job_id"].string.flatMap { jobID in jobs[jobID].map { (jobID, $0) } }
            return ExternalInterview(
                source: .greenhouse, externalID: id, title: "Interview", startsAt: startsAt, endsAt: item["ends_at"].date,
                meetingURL: item["video_conferencing_url"].url ?? MeetingLinks.first(in: [item["location"].string]),
                candidate: candidate.map(Self.candidate),
                job: job.map { ExternalJob(externalID: $0.0, title: $0.1["name"].string ?? "Job") },
                applicationID: item["application_id"].string,
                interviewers: interviewers[id] ?? []
            )
        }
    }

    static func candidate(_ json: JSONValue) -> ExternalCandidate {
        let first = json["preferred_name"].string ?? json["first_name"].string ?? ""
        let name = [first, json["last_name"].string ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return ExternalCandidate(externalID: json["id"].string, name: name.isEmpty ? "Candidate" : name,
                                 email: json["email_addresses"][0]["value"].string,
                                 profileURL: json["id"].string.flatMap { URL(string: "https://app.greenhouse.io/people/\($0)") })
    }

    public func job(id: String) async throws -> ExternalJob {
        guard let job = try await byIDs("jobs", [id])[id] else { throw ConnectorError.notFound }
        let posts = try await list("job_posts", [URLQueryItem(name: "job_ids", value: id)])
        let post = posts.first { $0["internal"].bool == false && $0["live"].bool == true }
            ?? posts.first { $0["internal"].bool == false } ?? posts.first
        return ExternalJob(externalID: id, title: post?["title"].string ?? job["name"].string ?? "Job",
                           description: post?["content"].string.map(HTMLText.plain) ?? "")
    }

    public func candidate(id: String) async throws -> ExternalCandidate {
        guard let json = try await byIDs("candidates", [id])[id] else { throw ConnectorError.notFound }
        var candidate = Self.candidate(json)
        let attachments = try await list("attachments", [URLQueryItem(name: "candidate_ids", value: id),
                                                         URLQueryItem(name: "type", value: "resume")])
        if let resume = attachments.first, let url = resume["url"].url {
            candidate.resume = ExternalFile(kind: .resume, filename: resume["filename"].string ?? "resume", url: url, needsAuth: false)
        }
        return candidate
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: file.needsAuth ? try await client() : nil, transport: transport)
    }

    public func addNote(_ text: String, to interview: ExternalInterview) async throws {
        guard let candidateID = interview.candidate?.externalID.flatMap(Double.init) else {
            throw ConnectorError.unsupported("This interview has no Greenhouse candidate to attach the note to.")
        }
        var body: [String: JSONValue] = ["candidate_id": .number(candidateID), "note_type": "NOTE",
                                         "visibility": "private", "body": .string(text)]
        if let application = interview.applicationID.flatMap(Double.init) { body["application_id"] = .number(application) }
        if let user = userID.flatMap(Double.init) { body["user_id"] = .number(user) }
        _ = try await client().postJSON("notes", body: .object(body))
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

extension GreenhouseConnector: CandidateLookup {
    public func findCandidate(email: String) async throws -> CandidateMatch? {
        guard let json = try await list("candidates", [URLQueryItem(name: "email", value: email)], maxPages: 1).first,
              let id = json["id"].string else { return nil }
        let application = try await list("applications", [URLQueryItem(name: "candidate_ids", value: id)], maxPages: 1)
            .first { $0["job_id"].string != nil }
        let jobID = application?["job_id"].string
        var jobName: String?
        if let jobID { jobName = try await byIDs("jobs", [jobID])[jobID]?["name"].string }
        return CandidateMatch(candidate: Self.candidate(json),
                              job: jobID.map { ExternalJob(externalID: $0, title: jobName ?? "Job") },
                              applicationID: application?["id"].string)
    }
}

extension GreenhouseConnector: JobListing {
    public func openJobs() async throws -> [ExternalJob] {
        try await list("jobs", [URLQueryItem(name: "status", value: "open"), URLQueryItem(name: "per_page", value: "500")], maxPages: 4)
            .compactMap { job in job["id"].string.map { ExternalJob(externalID: $0, title: job["name"].string ?? "Job") } }
    }
}

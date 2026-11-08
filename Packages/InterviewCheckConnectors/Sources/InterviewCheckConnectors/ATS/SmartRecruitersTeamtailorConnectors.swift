import Foundation

/// SmartRecruiters: API key (X-SmartToken) or OAuth client credentials.
/// Interviews are per application, so candidates in the Interview status are
/// read first (one candidates call at a time, as SmartRecruiters requires).
public struct SmartRecruitersConnector: InterviewSource, JobSource, CandidateSource, NoteDestination {
    public let kind = ConnectorKind.smartRecruiters
    private let transport: HTTPTransport
    private let apiKey: String?
    private let token: ClientCredentialsToken?
    static let base = URL(string: "https://api.smartrecruiters.com")!

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        self.transport = transport
        apiKey = credentials["apiKey"]
        if let id = credentials["clientID"], let secret = credentials["clientSecret"] {
            token = ClientCredentialsToken(tokenURL: URL(string: "https://api.smartrecruiters.com/identity/oauth/token")!,
                                           clientID: id, clientSecret: secret, basicAuth: false, transport: transport)
        } else {
            token = nil
            guard apiKey != nil else { throw ConnectorError.missingCredential("API key, or client ID and secret") }
        }
    }

    func client() async throws -> APIClient {
        if let token { return APIClient(baseURL: Self.base, headers: ["Authorization": "Bearer \(try await token.accessToken())"], transport: transport) }
        return APIClient(baseURL: Self.base, headers: ["X-SmartToken": apiKey ?? ""], transport: transport)
    }

    public func verify() async throws -> String {
        _ = try await client().get("jobs", query: [URLQueryItem(name: "limit", value: "1")])
        return "SmartRecruiters"
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        let api = try await client()
        let candidates = try await api.getJSON("candidates", query: [
            URLQueryItem(name: "status", value: "INTERVIEW"), URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "updatedAfter", value: DateParsing.iso(start.addingTimeInterval(-60 * 86_400))),
        ])["content"].array
        var result: [ExternalInterview] = []
        for candidate in candidates.prefix(100) {
            guard let candidateID = candidate["id"].string,
                  let jobID = candidate.at("primaryAssignment.job.id").string else { continue }
            let assignment = try? await api.getJSON("candidates/\(candidateID)/jobs/\(jobID)")
            guard let applicationID = assignment?["applicationId"].string ?? assignment?["id"].string else { continue }
            let interviews = (try? await api.getJSON("interviews-api/v201904/interviews",
                                                     query: [URLQueryItem(name: "applicationId", value: applicationID)]))?["content"].array ?? []
            let name = [candidate["firstName"].string, candidate["lastName"].string].compactMap { $0 }.joined(separator: " ")
            for interview in interviews {
                for slot in interview["timeslots"].array {
                    guard let startsAt = slot["startsOn"].date, startsAt >= start, startsAt <= end,
                          let id = slot["id"].string ?? interview["id"].string else { continue }
                    result.append(ExternalInterview(
                        source: .smartRecruiters, externalID: id, title: slot["title"].string ?? "Interview", startsAt: startsAt,
                        endsAt: slot["endsOn"].date,
                        meetingURL: MeetingLinks.first(in: [slot["place"].string, interview["location"].string]),
                        candidate: ExternalCandidate(externalID: candidateID, name: name.isEmpty ? "Candidate" : name,
                                                     email: candidate["email"].string),
                        job: ExternalJob(externalID: jobID, title: candidate.at("primaryAssignment.job.title").string ?? "Job"),
                        applicationID: applicationID
                    ))
                }
            }
        }
        return result
    }

    public func job(id: String) async throws -> ExternalJob {
        let job = try await client().getJSON("jobs/\(id)")
        let sections = ["companyDescription", "jobDescription", "qualifications", "additionalInformation"].compactMap { key -> String? in
            let section = job.at("jobAd.sections.\(key)")
            guard let text = section["text"].string else { return nil }
            return "<h3>\(section["title"].string ?? "")</h3>\(text)"
        }
        return ExternalJob(externalID: id, title: job["title"].string ?? "Job", description: HTMLText.plain(sections.joined()))
    }

    public func candidate(id: String) async throws -> ExternalCandidate {
        let api = try await client()
        let json = try await api.getJSON("candidates/\(id)")
        let name = [json["firstName"].string, json["lastName"].string].compactMap { $0 }.joined(separator: " ")
        var candidate = ExternalCandidate(externalID: id, name: name.isEmpty ? "Candidate" : name, email: json["email"].string)
        let files = (try? await api.getJSON("candidates/\(id)/attachments"))?["content"].array ?? []
        if let resume = files.first(where: { ($0["type"].string ?? "").uppercased().contains("RESUME") }) ?? files.first,
           let url = resume.at("actions.download.url").url {
            candidate.resume = ExternalFile(kind: .resume, filename: resume["name"].string ?? "resume", url: url, needsAuth: true)
        }
        return candidate
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: file.needsAuth ? try await client() : nil, transport: transport)
    }

    /// SmartRecruiters has no private notes: the message is shared with no one
    /// beyond its author and admins.
    public func addNote(_ text: String, to interview: ExternalInterview) async throws {
        guard let candidate = interview.candidate?.externalID else {
            throw ConnectorError.unsupported("This interview has no SmartRecruiters candidate to attach the note to.")
        }
        _ = try await client().postJSON("messages/shares", body: [
            "content": .string("\(text)\n#[CANDIDATE:\(candidate)]"),
            "shareWith": ["users": [], "hiringTeamOf": [], "everyone": false, "openNote": false],
        ])
    }
}

/// Teamtailor: no interview schedule in its API, so it brings job ads,
/// candidates and résumés (found by email from a calendar invite) and notes.
public struct TeamtailorConnector: JobSource, CandidateSource, NoteDestination {
    public let kind = ConnectorKind.teamtailor
    let api: APIClient
    private let userID: String?

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        let key = try credentials.required("apiKey", "API key")
        let host = credentials["region"]?.lowercased() == "na" ? "api.na.teamtailor.com" : "api.teamtailor.com"
        userID = credentials["userID"]
        api = APIClient(baseURL: URL(string: "https://\(host)/v1")!,
                        headers: ["Authorization": "Token token=\(key)", "X-Api-Version": "20240904"], transport: transport)
    }

    public func verify() async throws -> String {
        _ = try await api.get("jobs", query: [URLQueryItem(name: "page[size]", value: "1")])
        return "Teamtailor"
    }

    public func job(id: String) async throws -> ExternalJob {
        let job = try await api.getJSON("jobs/\(id)")["data"]
        return ExternalJob(externalID: id, title: job.at("attributes.title").string ?? "Job",
                           description: job.at("attributes.body").string.map(HTMLText.plain) ?? "")
    }

    public func candidate(id: String) async throws -> ExternalCandidate {
        Self.candidate(try await api.getJSON("candidates/\(id)")["data"])
    }

    static func candidate(_ json: JSONValue) -> ExternalCandidate {
        let attributes = json["attributes"]
        let name = [attributes["first-name"].string, attributes["last-name"].string].compactMap { $0 }.joined(separator: " ")
        return ExternalCandidate(externalID: json["id"].string, name: name.isEmpty ? "Candidate" : name,
                                 email: attributes["email"].string,
                                 resume: (attributes["original-resume"].url ?? attributes["resume"].url).map {
                                     ExternalFile(kind: .resume, filename: "\(name) resume", url: $0, needsAuth: false)
                                 })
    }

    /// Résumé links last about 30 seconds: fetch the candidate again first.
    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: nil, transport: api.transport)
    }

    public func addNote(_ text: String, to interview: ExternalInterview) async throws {
        guard let userID else { throw ConnectorError.missingCredential("your Teamtailor user ID (Connections \u{203A} Teamtailor)") }
        guard let candidate = interview.candidate?.externalID else {
            throw ConnectorError.unsupported("This interview has no Teamtailor candidate to attach the note to.")
        }
        _ = try await api.postJSON("notes", body: ["data": [
            "type": "notes", "attributes": ["note": .string(text)],
            "relationships": ["candidate": ["data": ["id": .string(candidate), "type": "candidates"]],
                              "user": ["data": ["id": .string(userID), "type": "users"]]],
        ]], contentType: "application/vnd.api+json")
    }
}

extension TeamtailorConnector: CandidateLookup {
    public func findCandidate(email: String) async throws -> CandidateMatch? {
        guard let json = try await api.getJSON("candidates", query: [URLQueryItem(name: "filter[email]", value: email)])["data"][0].asObject
        else { return nil }
        return CandidateMatch(candidate: Self.candidate(json))
    }
}

extension SmartRecruitersConnector: CandidateLookup {
    public func findCandidate(email: String) async throws -> CandidateMatch? {
        guard let json = try await client().getJSON("candidates", query: [URLQueryItem(name: "q", value: email),
                                                                         URLQueryItem(name: "limit", value: "5")])["content"].array
            .first(where: { $0["email"].string?.lowercased() == email.lowercased() })?.asObject,
              let id = json["id"].string else { return nil }
        let name = [json["firstName"].string, json["lastName"].string].compactMap { $0 }.joined(separator: " ")
        return CandidateMatch(candidate: ExternalCandidate(externalID: id, name: name.isEmpty ? "Candidate" : name, email: email),
                              job: json.at("primaryAssignment.job.id").string.map {
                                  ExternalJob(externalID: $0, title: json.at("primaryAssignment.job.title").string ?? "Job")
                              })
    }
}

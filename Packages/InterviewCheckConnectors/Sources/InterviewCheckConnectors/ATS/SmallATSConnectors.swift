import Foundation

/// BambooHR Hiring: no interviews or job descriptions in its API; brings
/// applicants and résumés (found by email from a calendar invite) and comments.
public struct BambooHRConnector: JobSource, CandidateSource, NoteDestination {
    public let kind = ConnectorKind.bambooHR
    let api: APIClient
    private let subdomain: String

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        subdomain = try credentials.required("subdomain", "company subdomain").lowercased()
            .replacingOccurrences(of: ".bamboohr.com", with: "").replacingOccurrences(of: "https://", with: "")
        let key = try credentials.required("apiKey", "API key")
        api = APIClient(baseURL: URL(string: "https://\(subdomain).bamboohr.com/api/v1")!,
                        headers: ["Authorization": APIClient.basic(key, "x")], transport: transport)
    }

    public func verify() async throws -> String {
        _ = try await api.get("applicant_tracking/jobs")
        return "\(subdomain).bamboohr.com"
    }

    public func job(id: String) async throws -> ExternalJob {
        let jobs = try await api.getJSON("applicant_tracking/jobs")
        let job = (jobs.array.isEmpty ? jobs["jobs"].array : jobs.array).first { $0["id"].string == id }
        return ExternalJob(externalID: id, title: job?.at("title.label").string ?? "Job")
    }

    /// `id` is the application id.
    public func candidate(id: String) async throws -> ExternalCandidate {
        let application = try await api.getJSON("applicant_tracking/applications/\(id)")
        let applicant = application["applicant"]
        let name = [applicant["firstName"].string, applicant["lastName"].string].compactMap { $0 }.joined(separator: " ")
        var candidate = ExternalCandidate(externalID: id, name: name.isEmpty ? "Candidate" : name, email: applicant["email"].string)
        if let file = application["resumeFileId"].string {
            candidate.resume = ExternalFile(kind: .resume, filename: "\(name) resume", url: api.url("files/\(file)"), needsAuth: true)
        } else if let url = application["attachments"][0]["fileUrl"].url {
            candidate.resume = ExternalFile(kind: .resume, filename: application["attachments"][0]["name"].string ?? "resume",
                                            url: url, needsAuth: true)
        }
        return candidate
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: api, transport: api.transport)
    }

    public func addNote(_ text: String, to interview: ExternalInterview) async throws {
        guard let application = interview.applicationID ?? interview.candidate?.externalID else {
            throw ConnectorError.unsupported("This interview has no BambooHR application to comment on.")
        }
        _ = try await api.postJSON("applicant_tracking/applications/\(application)/comments",
                                   body: ["type": "comment", "comment": .string(text)])
    }
}

/// JazzHR: key as an `apikey` query parameter; jobs, applicants, private notes.
public struct JazzHRConnector: JobSource, CandidateSource, NoteDestination {
    public let kind = ConnectorKind.jazzHR
    let api: APIClient
    private let key: String
    private let userID: String?

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        key = try credentials.required("apiKey", "API key")
        userID = credentials["userID"]
        api = APIClient(baseURL: URL(string: "https://api.resumatorapi.com/v1")!, transport: transport)
    }

    private var auth: [URLQueryItem] { [URLQueryItem(name: "apikey", value: key)] }

    public func verify() async throws -> String {
        _ = try await api.get("jobs", query: auth)
        return "JazzHR"
    }

    public func job(id: String) async throws -> ExternalJob {
        let job = try await api.getJSON("jobs/\(id)", query: auth)
        return ExternalJob(externalID: id, title: job["title"].string ?? "Job",
                           description: job["description"].string.map(HTMLText.plain) ?? "")
    }

    public func candidate(id: String) async throws -> ExternalCandidate {
        let applicant = try await api.getJSON("applicants/\(id)", query: auth)
        let name = [applicant["first_name"].string, applicant["last_name"].string].compactMap { $0 }.joined(separator: " ")
        return ExternalCandidate(externalID: id, name: name.isEmpty ? "Candidate" : name, email: applicant["email"].string,
                                 resume: applicant["resume_link"].url.map {
                                     ExternalFile(kind: .resume, filename: "\(name) resume", url: $0, needsAuth: false)
                                 })
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: nil, transport: api.transport)
    }

    /// `security: 30` = only the author can see it.
    public func addNote(_ text: String, to interview: ExternalInterview) async throws {
        guard let applicant = interview.candidate?.externalID else {
            throw ConnectorError.unsupported("This interview has no JazzHR applicant to attach the note to.")
        }
        var body: [String: JSONValue] = ["apikey": .string(key), "applicant_id": .string(applicant), "contents": .string(text),
                                         "security": "30"]
        if let userID { body["user_id"] = .string(userID) }
        _ = try await api.postJSON("notes", body: .object(body))
    }
}

/// Breezy HR: personal access token; candidates live under positions, so a
/// candidate id here is "positionID/candidateID".
public struct BreezyConnector: JobSource, CandidateSource, NoteDestination {
    public let kind = ConnectorKind.breezyHR
    let api: APIClient
    private let companyID: String?

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        let token = try credentials.required("apiKey", "personal access token")
        companyID = credentials["companyID"]
        api = APIClient(baseURL: URL(string: "https://api.breezy.hr/v3")!,
                        headers: ["Authorization": token.hasPrefix("Bearer ") ? token : "Bearer \(token)"], transport: transport)
    }

    func company() async throws -> String {
        if let companyID { return companyID }
        guard let id = try await api.getJSON("companies")[0]["_id"].string else { throw ConnectorError.notFound }
        return id
    }

    public func verify() async throws -> String {
        let companies = try await api.getJSON("companies")
        return companies[0]["name"].string ?? "Breezy HR"
    }

    public func job(id: String) async throws -> ExternalJob {
        let position = try await api.getJSON("company/\(try await company())/position/\(id)")
        return ExternalJob(externalID: id, title: position["name"].string ?? "Job",
                           description: position["description"].string.map(HTMLText.plain) ?? "")
    }

    public func candidate(id: String) async throws -> ExternalCandidate {
        let parts = id.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw ConnectorError.notFound }
        let path = "company/\(try await company())/position/\(parts[0])/candidate/\(parts[1])"
        let json = try await api.getJSON(path)
        return ExternalCandidate(externalID: id, name: json["name"].string ?? "Candidate", email: json["email_address"].string,
                                 resume: json["resume"].isNull ? nil : ExternalFile(
                                     kind: .resume, filename: json.at("resume.file_name").string ?? "resume",
                                     url: api.url("\(path)/resume"), needsAuth: true))
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: api, transport: api.transport)
    }

    /// A team note: internal, never shown to the candidate (Breezy has no private flag).
    public func addNote(_ text: String, to interview: ExternalInterview) async throws {
        let parts = (interview.candidate?.externalID ?? "").split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw ConnectorError.unsupported("This interview has no Breezy candidate to note on.") }
        _ = try await api.postJSON("company/\(try await company())/position/\(parts[0])/candidate/\(parts[1])/stream",
                                   body: ["body": .string(text)])
    }
}

/// Personio Recruiting v2: candidates and jobs by name (no interviews,
/// résumés, descriptions or notes in its API).
public struct PersonioConnector: JobSource, CandidateSource {
    public let kind = ConnectorKind.personio
    let token: ClientCredentialsToken
    let transport: HTTPTransport

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        token = ClientCredentialsToken(tokenURL: URL(string: "https://api.personio.de/v2/auth/token")!,
                                       clientID: try credentials.required("clientID", "client ID"),
                                       clientSecret: try credentials.required("clientSecret", "client secret"),
                                       extraFields: ["scope": "personio:recruiting:read"], basicAuth: false, transport: transport)
        self.transport = transport
    }

    func client() async throws -> APIClient {
        APIClient(baseURL: URL(string: "https://api.personio.de/v2/recruiting")!,
                  headers: ["Authorization": "Bearer \(try await token.accessToken())"], transport: transport)
    }

    public func verify() async throws -> String {
        _ = try await client().get("jobs", query: [URLQueryItem(name: "limit", value: "1")])
        return "Personio"
    }

    public func job(id: String) async throws -> ExternalJob {
        let job = try await client().getJSON("jobs/\(id)")
        return ExternalJob(externalID: id, title: job["name"].string ?? "Job")
    }

    public func candidate(id: String) async throws -> ExternalCandidate {
        let json = try await client().getJSON("candidates/\(id)")
        let name = [json["first_name"].string, json["last_name"].string].compactMap { $0 }.joined(separator: " ")
        return ExternalCandidate(externalID: id, name: name.isEmpty ? "Candidate" : name, email: json["email"].string)
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        throw ConnectorError.unsupported("Personio's API has no r\u{00E9}sum\u{00E9} download.")
    }
}

extension BambooHRConnector: CandidateLookup {
    public func findCandidate(email: String) async throws -> CandidateMatch? {
        let page = try await api.getJSON("applicant_tracking/applications", query: [URLQueryItem(name: "searchString", value: email)])
        guard let application = page["applications"].array.first(where: {
            $0.at("applicant.email").string?.lowercased() == email.lowercased()
        }), let id = application["id"].string else { return nil }
        let name = [application.at("applicant.firstName").string, application.at("applicant.lastName").string]
            .compactMap { $0 }.joined(separator: " ")
        return CandidateMatch(candidate: ExternalCandidate(externalID: id, name: name.isEmpty ? "Candidate" : name, email: email),
                              job: application.at("job.id").string.map {
                                  ExternalJob(externalID: $0, title: application.at("job.title.label").string ?? "Job")
                              },
                              applicationID: id)
    }
}

extension PersonioConnector: CandidateLookup {
    public func findCandidate(email: String) async throws -> CandidateMatch? {
        guard let application = try await client().getJSON("applications", query: [URLQueryItem(name: "candidate.email", value: email)])["_data"][0].asObject,
              let candidateID = application.at("candidate.id").string else { return nil }
        let name = [application.at("candidate.first_name").string, application.at("candidate.last_name").string]
            .compactMap { $0 }.joined(separator: " ")
        return CandidateMatch(candidate: ExternalCandidate(externalID: candidateID, name: name.isEmpty ? "Candidate" : name, email: email),
                              job: application.at("job.id").string.map { ExternalJob(externalID: $0, title: application.at("job.name").string ?? "Job") },
                              applicationID: application["id"].string)
    }
}

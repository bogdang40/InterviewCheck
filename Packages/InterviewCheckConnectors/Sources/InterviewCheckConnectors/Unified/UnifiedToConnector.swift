import Foundation

/// Unified.to: live calls through a workspace token, connection id in the
/// path, offset paging over plain arrays. Widest ATS coverage (iCIMS, Jobvite).
public struct UnifiedToConnector: InterviewSource, JobSource, CandidateSource, NoteDestination {
    public let kind = ConnectorKind.unifiedTo
    let api: APIClient
    private let connection: String

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        let key = try credentials.required("apiKey", "API token")
        connection = try credentials.required("connectionID", "connection ID")
        let host: String
        switch credentials["region"]?.lowercased() {
        case "eu": host = "api-eu.unified.to"
        case "au": host = "api-au.unified.to"
        default: host = "api.unified.to"
        }
        api = APIClient(baseURL: URL(string: "https://\(host)/ats/\(connection)")!,
                        headers: ["Authorization": "Bearer \(key)"], transport: transport)
    }

    public func verify() async throws -> String {
        _ = try await api.get("job", query: [URLQueryItem(name: "limit", value: "1")])
        return "Unified.to"
    }

    func list(_ path: String, _ query: [URLQueryItem] = [], maxPages: Int = 10) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        for page in 0..<maxPages {
            let rows = try await api.getJSON(path, query: query + [URLQueryItem(name: "limit", value: "100"),
                                                                   URLQueryItem(name: "offset", value: "\(page * 100)")]).array
            items += rows
            if rows.count < 100 { break }
        }
        return items
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        // Recently changed interviews first; not every ATS takes the filter.
        let since = [URLQueryItem(name: "updated_gte", value: DateParsing.iso(start.addingTimeInterval(-60 * 86_400)))]
        var all: [JSONValue]
        do { all = try await list("interview", since) } catch { all = try await list("interview") }
        let rows = all.filter { row in
            guard let startsAt = row["start_at"].date else { return false }
            return startsAt >= start && startsAt <= end && !["CANCELED", "COMPLETE"].contains(row["status"].string ?? "")
        }
        var candidates: [String: JSONValue] = [:]
        var jobs: [String: JSONValue] = [:]
        for id in Set(rows.compactMap { $0["candidate_id"].string }) { candidates[id] = try? await api.getJSON("candidate/\(id)") }
        for id in Set(rows.compactMap { $0["job_id"].string }) { jobs[id] = try? await api.getJSON("job/\(id)") }
        return rows.compactMap { row in
            guard let id = row["id"].string, let startsAt = row["start_at"].date else { return nil }
            let candidate = row["candidate_id"].string.flatMap { candidates[$0] }
            let jobID = row["job_id"].string
            return ExternalInterview(
                source: .unifiedTo, externalID: id, title: "Interview", startsAt: startsAt, endsAt: row["end_at"].date,
                meetingURL: row["meeting_url"].url ?? MeetingLinks.first(in: [row["location"].string]),
                candidate: candidate.map(Self.candidate),
                job: jobID.map { ExternalJob(externalID: $0, title: jobs[$0]?["name"].string ?? "Job") },
                applicationID: row["application_id"].string
            )
        }
    }

    static func candidate(_ json: JSONValue) -> ExternalCandidate {
        let name = json["name"].string
            ?? [json["first_name"].string, json["last_name"].string].compactMap { $0 }.joined(separator: " ")
        return ExternalCandidate(externalID: json["id"].string, name: name.isEmpty ? "Candidate" : name,
                                 email: json["emails"][0]["email"].string)
    }

    public func job(id: String) async throws -> ExternalJob {
        let job = try await api.getJSON("job/\(id)")
        return ExternalJob(externalID: id, title: job["name"].string ?? "Job",
                           description: job["description"].string.map(HTMLText.plain) ?? "")
    }

    public func candidate(id: String) async throws -> ExternalCandidate {
        var candidate = Self.candidate(try await api.getJSON("candidate/\(id)"))
        let documents = try await api.getJSON("document", query: [URLQueryItem(name: "candidate_id", value: id),
                                                                  URLQueryItem(name: "type", value: "RESUME")]).array
        if let resume = documents.first, let url = resume["document_url"].url {
            candidate.resume = ExternalFile(kind: .resume, filename: resume["filename"].string ?? "resume", url: url, needsAuth: false)
        }
        return candidate
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: nil, transport: api.transport)
    }

    public func addNote(_ text: String, to interview: ExternalInterview) async throws {
        var body: [String: JSONValue] = ["type": "NOTE", "title": "InterviewCheck", "description": .string(text), "is_private": true]
        if let candidate = interview.candidate?.externalID { body["candidate_id"] = .string(candidate) }
        if let application = interview.applicationID { body["application_id"] = .string(application) }
        guard body["candidate_id"] != nil || body["application_id"] != nil else {
            throw ConnectorError.unsupported("This interview has no candidate or application to attach the note to.")
        }
        _ = try await api.postJSON("activity", body: .object(body))
    }
}

/// Apideck: jobs and applicants only (no interviews or notes in its ATS API).
public struct ApideckConnector: JobSource, CandidateSource {
    public let kind = ConnectorKind.apideck
    let api: APIClient

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        var headers = ["Authorization": "Bearer \(try credentials.required("apiKey", "API key"))",
                       "x-apideck-app-id": try credentials.required("appID", "app ID"),
                       "x-apideck-consumer-id": try credentials.required("consumerID", "consumer ID")]
        if let service = credentials["serviceID"] { headers["x-apideck-service-id"] = service }
        api = APIClient(baseURL: URL(string: "https://unify.apideck.com/ats")!, headers: headers, transport: transport)
    }

    public func verify() async throws -> String {
        let response = try await api.getJSON("jobs", query: [URLQueryItem(name: "limit", value: "1")])
        return "Apideck \u{00B7} \(response["service"].string ?? "ATS")"
    }

    public func job(id: String) async throws -> ExternalJob {
        let job = try await api.getJSON("jobs/\(id)")["data"]
        return ExternalJob(externalID: id, title: job["title"].string ?? "Job",
                           description: job["description_html"].string.map(HTMLText.plain) ?? job["description"].string ?? "")
    }

    public func candidate(id: String) async throws -> ExternalCandidate {
        let applicant = try await api.getJSON("applicants/\(id)")["data"]
        let name = applicant["name"].string
            ?? [applicant["first_name"].string, applicant["last_name"].string].compactMap { $0 }.joined(separator: " ")
        return ExternalCandidate(externalID: id, name: name.isEmpty ? "Candidate" : name, email: applicant["emails"][0]["email"].string,
                                 resume: applicant["cv_url"].url.map {
                                     ExternalFile(kind: .resume, filename: "\(name) CV", url: $0, needsAuth: false)
                                 })
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: nil, transport: api.transport)
    }
}

extension UnifiedToConnector: CandidateLookup {
    public func findCandidate(email: String) async throws -> CandidateMatch? {
        guard let json = try await api.getJSON("candidate", query: [URLQueryItem(name: "query", value: email),
                                                                    URLQueryItem(name: "limit", value: "5")]).array
            .first(where: { $0["emails"].array.contains { $0["email"].string?.lowercased() == email.lowercased() } })?.asObject
        else { return nil }
        let jobID = json["job_ids"][0].string
        return CandidateMatch(candidate: Self.candidate(json), job: jobID.map { ExternalJob(externalID: $0, title: "Job") })
    }
}

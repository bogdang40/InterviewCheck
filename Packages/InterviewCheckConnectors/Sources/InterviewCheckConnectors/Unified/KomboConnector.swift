import Foundation

/// Kombo unified ATS API: Bearer key + X-Integration-Id. One interviews
/// call carries the candidate and job, so this is the cheapest to sync.
public struct KomboConnector: InterviewSource, JobSource, CandidateSource, NoteDestination {
    public let kind = ConnectorKind.kombo
    private let api: APIClient

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        let key = try credentials.required("apiKey", "API key")
        let integration = try credentials.required("integrationID", "integration ID")
        let host: String
        switch credentials["region"]?.lowercased() {
        case "us": host = "api.us.kombo.dev"
        case "ca": host = "api.ca.kombo.dev"
        default: host = "api.kombo.dev"
        }
        api = APIClient(baseURL: URL(string: "https://\(host)/v1")!,
                        headers: ["Authorization": "Bearer \(key)", "X-Integration-Id": integration], transport: transport)
    }

    public func verify() async throws -> String {
        _ = try await api.get("ats/jobs", query: [URLQueryItem(name: "page_size", value: "1")])
        return "Kombo"
    }

    func list(_ path: String, _ query: [URLQueryItem], maxPages: Int = 20) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        var cursor: String?
        for _ in 0..<maxPages {
            let page = try await api.getJSON(path, query: query + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []))
            items += page.at("data.results").array
            guard let next = page.at("data.next").string else { break }
            cursor = next
        }
        return items
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        try await list("ats/interviews", [
            URLQueryItem(name: "updated_after", value: DateParsing.iso(start.addingTimeInterval(-60 * 86_400))),
            URLQueryItem(name: "page_size", value: "250"),
        ]).compactMap { row in
            guard let id = row["id"].string, let startsAt = row["starting_at"].date, row["canceled"].bool != true,
                  row["remote_deleted_at"].isNull, startsAt >= start, startsAt <= end else { return nil }
            let application = row["application"]
            let candidate = application["candidate"]
            let name = [candidate["first_name"].string, candidate["last_name"].string].compactMap { $0 }.joined(separator: " ")
            return ExternalInterview(
                source: .kombo, externalID: id, title: row["title"].string ?? "Interview", startsAt: startsAt,
                endsAt: row["ending_at"].date,
                meetingURL: row["video_conferencing_url"].url ?? MeetingLinks.first(in: [row.at("location.raw").string]),
                candidate: name.isEmpty ? nil : ExternalCandidate(externalID: candidate["id"].string, name: name,
                                                                  email: candidate["email_addresses"][0]["email_address"].string),
                job: application.at("job.id").string.map { ExternalJob(externalID: $0, title: application.at("job.name").string ?? "Job") },
                applicationID: row["application_id"].string,
                interviewers: row["users"].array.map {
                    ExternalPerson(name: [$0["first_name"].string, $0["last_name"].string].compactMap { $0 }.joined(separator: " "),
                                   email: $0["email"].string)
                }
            )
        }
    }

    public func job(id: String) async throws -> ExternalJob {
        guard let job = try await list("ats/jobs", [URLQueryItem(name: "ids", value: id)], maxPages: 1).first else {
            throw ConnectorError.notFound
        }
        let html = job["description"].string ?? job["job_postings"][0]["description_html"].string ?? ""
        return ExternalJob(externalID: id, title: job["name"].string ?? "Job", description: HTMLText.plain(html))
    }

    public func candidate(id: String) async throws -> ExternalCandidate {
        guard let json = try await list("ats/candidates", [URLQueryItem(name: "ids", value: id)], maxPages: 1).first else {
            throw ConnectorError.notFound
        }
        let name = [json["first_name"].string, json["last_name"].string].compactMap { $0 }.joined(separator: " ")
        var candidate = ExternalCandidate(externalID: id, name: name.isEmpty ? "Candidate" : name,
                                          email: json["email_addresses"][0]["email_address"].string)
        let files = try await api.getJSON("ats/candidates/\(id)/attachments").at("data.results").array
        if let resume = files.first(where: { $0["type"].string == "CV" }), let url = resume["data_url"].url {
            candidate.resume = ExternalFile(kind: .resume, filename: resume["file_name"].string ?? "resume", url: url, needsAuth: false)
        }
        return candidate
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: nil, transport: api.transport)
    }

    public func addNote(_ text: String, to interview: ExternalInterview) async throws {
        guard let application = interview.applicationID else {
            throw ConnectorError.unsupported("Kombo notes attach to an application; this interview has none.")
        }
        _ = try await api.postJSON("ats/applications/\(application)/notes", body: [
            "title": "InterviewCheck", "content": .string(text), "content_type": "PLAIN_TEXT",
            "remote_fields": ["greenhousev3": ["visibility": "private"], "greenhouse": ["visibility": "private"]],
        ])
    }
}

extension KomboConnector: CandidateLookup {
    public func findCandidate(email: String) async throws -> CandidateMatch? {
        guard let json = try await list("ats/candidates", [URLQueryItem(name: "email", value: email)], maxPages: 1).first,
              let id = json["id"].string else { return nil }
        let name = [json["first_name"].string, json["last_name"].string].compactMap { $0 }.joined(separator: " ")
        let application = json["applications"].array.first { $0["outcome"].string == "PENDING" } ?? json["applications"][0].asObject
        return CandidateMatch(candidate: ExternalCandidate(externalID: id, name: name.isEmpty ? "Candidate" : name, email: email),
                              job: application?.at("job.id").string.map {
                                  ExternalJob(externalID: $0, title: application?.at("job.name").string ?? "Job")
                              },
                              applicationID: application?["id"].string)
    }
}

import Foundation

/// Merge unified ATS API: Bearer key + X-Account-Token per linked account.
/// Merge serves its own synced copy (daily on its entry plan).
public struct MergeConnector: InterviewSource, JobSource, CandidateSource, NoteDestination {
    public let kind = ConnectorKind.merge
    private let api: APIClient
    private let remoteUserID: String?

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        let key = try credentials.required("apiKey", "API key")
        let account = try credentials.required("accountToken", "linked account token")
        let host: String
        switch credentials["region"]?.lowercased() {
        case "eu": host = "api-eu.merge.dev"
        case "ap", "apac": host = "api-ap.merge.dev"
        default: host = "api.merge.dev"
        }
        remoteUserID = credentials["remoteUserID"]
        api = APIClient(baseURL: URL(string: "https://\(host)/api/ats/v1")!,
                        headers: ["Authorization": "Bearer \(key)", "X-Account-Token": account], transport: transport)
    }

    public func verify() async throws -> String {
        _ = try await api.get("jobs", query: [URLQueryItem(name: "page_size", value: "1")])
        return "Merge"
    }

    /// Follows `{next, results}` cursors.
    func list(_ path: String, _ query: [URLQueryItem], maxPages: Int = 20) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        var cursor: String?
        for _ in 0..<maxPages {
            let page = try await api.getJSON(path, query: query + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []))
            items += page["results"].array
            guard let next = page["next"].string else { break }
            cursor = next
        }
        return items
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        // No start-time filter in Merge: read recently synced interviews, filter here.
        let rows = try await list("interviews", [
            URLQueryItem(name: "modified_after", value: DateParsing.iso(start.addingTimeInterval(-60 * 86_400))),
            URLQueryItem(name: "expand", value: "application,interviewers"),
            URLQueryItem(name: "page_size", value: "100"),
        ]).filter { row in
            guard let startsAt = row["start_at"].date, row["remote_was_deleted"].bool != true else { return false }
            return startsAt >= start && startsAt <= end && row["status"].string != "COMPLETE"
        }
        var candidates: [String: JSONValue] = [:]
        var jobs: [String: JSONValue] = [:]
        for id in Set(rows.compactMap { $0.at("application.candidate").string }) {
            candidates[id] = try? await api.getJSON("candidates/\(id)")
        }
        for id in Set(rows.compactMap { $0.at("application.job").string }) {
            jobs[id] = try? await api.getJSON("jobs/\(id)")
        }
        return rows.compactMap { row in
            guard let id = row["id"].string, let startsAt = row["start_at"].date else { return nil }
            let candidateID = row.at("application.candidate").string
            let jobID = row.at("application.job").string
            return ExternalInterview(
                source: .merge, externalID: id, title: "Interview", startsAt: startsAt, endsAt: row["end_at"].date,
                meetingURL: MeetingLinks.first(in: [row["location"].string]),
                candidate: candidateID.flatMap { candidates[$0] }.map { Self.candidate($0) },
                job: jobID.map { ExternalJob(externalID: $0, title: jobs[$0]?["name"].string ?? "Job") },
                applicationID: row.at("application.id").string ?? row["application"].string,
                interviewers: row["interviewers"].array.map {
                    ExternalPerson(name: [$0["first_name"].string, $0["last_name"].string].compactMap { $0 }.joined(separator: " "),
                                   email: $0["email"].string)
                }
            )
        }
    }

    static func candidate(_ json: JSONValue) -> ExternalCandidate {
        let name = [json["first_name"].string, json["last_name"].string].compactMap { $0 }.joined(separator: " ")
        return ExternalCandidate(externalID: json["id"].string, name: name.isEmpty ? "Candidate" : name,
                                 email: json["email_addresses"][0]["value"].string)
    }

    public func job(id: String) async throws -> ExternalJob {
        let job = try await api.getJSON("jobs/\(id)")
        return ExternalJob(externalID: id, title: job["name"].string ?? "Job",
                           description: job["description"].string.map(HTMLText.plain) ?? "")
    }

    public func candidate(id: String) async throws -> ExternalCandidate {
        var candidate = Self.candidate(try await api.getJSON("candidates/\(id)"))
        let attachments = try await list("attachments", [URLQueryItem(name: "candidate_id", value: id)], maxPages: 2)
        if let resume = attachments.first(where: { $0["attachment_type"].string == "RESUME" }), let url = resume["file_url"].url {
            candidate.resume = ExternalFile(kind: .resume, filename: resume["file_name"].string ?? "resume", url: url, needsAuth: false)
        }
        return candidate
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: nil, transport: api.transport)
    }

    public func addNote(_ text: String, to interview: ExternalInterview) async throws {
        guard let remoteUserID else { throw ConnectorError.missingCredential("your ATS user ID (Connections \u{203A} Merge)") }
        guard let candidate = interview.candidate?.externalID else {
            throw ConnectorError.unsupported("This interview has no candidate in Merge to attach the note to.")
        }
        _ = try await api.postJSON("activities", body: [
            "remote_user_id": .string(remoteUserID),
            "model": ["candidate": .string(candidate), "activity_type": "NOTE", "subject": "InterviewCheck",
                      "body": .string(text), "visibility": "PRIVATE"],
        ])
    }
}

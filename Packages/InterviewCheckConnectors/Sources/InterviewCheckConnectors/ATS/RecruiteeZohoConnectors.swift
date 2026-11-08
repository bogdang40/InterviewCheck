import Foundation

/// Recruitee (Tellent): personal API token, company id in the path; the
/// interview events call returns candidates, jobs and admins alongside.
public struct RecruiteeConnector: InterviewSource, JobSource, CandidateSource, NoteDestination {
    public let kind = ConnectorKind.recruitee
    let api: APIClient

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        let company = try credentials.required("companyID", "company ID")
        let token = try credentials.required("apiKey", "API token")
        api = APIClient(baseURL: URL(string: "https://api.recruitee.com/c/\(company)")!,
                        headers: ["Authorization": "Bearer \(token)"], transport: transport)
    }

    public func verify() async throws -> String {
        let admin = try await api.getJSON("admin")["admin"]
        return admin["email"].string ?? "Recruitee"
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(identifier: "UTC")
        day.dateFormat = "yyyy-MM-dd"
        let page = try await api.getJSON("interview/events", query: [
            URLQueryItem(name: "scope", value: "my"), URLQueryItem(name: "status", value: "upcoming"),
            URLQueryItem(name: "start_date", value: day.string(from: start)),
            URLQueryItem(name: "end_date", value: day.string(from: end)),
        ])
        var references: [String: JSONValue] = [:]
        for reference in page["references"].array {
            if let type = reference["type"].string, let id = reference["id"].string { references["\(type):\(id)"] = reference }
        }
        return page["interview_events"].array.compactMap { event in
            guard let id = event["id"].string, let startsAt = event["starts_at"].date,
                  startsAt >= start, startsAt <= end else { return nil }
            let candidate = event["candidate_id"].string.flatMap { references["Candidate:\($0)"] }
            let offer = event["offer_id"].string.flatMap { references["Offer:\($0)"] }
            return ExternalInterview(
                source: .recruitee, externalID: id, title: event["custom_name"].string ?? "Interview", startsAt: startsAt,
                endsAt: event["duration"].double.map { startsAt.addingTimeInterval($0 * 60) },
                meetingURL: event["video_url"].url ?? MeetingLinks.first(in: [event["location"].string]),
                candidate: candidate.map {
                    ExternalCandidate(externalID: $0["id"].string, name: $0["name"].string ?? "Candidate", email: $0["emails"][0].string)
                },
                job: offer.flatMap { offer in offer["id"].string.map {
                    ExternalJob(externalID: $0, title: offer["title"].string ?? "Job",
                                description: HTMLText.plain((offer["description"].string ?? "") + (offer["requirements"].string ?? "")))
                } },
                applicationID: event["candidate_id"].string,
                interviewers: event["admin_ids"].array.compactMap { $0.string.flatMap { references["Admin:\($0)"] } }.map {
                    ExternalPerson(name: [$0["first_name"].string, $0["last_name"].string].compactMap { $0 }.joined(separator: " "),
                                   email: $0["email"].string)
                }
            )
        }
    }

    public func job(id: String) async throws -> ExternalJob {
        let offer = try await api.getJSON("offers/\(id)")["offer"]
        return ExternalJob(externalID: id, title: offer["title"].string ?? "Job",
                           description: HTMLText.plain((offer["description"].string ?? "") + (offer["requirements"].string ?? "")))
    }

    public func candidate(id: String) async throws -> ExternalCandidate {
        let json = try await api.getJSON("candidates/\(id)")["candidate"]
        return ExternalCandidate(externalID: id, name: json["name"].string ?? "Candidate", email: json["emails"][0].string,
                                 resume: (json["cv_original_url"].url ?? json["cv_url"].url).map {
                                     ExternalFile(kind: .resume, filename: "\(json["name"].string ?? "candidate") CV", url: $0, needsAuth: false)
                                 },
                                 profileURL: json["adminapp_url"].url)
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: nil, transport: api.transport)
    }

    /// Visible to the token's own admin only.
    public func addNote(_ text: String, to interview: ExternalInterview) async throws {
        guard let candidate = interview.candidate?.externalID ?? interview.applicationID else {
            throw ConnectorError.unsupported("This interview has no Recruitee candidate to attach the note to.")
        }
        guard let admin = try await api.getJSON("admin").at("admin.id").double else { throw ConnectorError.invalidResponse("no admin id") }
        _ = try await api.postJSON("candidates/\(candidate)/notes", body: [
            "note": ["body": .string(text), "visibility": ["level": "protected", "admin_ids": [.number(admin)], "role_ids": []]],
            "attachments": [],
        ])
    }
}

/// Zoho Recruit: OAuth via a Self Client refresh token, per data centre.
public struct ZohoRecruitConnector: InterviewSource, JobSource, CandidateSource, NoteDestination {
    public let kind = ConnectorKind.zohoRecruit
    private let session: OAuthSession
    private let transport: HTTPTransport
    private let base: URL

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        let domain = (credentials["domain"] ?? "zoho.com").replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "recruit.", with: "").replacingOccurrences(of: "accounts.", with: "")
        let provider = OAuthProvider(authorizeURL: URL(string: "https://accounts.\(domain)/oauth/v2/auth")!,
                                     tokenURL: URL(string: "https://accounts.\(domain)/oauth/v2/token")!, scopes: [])
        let client = OAuthClient(provider: provider, clientID: try credentials.required("clientID", "client ID"),
                                 clientSecret: try credentials.required("clientSecret", "client secret"), transport: transport)
        let refresh = try credentials.required("refreshToken", "refresh token")
        // One session per refresh token for the app's lifetime, so each sync
        // reuses the hour-long access token instead of minting a new one.
        session = ZohoSessions.session(for: refresh) {
            OAuthSession(tokens: OAuthTokens(accessToken: "", refreshToken: refresh, expiresAt: .distantPast),
                         client: client, onUpdate: { _ in })
        }
        self.transport = transport
        base = URL(string: "https://recruit.\(domain)/recruit/v2")!
    }

    private func client() async throws -> APIClient {
        APIClient(baseURL: base, headers: ["Authorization": "Zoho-oauthtoken \(try await session.accessToken())"], transport: transport)
    }

    public func verify() async throws -> String {
        _ = try await client().get("Job_Openings", query: [URLQueryItem(name: "per_page", value: "1")])
        return "Zoho Recruit"
    }

    static func zohoTime(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date).replacingOccurrences(of: "Z", with: "+00:00")
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        let (data, response) = try await client().get("Interviews/search", query: [
            URLQueryItem(name: "criteria", value: "(Start_DateTime:between:\(Self.zohoTime(start)),\(Self.zohoTime(end)))"),
            URLQueryItem(name: "per_page", value: "200"),
        ])
        // 204 means no matches.
        guard response.statusCode != 204, !data.isEmpty else { return [] }
        return try JSONValue.parse(data)["data"].array.compactMap { row in
            guard let id = row["id"].string, let startsAt = row["Start_DateTime"].date,
                  (row["Interview_Status"].string ?? "").lowercased() != "cancelled" else { return nil }
            return ExternalInterview(
                source: .zohoRecruit, externalID: id, title: row["Interview_Name"].string ?? "Interview", startsAt: startsAt,
                endsAt: row["End_DateTime"].date,
                meetingURL: MeetingLinks.first(in: [row["Venue"].string, row["Comments"].string]),
                candidate: row.at("Candidate_Name.name").string.map {
                    ExternalCandidate(externalID: row.at("Candidate_Name.id").string, name: $0)
                },
                job: row.at("Job_Opening_Name.id").string.map {
                    ExternalJob(externalID: $0, title: row.at("Job_Opening_Name.name").string ?? "Job")
                },
                interviewers: row["Interviewer"].array.compactMap { $0["name"].string.map { ExternalPerson(name: $0) } }
            )
        }
    }

    public func job(id: String) async throws -> ExternalJob {
        let job = try await client().getJSON("Job_Openings/\(id)")["data"][0]
        return ExternalJob(externalID: id, title: job["Posting_Title"].string ?? job["Job_Opening_Name"].string ?? "Job",
                           description: job["Job_Description"].string.map(HTMLText.plain) ?? "")
    }

    public func candidate(id: String) async throws -> ExternalCandidate {
        let api = try await client()
        let json = try await api.getJSON("Candidates/\(id)")["data"][0]
        let name = [json["First_Name"].string, json["Last_Name"].string].compactMap { $0 }.joined(separator: " ")
        var candidate = ExternalCandidate(externalID: id, name: name.isEmpty ? "Candidate" : name, email: json["Email"].string)
        let attachments = (try? await api.getJSON("Candidates/\(id)/Attachments"))?["data"].array ?? []
        if let resume = attachments.first(where: { ($0["Category"].string ?? $0["File_Name"].string ?? "").lowercased().contains("resume") })
            ?? attachments.first, let attachment = resume["id"].string {
            candidate.resume = ExternalFile(kind: .resume, filename: resume["File_Name"].string ?? "resume",
                                            url: api.url("Candidates/\(id)/Attachments/\(attachment)"), needsAuth: true)
        }
        return candidate
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: file.needsAuth ? try await client() : nil, transport: transport)
    }

    public func addNote(_ text: String, to interview: ExternalInterview) async throws {
        guard let candidate = interview.candidate?.externalID else {
            throw ConnectorError.unsupported("This interview has no Zoho Recruit candidate to attach the note to.")
        }
        _ = try await client().postJSON("Notes", body: ["data": [[
            "Note_Title": "InterviewCheck", "Note_Content": .string(text), "Parent_Id": .string(candidate), "se_module": "Candidates",
        ]]])
    }
}

extension RecruiteeConnector: CandidateLookup {
    public func findCandidate(email: String) async throws -> CandidateMatch? {
        guard let json = try await api.getJSON("candidates", query: [URLQueryItem(name: "query", value: email),
                                                                     URLQueryItem(name: "limit", value: "5")])["candidates"].array
            .first(where: { $0["emails"].array.contains { $0.string?.lowercased() == email.lowercased() } })?.asObject,
              let id = json["id"].string else { return nil }
        let offer = json["placements"][0]["offer_id"].string
        return CandidateMatch(candidate: ExternalCandidate(externalID: id, name: json["name"].string ?? "Candidate", email: email),
                              job: offer.map { ExternalJob(externalID: $0, title: "Job") }, applicationID: id)
    }
}

enum ZohoSessions {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [String: OAuthSession] = [:]

    static func session(for refreshToken: String, make: () -> OAuthSession) -> OAuthSession {
        lock.lock(); defer { lock.unlock() }
        if let session = sessions[refreshToken] { return session }
        let session = make()
        sessions[refreshToken] = session
        return session
    }
}

extension RecruiteeConnector: JobListing {
    public func openJobs() async throws -> [ExternalJob] {
        try await api.getJSON("offers", query: [URLQueryItem(name: "statuses[]", value: "published")])["offers"].array.compactMap { offer in
            offer["id"].string.map { ExternalJob(externalID: $0, title: offer["title"].string ?? "Job") }
        }
    }
}

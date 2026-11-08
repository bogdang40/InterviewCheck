import Foundation

/// Lever: API key as Basic username. Lever has no global interview list, so
/// interviews are read per open opportunity updated in the last 60 days.
public struct LeverConnector: InterviewSource, JobSource, CandidateSource, NoteDestination {
    public let kind = ConnectorKind.lever
    private let api: APIClient
    var maxOpportunities = 300

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        let key = try credentials.required("apiKey", "API key")
        let base = URL(string: credentials["baseURL"] ?? "https://api.lever.co/v1")!
        api = APIClient(baseURL: base, headers: ["Authorization": APIClient.basic(key)], transport: transport)
    }

    public func verify() async throws -> String {
        _ = try await api.get("opportunities", query: [URLQueryItem(name: "limit", value: "1")])
        return "Lever"
    }

    /// Pages through `{data, next, hasNext}` lists.
    func list(_ path: String, _ query: [URLQueryItem], limit: Int) async throws -> [JSONValue] {
        var items: [JSONValue] = []
        var offset: String?
        repeat {
            var pageQuery = query + [URLQueryItem(name: "limit", value: "100")]
            if let offset { pageQuery.append(URLQueryItem(name: "offset", value: offset)) }
            let page = try await api.getJSON(path, query: pageQuery)
            items += page["data"].array
            offset = page["hasNext"].bool == true ? page["next"].string : nil
        } while offset != nil && items.count < limit
        return Array(items.prefix(limit))
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        let since = start.addingTimeInterval(-60 * 86_400)
        let opportunities = try await list("opportunities", [
            URLQueryItem(name: "archived", value: "false"),
            URLQueryItem(name: "updated_at_start", value: DateParsing.millis(since)),
        ], limit: maxOpportunities)
        var interviews: [(JSONValue, JSONValue)] = []
        // About 10 requests a second is allowed: five at a time.
        for batch in opportunities.chunked(5) {
            let found = try await withThrowingTaskGroup(of: [(JSONValue, JSONValue)].self) { group in
                for opportunity in batch {
                    guard let id = opportunity["id"].string else { continue }
                    group.addTask {
                        let rows = try await api.getJSON("opportunities/\(id)/interviews")["data"].array
                        return rows.map { (opportunity, $0) }
                    }
                }
                return try await group.reduce(into: []) { $0 += $1 }
            }
            interviews += found.filter { _, interview in
                guard interview["canceledAt"].isNull, let ms = interview["date"].double else { return false }
                let date = Date(timeIntervalSince1970: ms / 1000)
                return date >= start && date <= end
            }
        }
        var titles: [String: String] = [:]
        for posting in Set(interviews.compactMap { $0.1["postings"][0].string }) {
            titles[posting] = (try? await api.getJSON("postings/\(posting)"))?.at("data.text").string
        }
        return interviews.compactMap { opportunity, item in
            guard let id = item["id"].string, let ms = item["date"].double else { return nil }
            let startsAt = Date(timeIntervalSince1970: ms / 1000)
            let video = item["conferences"].array.flatMap { $0["entryPoints"].array }.first { $0["type"].string == "video" }
            let posting = item["postings"][0].string
            return ExternalInterview(
                source: .lever, externalID: id, title: item["subject"].string ?? "Interview", startsAt: startsAt,
                endsAt: item["duration"].double.map { startsAt.addingTimeInterval($0 * 60) },
                meetingURL: video?["uri"].url ?? MeetingLinks.first(in: [item["location"].string]),
                candidate: ExternalCandidate(externalID: opportunity["id"].string, name: opportunity["name"].string ?? "Candidate",
                                             email: opportunity["emails"][0].string),
                job: posting.map { ExternalJob(externalID: $0, title: titles[$0] ?? "Job") },
                applicationID: opportunity["id"].string,
                interviewers: item["interviewers"].array.map {
                    ExternalPerson(name: $0["name"].string ?? "", email: $0["email"].string)
                }
            )
        }
    }

    public func job(id: String) async throws -> ExternalJob {
        let posting = try await api.getJSON("postings/\(id)")["data"]
        let content = posting["content"]
        var html = content["descriptionHtml"].string ?? content["description"].string ?? ""
        for list in content["lists"].array {
            html += "<h3>\(list["text"].string ?? "")</h3><ul>\(list["content"].string ?? "")</ul>"
        }
        html += content["closingHtml"].string ?? ""
        return ExternalJob(externalID: id, title: posting["text"].string ?? "Job", description: HTMLText.plain(html))
    }

    /// `id` is the opportunity id (Lever's candidacy record).
    public func candidate(id: String) async throws -> ExternalCandidate {
        let opportunity = try await api.getJSON("opportunities/\(id)")["data"]
        var candidate = ExternalCandidate(externalID: id, name: opportunity["name"].string ?? "Candidate",
                                          email: opportunity["emails"][0].string)
        let resumes = try await api.getJSON("opportunities/\(id)/resumes")["data"].array
        if let resume = resumes.first(where: { $0.at("file.status").string == "processed" }) ?? resumes.first,
           let resumeID = resume["id"].string {
            candidate.resume = ExternalFile(kind: .resume, filename: resume.at("file.name").string ?? "resume",
                                            url: api.url("opportunities/\(id)/resumes/\(resumeID)/download"), needsAuth: true)
        }
        return candidate
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: file.needsAuth ? api : nil, transport: api.transport)
    }

    public func addNote(_ text: String, to interview: ExternalInterview) async throws {
        guard let opportunity = interview.applicationID ?? interview.candidate?.externalID else {
            throw ConnectorError.unsupported("This interview has no Lever opportunity to attach the note to.")
        }
        _ = try await api.postJSON("opportunities/\(opportunity)/notes",
                                   body: ["value": .string(text), "secret": true, "notifyFollowers": false])
    }
}

import Foundation

/// Ashby: RPC-style POST calls with the API key as Basic username. Errors
/// can come back as HTTP 200 with `success: false`.
public struct AshbyConnector: InterviewSource, JobSource, CandidateSource, NoteDestination {
    public let kind = ConnectorKind.ashby
    let api: APIClient

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        let key = try credentials.required("apiKey", "API key")
        api = APIClient(baseURL: URL(string: "https://api.ashbyhq.com")!,
                        headers: ["Authorization": APIClient.basic(key), "Accept": "application/json; version=1"],
                        transport: transport)
    }

    /// One RPC call; returns `results` or throws Ashby's own error.
    func call(_ method: String, _ body: [String: JSONValue]) async throws -> JSONValue {
        let response = try await api.postJSON(method, body: .object(body))
        if response["success"].bool == false {
            let errors = response["errors"].array.compactMap(\.string).joined(separator: ", ")
            if errors.contains("missing_endpoint_permission") { throw ConnectorError.forbidden(errors) }
            throw ConnectorError.invalidResponse(errors.isEmpty ? "Ashby refused the request" : errors)
        }
        return response
    }

    public func verify() async throws -> String {
        _ = try await call("interviewSchedule.list", ["limit": 1])
        return "Ashby"
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        // No start-time filter: read schedules created in the last 60 days.
        var schedules: [JSONValue] = []
        var cursor: String?
        for _ in 0..<20 {
            var body: [String: JSONValue] = ["limit": 100,
                                             "createdAfter": .number(start.addingTimeInterval(-60 * 86_400).timeIntervalSince1970 * 1000)]
            if let cursor { body["cursor"] = .string(cursor) }
            let page = try await call("interviewSchedule.list", body)
            schedules += page["results"].array
            guard page["moreDataAvailable"].bool == true, let next = page["nextCursor"].string else { break }
            cursor = next
        }
        let events = schedules.filter { $0["status"].string == "Scheduled" }.flatMap { schedule in
            schedule["interviewEvents"].array.compactMap { event -> (JSONValue, JSONValue)? in
                guard let startsAt = event["startTime"].date, startsAt >= start, startsAt <= end else { return nil }
                return (schedule, event)
            }
        }
        var applications: [String: JSONValue] = [:]
        for id in Set(events.compactMap { $0.0["applicationId"].string }) {
            applications[id] = try? await call("application.info", ["applicationId": .string(id)])["results"]
        }
        return events.compactMap { schedule, event in
            guard let id = event["id"].string, let startsAt = event["startTime"].date else { return nil }
            let application = schedule["applicationId"].string.flatMap { applications[$0] }
            let candidate = application?["candidate"]
            let job = application?["job"]
            return ExternalInterview(
                source: .ashby, externalID: id, title: event.at("interview.title").string ?? "Interview",
                startsAt: startsAt, endsAt: event["endTime"].date,
                meetingURL: event["meetingLink"].url ?? MeetingLinks.first(in: [event["location"].string]),
                candidate: candidate.flatMap { candidate in
                    candidate["name"].string.map {
                        ExternalCandidate(externalID: candidate["id"].string, name: $0,
                                          email: candidate.at("primaryEmailAddress.value").string)
                    }
                },
                job: job.flatMap { job in job["id"].string.map { ExternalJob(externalID: $0, title: job["title"].string ?? "Job") } },
                applicationID: schedule["applicationId"].string,
                interviewers: event["interviewers"].array.map {
                    ExternalPerson(name: [$0["firstName"].string, $0["lastName"].string].compactMap { $0 }.joined(separator: " "),
                                   email: $0["email"].string)
                }
            )
        }
    }

    public func job(id: String) async throws -> ExternalJob {
        let job = try await call("job.info", ["id": .string(id)])["results"]
        var description = ""
        if let posting = job["jobPostingIds"][0].string {
            let details = try await call("jobPosting.info", ["jobPostingId": .string(posting)])["results"]
            description = details["descriptionPlain"].string ?? details["descriptionHtml"].string.map(HTMLText.plain) ?? ""
        }
        return ExternalJob(externalID: id, title: job["title"].string ?? "Job", description: description)
    }

    public func candidate(id: String) async throws -> ExternalCandidate {
        let json = try await call("candidate.info", ["id": .string(id)])["results"]
        var candidate = ExternalCandidate(externalID: id, name: json["name"].string ?? "Candidate",
                                          email: json.at("primaryEmailAddress.value").string, profileURL: json["profileUrl"].url)
        if let handle = json.at("resumeFileHandle.handle").string {
            var components = URLComponents(string: "ashby://file")!
            components.queryItems = [URLQueryItem(name: "handle", value: handle)]
            candidate.resume = ExternalFile(kind: .resume, filename: json.at("resumeFileHandle.name").string ?? "resume",
                                            url: components.url!, needsAuth: false)
        }
        return candidate
    }

    /// Ashby résumé links are fetched just before downloading (expiry unknown).
    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        var target = file
        if file.url.scheme == "ashby",
           let handle = URLComponents(url: file.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "handle" })?.value {
            guard let url = try await call("file.info", ["fileHandle": .string(handle)]).at("results.url").url else {
                throw ConnectorError.invalidResponse("no file URL")
            }
            target.url = url
        }
        return try await FileDownload.save(target, into: folder, client: nil, transport: api.transport)
    }

    public func addNote(_ text: String, to interview: ExternalInterview) async throws {
        guard let candidateID = interview.candidate?.externalID else {
            throw ConnectorError.unsupported("This interview has no Ashby candidate to attach the note to.")
        }
        _ = try await call("candidate.createNote", [
            "candidateId": .string(candidateID),
            "note": ["type": "text/plain", "value": .string(text)],
            "isPrivate": true, "sendNotifications": false,
        ])
    }
}

extension AshbyConnector: CandidateLookup {
    public func findCandidate(email: String) async throws -> CandidateMatch? {
        guard let json = try await call("candidate.search", ["email": .string(email)])["results"][0].asObject,
              let id = json["id"].string else { return nil }
        let applicationID = json["applicationIds"].array.last?.string
        var application: JSONValue?
        if let applicationID { application = try await call("application.info", ["applicationId": .string(applicationID)])["results"] }
        return CandidateMatch(candidate: ExternalCandidate(externalID: id, name: json["name"].string ?? "Candidate", email: email),
                              job: application?.at("job.id").string.map {
                                  ExternalJob(externalID: $0, title: application?.at("job.title").string ?? "Job")
                              },
                              applicationID: applicationID)
    }
}

extension AshbyConnector: JobListing {
    public func openJobs() async throws -> [ExternalJob] {
        try await call("job.list", ["status": ["Open"]])["results"].array.compactMap { job in
            job["id"].string.map { ExternalJob(externalID: $0, title: job["title"].string ?? "Job") }
        }
    }
}

import Foundation

/// Bullhorn OAuth: each customer asks Bullhorn support for an API key (client
/// ID and secret) whose redirect list includes http://127.0.0.1:53871/callback.
/// The sign-in host depends on the customer's data center, found from the
/// API user's name before sign-in.
public enum BullhornConnectorProvider {
    static let defaultOAuthURL = "https://auth.bullhornstaffing.com/oauth"
    static let defaultRestURL = "https://rest.bullhornstaffing.com/rest-services"

    public static func provider(_ credentials: ConnectorCredentials) -> OAuthProvider {
        let base = (credentials["oauthURL"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultOAuthURL).trimmingSuffix("/")
        return OAuthProvider(authorizeURL: URL(string: base + "/authorize")!, tokenURL: URL(string: base + "/token")!, scopes: [])
    }

    /// The data center's sign-in and REST addresses for this API user.
    public static func locate(username: String, transport: HTTPTransport) async throws -> (oauthURL: String, restURL: String) {
        let api = APIClient(baseURL: URL(string: defaultRestURL)!, transport: transport)
        let info = try await api.getJSON("loginInfo", query: [URLQueryItem(name: "username", value: username)])
        guard let oauth = info["oauthUrl"].url, oauth.scheme == "https", oauth.host?.hasSuffix("bullhornstaffing.com") == true,
              let rest = info["restUrl"].url, rest.scheme == "https", rest.host?.hasSuffix("bullhornstaffing.com") == true else {
            throw ConnectorError.invalidResponse("no data center found for \(username)")
        }
        return (oauth.absoluteString, rest.absoluteString)
    }
}

/// Bullhorn's REST session (BhRestToken), made once per connector and reused:
/// Bullhorn limits how often an integration may log in.
actor BullhornSession {
    private var current: Task<(URL, String), Error>?

    func get(_ login: @escaping @Sendable () async throws -> (URL, String)) async throws -> (URL, String) {
        if let current { return try await current.value }
        let task = Task { try await login() }
        current = task
        do { return try await task.value } catch { current = nil; throw error }
    }
}

/// Bullhorn (staffing): interviews are Appointment records of the interview
/// type. Read-only: Bullhorn notes cannot be private, so no summary is sent.
public struct BullhornConnector: InterviewSource, JobSource, CandidateSource, CandidateLookup {
    public let kind = ConnectorKind.bullhorn
    private let token: AccessTokenProvider
    private let transport: HTTPTransport
    private let restServices: URL
    private let username: String
    /// Appointment types that are interviews ("Interview" unless the agency uses others).
    let types: [String]
    private let session = BullhornSession()
    static let pageSize = 200
    static let pageLimit = 10

    public init(credentials: ConnectorCredentials, transport: HTTPTransport, accessToken: AccessTokenProvider?) throws {
        guard let accessToken else { throw ConnectorError.notConnected }
        token = accessToken
        self.transport = transport
        username = credentials["username"] ?? ""
        let rest = credentials["restURL"].flatMap { $0.isEmpty ? nil : $0 } ?? BullhornConnectorProvider.defaultRestURL
        guard let url = URL(string: rest.trimmingSuffix("/")), url.scheme == "https" else {
            throw ConnectorError.invalidResponse("REST address")
        }
        restServices = url
        let typed = credentials["types"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        types = typed.isEmpty ? ["Interview"] : typed
    }

    private func client() async throws -> APIClient {
        let token = self.token
        let login = APIClient(baseURL: restServices, transport: transport)
        let (base, bhToken) = try await session.get {
            let url = login.url("login", query: [URLQueryItem(name: "version", value: "2.0"),
                                                 URLQueryItem(name: "access_token", value: try await token())])
            let json = try JSONValue.parse(try await login.send(method: "POST", url: url, body: nil).0)
            guard let rest = json["restUrl"].url, rest.scheme == "https", let bh = json["BhRestToken"].string else {
                throw ConnectorError.invalidResponse("no BhRestToken from login")
            }
            return (rest, bh)
        }
        return APIClient(baseURL: base, headers: ["BhRestToken": bhToken], transport: transport)
    }

    public func verify() async throws -> String {
        let settings = try await client().getJSON("settings/corporationName")
        return settings["corporationName"].string ?? (username.isEmpty ? "Bullhorn" : username)
    }

    /// `type='Interview' OR type='Phone screen'`, quotes doubled.
    static func typeClause(_ types: [String]) -> String {
        "(" + types.map { "type='\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: " OR ") + ")"
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        let api = try await client()
        let millis = { (date: Date) in String(Int64(date.timeIntervalSince1970 * 1000)) }
        // Bullhorn copies an appointment to each invitee (a child of the owner's
        // copy). All copies are read and joined, so each person on it is an interviewer.
        let clause = "\(Self.typeClause(types)) AND dateBegin>=\(millis(start)) AND dateBegin<\(millis(end)) AND isDeleted=false"
        let fields = "id,subject,dateBegin,dateEnd,location,type,description,candidateReference(id,firstName,lastName,email),"
            + "jobOrder(id,title),owner(id,firstName,lastName,email),parentAppointment(id)"
        var rows: [JSONValue] = []
        for page in 0..<Self.pageLimit {
            let data = try await api.getJSON("query/Appointment", query: [
                URLQueryItem(name: "where", value: clause), URLQueryItem(name: "fields", value: fields),
                URLQueryItem(name: "orderBy", value: "dateBegin"), URLQueryItem(name: "start", value: "\(page * Self.pageSize)"),
                URLQueryItem(name: "count", value: "\(Self.pageSize)"),
            ])["data"].array
            rows += data
            if data.count < Self.pageSize { break }
            if page == Self.pageLimit - 1 { SyncNotes.cut("appointments", read: rows.count) }
        }
        // One interview per original appointment, with every copy's owner on it.
        var order: [String] = []
        var groups: [String: [JSONValue]] = [:]
        for row in rows {
            guard let id = row["id"].string else { continue }
            let root = row.at("parentAppointment.id").string ?? id
            if groups[root] == nil { order.append(root) }
            groups[root, default: []].append(row)
        }
        return order.compactMap { root in
            let copies = groups[root] ?? []
            // The owner's copy when it was read, else an invitee's copy.
            guard let row = copies.first(where: { $0.at("parentAppointment.id").string == nil }) ?? copies.first,
                  let begin = row["dateBegin"].double else { return nil }
            let candidate = row["candidateReference"]
            let job = row["jobOrder"]
            var interviewers: [ExternalPerson] = []
            for owner in copies.map({ $0["owner"] }) {
                guard let email = owner["email"].string, !interviewers.contains(where: { $0.email == email }) else { continue }
                let name = [owner["firstName"].string, owner["lastName"].string].compactMap { $0 }.joined(separator: " ")
                interviewers.append(ExternalPerson(name: name.isEmpty ? email : name, email: email))
            }
            return ExternalInterview(
                source: .bullhorn, externalID: root, title: row["subject"].string ?? "Interview",
                startsAt: Date(timeIntervalSince1970: begin / 1000),
                endsAt: row["dateEnd"].double.map { Date(timeIntervalSince1970: $0 / 1000) },
                meetingURL: MeetingLinks.first(in: [row["location"].string, row["description"].string]),
                candidate: candidate["id"].string.map {
                    ExternalCandidate(externalID: $0, name: Self.name(candidate), email: candidate["email"].string)
                },
                job: job["id"].string.map { ExternalJob(externalID: $0, title: job["title"].string ?? "Job") },
                interviewers: interviewers
            )
        }
    }

    static func name(_ person: JSONValue) -> String {
        let name = [person["firstName"].string, person["lastName"].string].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? "Candidate" : name
    }

    public func job(id: String) async throws -> ExternalJob {
        let job = try await client().getJSON("entity/JobOrder/\(id)", query: [
            URLQueryItem(name: "fields", value: "id,title,publicDescription,description")])["data"]
        let html = job["publicDescription"].string ?? job["description"].string ?? ""
        return ExternalJob(externalID: id, title: job["title"].string ?? "Job", description: HTMLText.plain(html))
    }

    public func candidate(id: String) async throws -> ExternalCandidate {
        let api = try await client()
        let person = try await api.getJSON("entity/Candidate/\(id)", query: [
            URLQueryItem(name: "fields", value: "id,firstName,lastName,email")])["data"]
        let files = try await api.getJSON("entity/Candidate/\(id)/fileAttachments", query: [
            URLQueryItem(name: "fields", value: "id,type,name,isDeleted,dateAdded")])["data"].array
        let resume = files.filter { $0["isDeleted"].bool != true && ($0["type"].string ?? "").lowercased().contains("resume") }
            .max { ($0["dateAdded"].double ?? 0) < ($1["dateAdded"].double ?? 0) }
        return ExternalCandidate(externalID: id, name: Self.name(person), email: person["email"].string,
                                 resume: resume.flatMap { file in file["id"].string.map {
                                     ExternalFile(kind: .resume, filename: file["name"].string ?? "resume",
                                                  url: api.url("file/Candidate/\(id)/\($0)/raw"), needsAuth: true)
                                 } })
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: try await client(), transport: transport)
    }

    public func findCandidate(email: String) async throws -> CandidateMatch? {
        let rows = try await client().getJSON("search/Candidate", query: [
            URLQueryItem(name: "query", value: "email:\"\(email.replacingOccurrences(of: "\"", with: ""))\""),
            URLQueryItem(name: "fields", value: "id,firstName,lastName,email"), URLQueryItem(name: "count", value: "5"),
        ])["data"].array
        guard let row = rows.first(where: { $0["email"].string?.caseInsensitiveCompare(email) == .orderedSame }),
              let id = row["id"].string else { return nil }
        return CandidateMatch(candidate: ExternalCandidate(externalID: id, name: Self.name(row), email: row["email"].string),
                              job: nil, applicationID: nil)
    }
}

/// JobAdder OAuth: an approved JobAdder developer app with the redirect
/// http://127.0.0.1:53871/callback; JobAdder asks for the client secret.
public enum JobAdderConnectorProvider {
    public static let provider = OAuthProvider(
        authorizeURL: URL(string: "https://id.jobadder.com/connect/authorize")!,
        tokenURL: URL(string: "https://id.jobadder.com/connect/token")!,
        scopes: ["read", "offline_access"]
    )
}

/// JobAdder (staffing): interviews from /interviews and the newer /events
/// scheduler, merged. Read-only: JobAdder notes have no private setting.
public struct JobAdderConnector: InterviewSource, JobSource, CandidateSource, CandidateLookup {
    public let kind = ConnectorKind.jobAdder
    private let token: AccessTokenProvider
    private let transport: HTTPTransport
    private let base: URL
    static let pageLimit = 10

    public init(credentials: ConnectorCredentials, transport: HTTPTransport, accessToken: AccessTokenProvider?) throws {
        guard let accessToken else { throw ConnectorError.notConnected }
        token = accessToken
        self.transport = transport
        let typed = credentials["apiURL"].flatMap { $0.isEmpty ? nil : $0 } ?? "https://api.jobadder.com/v2"
        guard let url = URL(string: typed.trimmingSuffix("/")), url.scheme == "https", url.host?.hasSuffix("jobadder.com") == true else {
            throw ConnectorError.missingCredential("API address on jobadder.com")
        }
        base = url
    }

    private func client() async throws -> APIClient {
        APIClient(baseURL: base, headers: ["Authorization": "Bearer \(try await token())"], transport: transport)
    }

    public func verify() async throws -> String {
        _ = try await client().getJSON("interviews", query: [URLQueryItem(name: "Limit", value: "1")])
        return "JobAdder"
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        let api = try await client()
        var rows: [JSONValue] = []
        for page in 0..<Self.pageLimit {
            let json = try await api.getJSON("interviews", query: [
                URLQueryItem(name: "StartAt", value: ">" + DateParsing.iso(start)),
                URLQueryItem(name: "StartAt", value: "<" + DateParsing.iso(end)),
                URLQueryItem(name: "Limit", value: "100"), URLQueryItem(name: "Offset", value: "\(page * 100)"),
            ])
            let items = json["items"].array
            rows += items
            if items.count < 100 || rows.count >= Int(json["totalCount"].double ?? 0) { break }
            if page == Self.pageLimit - 1 { SyncNotes.cut("interviews", read: rows.count) }
        }
        var interviews = rows.compactMap(Self.interview)
        // The newer scheduler keeps its interviews as events.
        do {
            var events: [JSONValue] = []
            for page in 0..<Self.pageLimit {
                let items = try await api.getJSON("events", query: [
                    URLQueryItem(name: "EventType", value: "Interview"), URLQueryItem(name: "StartDate", value: DateParsing.iso(start)),
                    URLQueryItem(name: "EndDate", value: DateParsing.iso(end)), URLQueryItem(name: "Limit", value: "100"),
                    URLQueryItem(name: "Offset", value: "\(page * 100)"),
                ])["items"].array
                events += items
                if items.count < 100 { break }
                if page == Self.pageLimit - 1 { SyncNotes.cut("scheduler interviews", read: events.count) }
            }
            interviews += events.compactMap(Self.event)
        } catch {
            SyncNotes.note("Interviews from JobAdder\u{2019}s scheduler could not be read: \(error.localizedDescription)")
        }
        return InterviewMerger.merge(interviews)
    }

    static func person(_ json: JSONValue) -> String {
        let name = [json["firstName"].string, json["lastName"].string].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? (json["email"].string ?? "Candidate") : name
    }

    static func interview(_ row: JSONValue) -> ExternalInterview? {
        guard let id = row["interviewId"].string, let startsAt = row["startAt"].date else { return nil }
        let application = row["interviewee"]
        let candidate = application["candidate"]
        let jobID = application.at("job.jobId").string
        return ExternalInterview(
            source: .jobAdder, externalID: id, title: "Interview", startsAt: startsAt, endsAt: row["endAt"].date,
            meetingURL: MeetingLinks.first(in: [row["location"].string]),
            candidate: candidate["candidateId"].string.map { ExternalCandidate(externalID: $0, name: person(candidate), email: candidate["email"].string) },
            job: jobID.map { ExternalJob(externalID: $0, title: application.at("job.jobTitle").string ?? application["jobTitle"].string ?? "Job") },
            applicationID: application["applicationId"].string,
            interviewers: row.at("interviewers.users").array.compactMap { user in
                user["email"].string.map { ExternalPerson(name: person(user), email: $0) }
            }
        )
    }

    static func event(_ row: JSONValue) -> ExternalInterview? {
        guard let id = row["eventId"].string, let startsAt = row["startTimeUtc"].date else { return nil }
        let candidate = row["candidates"][0]
        return ExternalInterview(
            source: .jobAdder, externalID: "event-\(id)", title: row["title"].string ?? "Interview", startsAt: startsAt,
            endsAt: row["endTimeUtc"].date,
            meetingURL: row["videoConferenceUrl"].url ?? MeetingLinks.first(in: [row["description"].string]),
            candidate: candidate["candidateId"].string.map { ExternalCandidate(externalID: $0, name: person(candidate), email: candidate["email"].string) },
            job: row.at("job.jobId").string.map { ExternalJob(externalID: $0, title: row.at("job.jobTitle").string ?? "Job") },
            interviewers: row["users"].array.compactMap { user in user["email"].string.map { ExternalPerson(name: person(user), email: $0) } }
        )
    }

    public func job(id: String) async throws -> ExternalJob {
        let job = try await client().getJSON("jobs/\(id)")
        return ExternalJob(externalID: id, title: job["jobTitle"].string ?? "Job", description: HTMLText.plain(job["jobDescription"].string ?? ""))
    }

    public func candidate(id: String) async throws -> ExternalCandidate {
        let api = try await client()
        let person = try await api.getJSON("candidates/\(id)")
        let resume = try? await api.getJSON("candidates/\(id)/attachments", query: [URLQueryItem(name: "Type", value: "Resume"),
                                                                                    URLQueryItem(name: "Latest", value: "true")])["items"][0]
        return ExternalCandidate(externalID: id, name: Self.person(person), email: person["email"].string,
                                 resume: resume.flatMap { file in file["attachmentId"].string.map {
                                     ExternalFile(kind: .resume, filename: file["fileName"].string ?? "resume",
                                                  url: api.url("candidates/\(id)/attachments/\($0)"), needsAuth: true)
                                 } })
    }

    public func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        try await FileDownload.save(file, into: folder, client: try await client(), transport: transport)
    }

    public func findCandidate(email: String) async throws -> CandidateMatch? {
        let rows = try await client().getJSON("candidates", query: [URLQueryItem(name: "Email", value: email),
                                                                    URLQueryItem(name: "Limit", value: "5")])["items"].array
        // Only an exact email match counts, whatever the filter did.
        guard let row = rows.first(where: { $0["email"].string?.caseInsensitiveCompare(email) == .orderedSame }),
              let id = row["candidateId"].string else { return nil }
        return CandidateMatch(candidate: ExternalCandidate(externalID: id, name: Self.person(row), email: row["email"].string),
                              job: nil, applicationID: nil)
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

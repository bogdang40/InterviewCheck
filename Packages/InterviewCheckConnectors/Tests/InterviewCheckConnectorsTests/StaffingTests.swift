import XCTest
@testable import InterviewCheckConnectors

final class StaffingTests: XCTestCase {
    private let from = date("2026-11-07T00:00:00Z")
    private let to = date("2026-11-21T00:00:00Z")

    private func bullhorn(_ stub: StubTransport, fields: [String: String] = [:]) throws -> BullhornConnector {
        var all = ["username": "acme.api", "oauthURL": "https://auth-west.bullhornstaffing.com/oauth",
                   "restURL": "https://rest-west.bullhornstaffing.com/rest-services"]
        all.merge(fields) { $1 }
        return try BullhornConnector(credentials: ConnectorCredentials(fields: all), transport: stub, accessToken: { "access" })
    }

    func testBullhornLogsInOnceAndReadsInterviewAppointments() async throws {
        let stub = StubTransport()
        stub.on("POST", "rest-west.bullhornstaffing.com/rest-services/login", json: #"{"BhRestToken":"bh-123","restUrl":"https://rest99.bullhornstaffing.com/rest-services/abc1/"}"#)
        stub.on("GET", "rest99.bullhornstaffing.com/rest-services/abc1/query/Appointment", json: #"""
        {"start":0,"count":1,"data":[{"id":5501,"subject":"Interview - Jane Doe","dateBegin":1794326400000,"dateEnd":1794330000000,
          "location":"https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0","type":"Interview",
          "candidateReference":{"id":88,"firstName":"Jane","lastName":"Doe","email":"jane@example.com"},
          "jobOrder":{"id":12,"title":"Senior Java Developer"},"owner":{"id":3,"firstName":"Sam","lastName":"Recruiter","email":"sam@acme-staffing.com"}},
         {"id":5502,"subject":"Interview - Jane Doe","dateBegin":1794326400000,"dateEnd":1794330000000,"type":"Interview",
          "parentAppointment":{"id":5501},"candidateReference":{"id":88,"firstName":"Jane","lastName":"Doe","email":"jane@example.com"},
          "owner":{"id":4,"firstName":"Lee","lastName":"Engineer","email":"lee@acme-staffing.com"}}]}
        """#)
        stub.on("GET", "settings/corporationName", json: #"{"corporationName":"Acme Staffing"}"#)
        let connector = try bullhorn(stub, fields: ["types": "Interview, Client's Interview"])
        let interviews = try await connector.upcomingInterviews(from: from, to: to)
        let interview = try XCTUnwrap(interviews.first)
        XCTAssertEqual(interview.source, .bullhorn)
        XCTAssertEqual(interview.externalID, "5501")
        XCTAssertEqual(interview.startsAt, Date(timeIntervalSince1970: 1_794_326_400))
        XCTAssertEqual(interview.candidate, ExternalCandidate(externalID: "88", name: "Jane Doe", email: "jane@example.com"))
        XCTAssertEqual(interview.job?.title, "Senior Java Developer")
        XCTAssertEqual(interview.meetingURL?.host, "teams.microsoft.com")
        XCTAssertEqual(interviews.count, 1, "an invitee's copy joins the original appointment")
        XCTAssertEqual(interview.interviewers.map(\.email), ["sam@acme-staffing.com", "lee@acme-staffing.com"],
                       "an invited colleague is an interviewer too, so the interview shows for them")
        let query = try XCTUnwrap(stub.requests(containing: "query/Appointment").first)
        XCTAssertEqual(query.value(forHTTPHeaderField: "BhRestToken"), "bh-123")
        let clause = try XCTUnwrap(URLComponents(url: query.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "where" }?.value)
        XCTAssertTrue(clause.hasPrefix("(type='Interview' OR type='Client''s Interview') AND dateBegin>="), clause)
        XCTAssertFalse(clause.contains("parentAppointment IS NULL"), "invitees' copies are read")
        let label = try await connector.verify()
        XCTAssertEqual(label, "Acme Staffing")
        XCTAssertEqual(stub.requests(containing: "/login").count, 1, "one REST login per connector")
        XCTAssertTrue(stub.requests(containing: "/login").first!.url!.absoluteString.contains("access_token=access"))
    }

    func testBullhornResumeAndLookup() async throws {
        let stub = StubTransport()
        stub.on("POST", "/login", json: #"{"BhRestToken":"bh","restUrl":"https://rest99.bullhornstaffing.com/rest-services/abc1/"}"#)
        stub.on("GET", "entity/Candidate/88/fileAttachments", json: #"{"data":[{"id":1,"type":"Cover Letter","name":"cover.pdf"},{"id":2,"type":"Resume","name":"old.pdf","dateAdded":1000},{"id":3,"type":"Resume","name":"jane.pdf","dateAdded":2000},{"id":4,"type":"Resume","name":"gone.pdf","dateAdded":3000,"isDeleted":true}]}"#)
        stub.on("GET", "entity/Candidate/88", json: #"{"data":{"id":88,"firstName":"Jane","lastName":"Doe","email":"jane@example.com"}}"#)
        stub.on("GET", "search/Candidate", json: #"{"total":2,"data":[{"id":90,"firstName":"Janet","email":"janet@example.com"},{"id":88,"firstName":"Jane","lastName":"Doe","email":"Jane@Example.com"}]}"#)
        stub.on("GET", "entity/JobOrder/12", json: #"{"data":{"id":12,"title":"Senior Java Developer","publicDescription":"<p>Spring and Kafka</p>"}}"#)
        let connector = try bullhorn(stub)
        let candidate = try await connector.candidate(id: "88")
        XCTAssertEqual(candidate.resume?.filename, "jane.pdf", "the newest résumé that is not deleted")
        XCTAssertEqual(candidate.resume?.url.absoluteString, "https://rest99.bullhornstaffing.com/rest-services/abc1/file/Candidate/88/3/raw")
        XCTAssertEqual(candidate.resume?.needsAuth, true)
        let match = try await connector.findCandidate(email: "jane@example.com")
        XCTAssertEqual(match?.candidate.externalID, "88", "only an exact email match")
        let job = try await connector.job(id: "12")
        XCTAssertEqual(job.description, "Spring and Kafka")
    }

    func testBullhornDataCenterLookupBeforeSignIn() async throws {
        let stub = StubTransport()
        stub.on("GET", "rest.bullhornstaffing.com/rest-services/loginInfo?username=acme.api", json: #"{"oauthUrl":"https://auth-east.bullhornstaffing.com/oauth","restUrl":"https://rest-east.bullhornstaffing.com/rest-services"}"#)
        let fields = try await ConnectorOAuth.prepareSignIn(.bullhorn, fields: ["username": "acme.api", "clientID": "c"], transport: stub)
        XCTAssertEqual(fields["oauthURL"], "https://auth-east.bullhornstaffing.com/oauth")
        let provider = try XCTUnwrap(ConnectorOAuth.provider(.bullhorn, ConnectorCredentials(fields: fields)))
        XCTAssertEqual(provider.authorizeURL.absoluteString, "https://auth-east.bullhornstaffing.com/oauth/authorize")
        XCTAssertEqual(provider.tokenURL.absoluteString, "https://auth-east.bullhornstaffing.com/oauth/token")
        XCTAssertEqual(ConnectorOAuth.redirectPort(.bullhorn), 53_871)
        XCTAssertEqual(ConnectorOAuth.redirectPort(.google), 0)

        let spoofed = StubTransport()
        spoofed.on("GET", "loginInfo", json: #"{"oauthUrl":"https://evil.example.com/oauth","restUrl":"https://evil.example.com/rest"}"#)
        do {
            _ = try await ConnectorOAuth.prepareSignIn(.bullhorn, fields: ["username": "x"], transport: spoofed)
            XCTFail("a sign-in host outside bullhornstaffing.com is refused")
        } catch {}
    }

    func testJobAdderMergesInterviewsAndSchedulerEvents() async throws {
        let stub = StubTransport()
        stub.on("GET", "api.jobadder.com/v2/interviews?", json: #"""
        {"items":[{"interviewId":701,"type":"External","startAt":"2026-11-10T15:00:00Z","endAt":"2026-11-10T16:00:00Z","location":"https://meet.google.com/abc-defg-hij",
          "interviewee":{"applicationId":333,"jobTitle":"Payroll Officer","candidate":{"candidateId":44,"firstName":"Ana","lastName":"Pop","email":"ana@example.com"},"job":{"jobId":9,"jobTitle":"Payroll Officer"}},
          "interviewers":{"users":[{"firstName":"Lee","lastName":"Smith","email":"lee@agency.com"}],"contacts":[]}}],"totalCount":1}
        """#)
        stub.on("GET", "api.jobadder.com/v2/events?", json: #"""
        {"items":[{"eventId":"e-1","eventType":"Interview","title":"Interview: Ana Pop","startTimeUtc":"2026-11-10T15:00:00Z","endTimeUtc":"2026-11-10T16:00:00Z",
          "videoConferenceUrl":"https://meet.google.com/abc-defg-hij","job":{"jobId":9,"jobTitle":"Payroll Officer"},
          "candidates":[{"candidateId":44,"firstName":"Ana","lastName":"Pop","email":"ana@example.com"}],"users":[]},
         {"eventId":"e-2","eventType":"Interview","title":"Interview: Max Roe","startTimeUtc":"2026-11-12T15:00:00Z",
          "candidates":[{"candidateId":45,"firstName":"Max","lastName":"Roe","email":"max@example.com"}],"users":[]}]}
        """#)
        let connector = try JobAdderConnector(credentials: ConnectorCredentials(fields: [:]), transport: stub, accessToken: { "ja" })
        let interviews = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(interviews.count, 2, "the same interview in both lists counts once")
        XCTAssertEqual(interviews[0].candidate?.externalID, "44")
        XCTAssertEqual(interviews[0].applicationID, "333")
        XCTAssertEqual(interviews[0].job?.title, "Payroll Officer")
        XCTAssertEqual(interviews[1].externalID, "event-e-2")
        let list = try XCTUnwrap(stub.requests(containing: "/interviews?").first?.url?.absoluteString)
        XCTAssertTrue(list.contains("StartAt=%3E2026-11-07T00:00:00Z") && list.contains("StartAt=%3C2026-11-21T00:00:00Z"), list)
    }

    func testJobAdderSchedulerFailureIsANoteNotAnError() async throws {
        let stub = StubTransport()
        stub.on("GET", "/interviews?", json: #"{"items":[],"totalCount":0}"#)
        stub.on("GET", "/events?", status: 403, json: #"{"message":"insufficient scope"}"#)
        let connector = try JobAdderConnector(credentials: ConnectorCredentials(fields: [:]), transport: stub, accessToken: { "ja" })
        let notes = SyncNotes()
        let interviews = try await SyncNotes.$current.withValue(notes) { try await connector.upcomingInterviews(from: from, to: to) }
        XCTAssertTrue(interviews.isEmpty)
        XCTAssertEqual(notes.messages.count, 1)
        XCTAssertThrowsError(try JobAdderConnector(credentials: ConnectorCredentials(fields: ["apiURL": "https://evil.example.com/v2"]),
                                                   transport: stub, accessToken: { "ja" }), "the token only goes to jobadder.com")
    }

    func testJobAdderResumeAndExactLookup() async throws {
        let stub = StubTransport()
        stub.on("GET", "candidates/44/attachments", json: #"{"items":[{"attachmentId":555,"type":"Resume","fileName":"ana-cv.docx"}]}"#)
        stub.on("GET", "candidates/44", json: #"{"candidateId":44,"firstName":"Ana","lastName":"Pop","email":"ana@example.com"}"#)
        stub.on("GET", "v2/candidates?", json: #"{"items":[{"candidateId":46,"firstName":"Anna","email":"anna@example.com"}]}"#)
        stub.on("GET", "jobs/9", json: #"{"jobId":9,"jobTitle":"Payroll Officer","jobDescription":"<p>Run payroll</p>"}"#)
        let connector = try JobAdderConnector(credentials: ConnectorCredentials(fields: [:]), transport: stub, accessToken: { "ja" })
        let candidate = try await connector.candidate(id: "44")
        XCTAssertEqual(candidate.resume?.url.absoluteString, "https://api.jobadder.com/v2/candidates/44/attachments/555")
        let match = try await connector.findCandidate(email: "ana@example.com")
        XCTAssertNil(match, "a filter that returned someone else is not a match")
        let job = try await connector.job(id: "9")
        XCTAssertEqual(job.description, "Run payroll")
    }
}

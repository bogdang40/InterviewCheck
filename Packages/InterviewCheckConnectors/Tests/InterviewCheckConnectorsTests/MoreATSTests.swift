import XCTest
@testable import InterviewCheckConnectors

final class MoreATSTests: XCTestCase {
    private let from = date("2026-11-07T00:00:00Z")
    private let to = date("2026-11-21T00:00:00Z")

    func testRecruiteeEventsResolveReferences() async throws {
        let stub = StubTransport()
        stub.on("GET", "/c/123/interview/events?", json: #"{"references":[{"id":11668,"type":"Admin","email":"john@acme.com","first_name":"John","last_name":"Doe"},{"id":3318,"type":"Candidate","name":"Jane Roe","emails":["jane@example.com"]},{"id":2792,"type":"Offer","title":"Elixir Developer","description":"<p>Elixir</p>","requirements":"<ul><li>OTP</li></ul>"}],"interview_events":[{"id":216,"starts_at":"2026-11-10T17:00:00.742507Z","duration":60,"location":"https://meet.google.com/abc-defg-hij","video_url":null,"candidate_id":3318,"offer_id":2792,"admin_ids":[11668]}]}"#)
        stub.on("GET", "/c/123/admin", json: #"{"admin":{"id":11668,"email":"john@acme.com"}}"#)
        stub.on("POST", "/c/123/candidates/3318/notes", status: 201, json: #"{"note":{"id":1}}"#)
        let connector = try RecruiteeConnector(credentials: ConnectorCredentials(fields: ["companyID": "123", "apiKey": "t"]), transport: stub)
        let interviews = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(interviews.count, 1)
        XCTAssertEqual(interviews[0].candidate, ExternalCandidate(externalID: "3318", name: "Jane Roe", email: "jane@example.com"))
        XCTAssertEqual(interviews[0].job?.description, "Elixir\n\n\u{2022} OTP")
        XCTAssertEqual(interviews[0].endsAt?.timeIntervalSince(interviews[0].startsAt), 3600)
        XCTAssertEqual(interviews[0].interviewers.first?.name, "John Doe")
        XCTAssertTrue(stub.requests[0].url!.absoluteString.contains("scope=my"))
        try await connector.addNote("Note", to: interviews[0])
        let note = stub.bodyJSON(try XCTUnwrap(stub.requests(containing: "/notes").first))
        XCTAssertEqual(note.at("note.visibility.level").string, "protected")
        XCTAssertEqual(note.at("note.visibility.admin_ids.0").double, 11668)
    }

    func testZohoRefreshesTokenAndSearchesInterviews() async throws {
        let stub = StubTransport()
        stub.on("POST", "accounts.zoho.eu/oauth/v2/token", json: #"{"access_token":"zt","expires_in":3600}"#)
        stub.on("GET", "recruit.zoho.eu/recruit/v2/Interviews/search", json: #"{"data":[{"id":"9001","Interview_Name":"Technical","Start_DateTime":"2026-11-10T14:00:00+00:00","End_DateTime":"2026-11-10T15:00:00+00:00","Candidate_Name":{"name":"Ana Pop","id":"c1"},"Job_Opening_Name":{"name":"iOS Engineer","id":"j1"},"Interviewer":[{"name":"Dan"}],"Interview_Status":"Scheduled"}],"info":{"more_records":false}}"#)
        let connector = try ZohoRecruitConnector(credentials: ConnectorCredentials(fields: ["domain": "zoho.eu", "clientID": "c", "clientSecret": "s",
                                                                                          "refreshToken": "r"]), transport: stub)
        let interviews = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(interviews.first?.candidate?.name, "Ana Pop")
        XCTAssertEqual(interviews.first?.job?.externalID, "j1")
        let search = try XCTUnwrap(stub.requests(containing: "Interviews/search").first)
        XCTAssertEqual(search.value(forHTTPHeaderField: "Authorization"), "Zoho-oauthtoken zt")
        XCTAssertTrue(search.url!.absoluteString.contains("Start_DateTime:between:2026-11-07T00:00:00%2B00:00"))
        let refresh = String(decoding: try XCTUnwrap(stub.requests(containing: "oauth/v2/token").first?.httpBody), as: UTF8.self)
        XCTAssertTrue(refresh.contains("grant_type=refresh_token") && refresh.contains("refresh_token=r"))
    }

    func testSmartRecruitersInterviewsThroughApplications() async throws {
        let stub = StubTransport()
        stub.on("GET", "/candidates/c1/jobs/j1", json: #"{"id":"app1","status":"INTERVIEW"}"#)
        stub.on("GET", "/candidates?", json: #"{"content":[{"id":"c1","firstName":"Ana","lastName":"Pop","email":"ana@x.com","primaryAssignment":{"job":{"id":"j1","title":"iOS Engineer"},"status":"INTERVIEW"}}]}"#)
        stub.on("GET", "/interviews-api/v201904/interviews?", json: #"{"content":[{"id":"iv","location":"Zoom","timeslots":[{"id":"ts1","title":"Tech round","place":"https://zoom.us/j/1","startsOn":"2026-11-10T14:00:00.000Z","endsOn":"2026-11-10T15:00:00.000Z"},{"id":"ts0","startsOn":"2026-10-01T14:00:00.000Z"}]}]}"#)
        let connector = try SmartRecruitersConnector(credentials: ConnectorCredentials(fields: ["apiKey": "sk"]), transport: stub)
        let interviews = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(interviews.map(\.externalID), ["ts1"])
        XCTAssertEqual(interviews[0].applicationID, "app1")
        XCTAssertEqual(interviews[0].job?.title, "iOS Engineer")
        XCTAssertEqual(stub.requests[0].value(forHTTPHeaderField: "X-SmartToken"), "sk")
        XCTAssertThrowsError(try SmartRecruitersConnector(credentials: ConnectorCredentials(), transport: stub))
    }

    func testTeamtailorVersionHeaderJobAndJSONAPINote() async throws {
        let stub = StubTransport()
        stub.on("GET", "/v1/jobs/1", json: #"{"data":{"id":"1","type":"jobs","attributes":{"title":"Account Manager","body":"<p>hello</p>"}}}"#)
        stub.on("GET", "/v1/candidates?", json: #"{"data":[{"id":"7","type":"candidates","attributes":{"first-name":"Mariann","last-name":"Koch","email":"m@example.com","resume":"https://signed.example.com/r.pdf"}}]}"#)
        stub.on("POST", "/v1/notes", status: 201, json: #"{"data":{"id":"n1"}}"#)
        let connector = try TeamtailorConnector(credentials: ConnectorCredentials(fields: ["apiKey": "k", "userID": "3"]), transport: stub)
        let job = try await connector.job(id: "1")
        XCTAssertEqual(job.description, "hello")
        XCTAssertEqual(stub.requests[0].value(forHTTPHeaderField: "X-Api-Version"), "20240904")
        XCTAssertEqual(stub.requests[0].value(forHTTPHeaderField: "Authorization"), "Token token=k")
        let match = try await connector.findCandidate(email: "m@example.com")
        XCTAssertEqual(match?.candidate.name, "Mariann Koch")
        XCTAssertEqual(match?.candidate.resume?.url.host, "signed.example.com")
        try await connector.addNote("Note", to: ExternalInterview(source: .teamtailor, externalID: "x", title: "", startsAt: from,
                                                                  candidate: match?.candidate))
        let request = try XCTUnwrap(stub.requests(containing: "/v1/notes").first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/vnd.api+json")
        XCTAssertEqual(stub.bodyJSON(request).at("data.relationships.candidate.data.id").string, "7")
    }

    func testLookupsByEmail() async throws {
        let stub = StubTransport()
        stub.on("POST", "auth.greenhouse.io/token", json: #"{"access_token":"t","expires_in":3600}"#)
        stub.on("GET", "/v3/candidates?", json: #"[{"id":41,"first_name":"Pete","last_name":"Current","email_addresses":[{"value":"pete@example.com"}]}]"#)
        stub.on("GET", "/v3/applications?", json: #"[{"id":21,"candidate_id":41,"job_id":31}]"#)
        stub.on("GET", "/v3/jobs?", json: #"[{"id":31,"name":"Backend Engineer"}]"#)
        let greenhouse = try GreenhouseConnector(credentials: ConnectorCredentials(fields: ["clientID": "c", "clientSecret": "s"]), transport: stub)
        let match = try await greenhouse.findCandidate(email: "pete@example.com")
        XCTAssertEqual(match, CandidateMatch(candidate: ExternalCandidate(externalID: "41", name: "Pete Current", email: "pete@example.com",
                                                                          profileURL: URL(string: "https://app.greenhouse.io/people/41")),
                                             job: ExternalJob(externalID: "31", title: "Backend Engineer"), applicationID: "21"))
        XCTAssertTrue(stub.requests(containing: "/v3/candidates?").first!.url!.absoluteString.contains("email=pete@example.com"))

        let kombo = StubTransport()
        kombo.on("GET", "/ats/candidates?", json: #"{"status":"success","data":{"next":null,"results":[{"id":"C1","first_name":"John","last_name":"Doe","applications":[{"id":"A0","outcome":"DECLINED","job":{"id":"J0","name":"Old"}},{"id":"A1","outcome":"PENDING","job":{"id":"J1","name":"Backend Engineer"}}]}]}}"#)
        let connector = try KomboConnector(credentials: ConnectorCredentials(fields: ["apiKey": "k", "integrationID": "i"]), transport: kombo)
        let found = try await connector.findCandidate(email: "john@example.com")
        XCTAssertEqual(found?.applicationID, "A1", "the open application wins")
        XCTAssertEqual(found?.job?.title, "Backend Engineer")
        let none = StubTransport()
        none.on("GET", "/ats/candidates?", json: #"{"status":"success","data":{"next":null,"results":[]}}"#)
        let empty = try KomboConnector(credentials: ConnectorCredentials(fields: ["apiKey": "k", "integrationID": "i"]), transport: none)
        let missing = try await empty.findCandidate(email: "nobody@example.com")
        XCTAssertNil(missing)
    }

    func testEveryCatalogedATSIsBuiltOrRoutedThroughAUnifiedAPI() {
        for kind in ConnectorKind.allCases where [.ats, .unified].contains(kind.descriptor.category) {
            let routed = [ConnectorKind.workday, .icims].contains(kind)
            XCTAssertTrue(ConnectorFactory.implemented.contains(kind) || routed, kind.rawValue)
        }
    }
}

final class JobListingTests: XCTestCase {
    func testGreenhouseAndMergeOpenJobs() async throws {
        let stub = StubTransport()
        stub.on("POST", "auth.greenhouse.io/token", json: #"{"access_token":"t","expires_in":3600}"#)
        stub.on("GET", "/v3/jobs?", json: #"[{"id":31,"name":"Backend Engineer","status":"open"},{"id":32,"name":"Designer","status":"open"}]"#)
        let greenhouse = try GreenhouseConnector(credentials: ConnectorCredentials(fields: ["clientID": "c", "clientSecret": "s"]), transport: stub)
        let jobs = try await greenhouse.openJobs()
        XCTAssertEqual(jobs.map(\.title), ["Backend Engineer", "Designer"])
        XCTAssertTrue(stub.requests(containing: "/v3/jobs?").first!.url!.absoluteString.contains("status=open"))

        let merge = StubTransport()
        merge.on("GET", "/jobs?", json: #"{"next":null,"results":[{"id":"j1","name":"SRE","description":"<p>Keep it up.</p>","status":"OPEN"}]}"#)
        let connector = try MergeConnector(credentials: ConnectorCredentials(fields: ["apiKey": "k", "accountToken": "a"]), transport: merge)
        let open = try await connector.openJobs()
        XCTAssertEqual(open, [ExternalJob(externalID: "j1", title: "SRE", description: "Keep it up.")])
    }
}

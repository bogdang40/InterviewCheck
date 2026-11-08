import XCTest
@testable import InterviewCheckConnectors

final class UnifiedConnectorTests: XCTestCase {
    private let from = date("2026-11-07T00:00:00Z")
    private let to = date("2026-11-21T00:00:00Z")

    func testMergeInterviewsFilteredLocallyWithCandidateAndJob() async throws {
        let stub = StubTransport()
        stub.on("GET", "/interviews?", json: #"{"next":null,"results":[{"id":"iv1","application":{"id":"app1","candidate":"cand1","job":"job1"},"interviewers":[{"first_name":"Ana","last_name":"Pop","email":"ana@acme.com"}],"location":"https://acme.zoom.us/j/555","start_at":"2026-11-10T15:00:00Z","end_at":"2026-11-10T16:00:00Z","status":"SCHEDULED","remote_was_deleted":false},{"id":"old","start_at":"2026-10-01T15:00:00Z","status":"SCHEDULED"},{"id":"gone","start_at":"2026-11-10T15:00:00Z","remote_was_deleted":true}]}"#)
        stub.on("GET", "/candidates/cand1", json: #"{"id":"cand1","first_name":"Gil","last_name":"Feig","email_addresses":[{"value":"gil@example.com","email_address_type":"PERSONAL"}]}"#)
        stub.on("GET", "/jobs/job1", json: #"{"id":"job1","name":"Senior Backend Engineer","description":"<p>We are hiring.</p>"}"#)
        stub.on("POST", "/activities", status: 201, json: #"{"model":{}}"#)
        let connector = try MergeConnector(credentials: ConnectorCredentials(fields: ["apiKey": "k", "accountToken": "acct", "region": "eu", "remoteUserID": "17"]),
                                           transport: stub)
        let interviews = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(interviews.map(\.externalID), ["iv1"])
        XCTAssertEqual(interviews[0].candidate?.name, "Gil Feig")
        XCTAssertEqual(interviews[0].job?.title, "Senior Backend Engineer")
        XCTAssertEqual(interviews[0].meetingURL?.host, "acme.zoom.us")
        XCTAssertEqual(interviews[0].applicationID, "app1")
        XCTAssertTrue(stub.requests[0].url!.absoluteString.hasPrefix("https://api-eu.merge.dev/api/ats/v1/interviews"))
        XCTAssertEqual(stub.requests[0].value(forHTTPHeaderField: "X-Account-Token"), "acct")

        try await connector.addNote("Note", to: interviews[0])
        let body = stub.bodyJSON(try XCTUnwrap(stub.requests(containing: "/activities").first))
        XCTAssertEqual(body["remote_user_id"].string, "17")
        XCTAssertEqual(body.at("model.visibility").string, "PRIVATE")
        XCTAssertEqual(body.at("model.candidate").string, "cand1")
    }

    func testKomboOneCallInterviewsAndApplicationNote() async throws {
        let stub = StubTransport()
        stub.on("GET", "/ats/interviews?", json: #"{"status":"success","data":{"next":null,"results":[{"id":"k1","title":"Interview with John Doe","starting_at":"2026-11-12T14:30:00.000Z","ending_at":"2026-11-12T15:30:00.000Z","location":{"raw":"Berlin"},"video_conferencing_url":"https://meet.example.com/abc","application_id":"A1","canceled":false,"remote_deleted_at":null,"users":[{"first_name":"Jane","last_name":"Lead","email":"jane@kombo.dev"}],"application":{"id":"A1","candidate":{"id":"C1","first_name":"John","last_name":"Doe","email_addresses":[{"email_address":"john@example.com","type":"PRIVATE"}]},"job":{"id":"J1","name":"Backend Engineer"}}},{"id":"k2","starting_at":"2026-11-12T14:30:00Z","canceled":true}]}}"#)
        stub.on("POST", "/ats/applications/A1/notes", json: #"{"status":"success","data":{}}"#)
        let connector = try KomboConnector(credentials: ConnectorCredentials(fields: ["apiKey": "k", "integrationID": "greenhousev3:abc", "region": "us"]),
                                           transport: stub)
        let interviews = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(interviews.count, 1)
        XCTAssertEqual(interviews[0].candidate, ExternalCandidate(externalID: "C1", name: "John Doe", email: "john@example.com"))
        XCTAssertEqual(interviews[0].job, ExternalJob(externalID: "J1", title: "Backend Engineer"))
        XCTAssertEqual(interviews[0].meetingURL?.absoluteString, "https://meet.example.com/abc")
        XCTAssertTrue(stub.requests[0].url!.absoluteString.hasPrefix("https://api.us.kombo.dev/v1/ats/interviews"))
        XCTAssertEqual(stub.requests[0].value(forHTTPHeaderField: "X-Integration-Id"), "greenhousev3:abc")

        try await connector.addNote("Note", to: interviews[0])
        let body = stub.bodyJSON(try XCTUnwrap(stub.requests(containing: "/notes").first))
        XCTAssertEqual(body["content_type"].string, "PLAIN_TEXT")
        XCTAssertEqual(body.at("remote_fields.greenhousev3.visibility").string, "private")
    }

    func testUnifiedToOffsetPagingAndLookups() async throws {
        let stub = StubTransport()
        stub.on("GET", "/ats/conn9/interview?", json: #"[{"id":"u1","candidate_id":"cand_9","job_id":"job_4","application_id":"app_7","status":"SCHEDULED","start_at":"2026-11-10T15:00:00Z","end_at":"2026-11-10T16:00:00Z","meeting_url":"https://zoom.us/j/123"},{"id":"u2","status":"CANCELED","start_at":"2026-11-10T15:00:00Z"}]"#)
        stub.on("GET", "/ats/conn9/candidate/cand_9", json: #"{"id":"cand_9","name":"Gil Feig","emails":[{"email":"gil@example.com","type":"HOME"}]}"#)
        stub.on("GET", "/ats/conn9/job/job_4", json: #"{"id":"job_4","name":"Senior Backend Engineer","description":"<p>Hiring</p>"}"#)
        stub.on("GET", "/ats/conn9/document?", json: #"[{"id":"doc_1","type":"RESUME","filename":"resume.pdf","document_url":"https://files.unified.to/x"}]"#)
        let connector = try UnifiedToConnector(credentials: ConnectorCredentials(fields: ["apiKey": "t", "connectionID": "conn9"]), transport: stub)
        let interviews = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(interviews.map(\.externalID), ["u1"])
        XCTAssertEqual(interviews[0].candidate?.email, "gil@example.com")
        XCTAssertEqual(interviews[0].job?.title, "Senior Backend Engineer")
        XCTAssertTrue(stub.requests[0].url!.absoluteString.contains("limit=100&offset=0"))
        let candidate = try await connector.candidate(id: "cand_9")
        XCTAssertEqual(candidate.resume?.filename, "resume.pdf")
        let job = try await connector.job(id: "job_4")
        XCTAssertEqual(job.description, "Hiring")
    }

    func testApideckJobsAndApplicantsOnly() async throws {
        let stub = StubTransport()
        stub.on("GET", "/ats/applicants/12345", json: #"{"data":{"id":"12345","name":"Elon Musk","emails":[{"email":"elon@musk.com","type":"primary"}],"cv_url":"https://cv.example.com/x.pdf"}}"#)
        stub.on("GET", "/ats/jobs/7890", json: #"{"data":{"id":"7890","title":"Senior Backend Engineer","description":"We are hiring","description_html":"<p>We are hiring</p>"}}"#)
        let connector = try ApideckConnector(credentials: ConnectorCredentials(fields: ["apiKey": "k", "appID": "a", "consumerID": "c"]), transport: stub)
        let candidate = try await connector.candidate(id: "12345")
        XCTAssertEqual(candidate.resume?.url.host, "cv.example.com")
        let job = try await connector.job(id: "7890")
        XCTAssertEqual(job.description, "We are hiring")
        XCTAssertEqual(stub.requests[0].value(forHTTPHeaderField: "x-apideck-consumer-id"), "c")
        XCTAssertFalse((connector as Connector) is InterviewSource)
    }
}

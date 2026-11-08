import XCTest
@testable import InterviewCheckConnectors

final class GreenhouseLeverTests: XCTestCase {
    private let from = date("2026-11-07T00:00:00Z")
    private let to = date("2026-11-21T00:00:00Z")

    func testGreenhouseInterviewsWithCandidateJobAndInterviewers() async throws {
        let stub = StubTransport()
        stub.on("POST", "auth.greenhouse.io/token", json: #"{"token_type":"Bearer","access_token":"tok","expires_in":3600}"#)
        // The cursor page is registered first: routes match by substring, earliest first.
        stub.on("GET", "/v3/interviews?cursor=abc", json: #"[{"id":12,"application_id":22,"job_id":31,"starts_at":"2026-11-11T09:00:00Z","location":"Join https://meet.google.com/abc-defg-hij"}]"#)
        stub.on("GET", "/v3/interviews?", json: #"[{"id":11,"application_id":21,"job_id":31,"status":"scheduled","starts_at":"2026-11-10T15:00:00.000Z","ends_at":"2026-11-10T16:00:00.000Z","location":null,"video_conferencing_url":"https://zoom.us/j/123"}]"#,
                headers: ["Link": #"<https://harvest.greenhouse.io/v3/interviews?cursor=abc>; rel="next""#])
        stub.on("GET", "/v3/applications?", json: #"[{"id":21,"candidate_id":41,"job_id":31},{"id":22,"candidate_id":42,"job_id":31}]"#)
        stub.on("GET", "/v3/candidates?", json: #"[{"id":41,"first_name":"Pete","last_name":"Current","preferred_name":null,"email_addresses":[{"value":"pete@example.com","type":"personal"}]},{"id":42,"first_name":"Ana","last_name":"Silva","preferred_name":"Ani","email_addresses":[]}]"#)
        stub.on("GET", "/v3/jobs?", json: #"[{"id":31,"name":"Backend Engineer","status":"open"}]"#)
        stub.on("GET", "/v3/interviewers?", json: #"[{"id":1,"interview_id":11,"user_id":5,"email":"lee@acme.com"}]"#)

        let connector = try GreenhouseConnector(credentials: ConnectorCredentials(fields: ["clientID": "cid", "clientSecret": "sec", "userID": "99"]),
                                                transport: stub)
        let interviews = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(interviews.count, 2)
        let first = interviews[0]
        XCTAssertEqual(first.id, "greenhouse:11")
        XCTAssertEqual(first.candidate?.name, "Pete Current")
        XCTAssertEqual(first.candidate?.email, "pete@example.com")
        XCTAssertEqual(first.candidate?.externalID, "41")
        XCTAssertEqual(first.job?.title, "Backend Engineer")
        XCTAssertEqual(first.meetingURL?.absoluteString, "https://zoom.us/j/123")
        XCTAssertEqual(first.interviewers.map(\.email), ["lee@acme.com"])
        XCTAssertEqual(interviews[1].candidate?.name, "Ani Silva", "preferred name wins")
        XCTAssertEqual(interviews[1].meetingURL?.host, "meet.google.com")

        let token = try XCTUnwrap(stub.requests(containing: "auth.greenhouse.io").first)
        XCTAssertEqual(token.value(forHTTPHeaderField: "Authorization"), APIClient.basic("cid", "sec"))
        XCTAssertTrue(String(decoding: token.httpBody!, as: UTF8.self).contains("sub=99"))
        XCTAssertEqual(stub.requests(containing: "auth.greenhouse.io").count, 1, "the token is reused")
        let list = try XCTUnwrap(stub.requests(containing: "/v3/interviews?status").first?.url?.absoluteString)
        XCTAssertTrue(list.contains("starts_at%5Bgte%5D=2026-11-07T00:00:00Z") || list.contains("starts_at[gte]=2026-11-07T00:00:00Z"))
        XCTAssertEqual(stub.requests(containing: "cursor=abc").first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testGreenhouseJobPostResumeAndPrivateNote() async throws {
        let stub = StubTransport()
        stub.on("POST", "auth.greenhouse.io/token", json: #"{"access_token":"tok","expires_in":3600}"#)
        stub.on("GET", "/v3/jobs?", json: #"[{"id":31,"name":"Internal title"}]"#)
        stub.on("GET", "/v3/job_posts?", json: #"[{"id":2,"title":"Old","content":"x","internal":true,"live":false},{"id":3,"title":"Backend Engineer","content":"&lt;p&gt;Build &lt;b&gt;payments&lt;/b&gt;&lt;/p&gt;","internal":false,"live":true}]"#)
        stub.on("GET", "/v3/candidates?", json: #"[{"id":41,"first_name":"Pete","last_name":"Current","email_addresses":[]}]"#)
        stub.on("GET", "/v3/attachments?", json: #"[{"id":1,"type":"resume","filename":"pete.pdf","url":"https://files.example.com/signed"}]"#)
        stub.on("POST", "/v3/notes", status: 201, json: #"{"id":5}"#)
        let connector = try GreenhouseConnector(credentials: ConnectorCredentials(fields: ["clientID": "c", "clientSecret": "s"]), transport: stub)

        let job = try await connector.job(id: "31")
        XCTAssertEqual(job.title, "Backend Engineer")
        XCTAssertEqual(job.description, "Build payments")
        let candidate = try await connector.candidate(id: "41")
        XCTAssertEqual(candidate.resume?.url.absoluteString, "https://files.example.com/signed")
        XCTAssertEqual(candidate.resume?.needsAuth, false)

        let interview = ExternalInterview(source: .greenhouse, externalID: "11", title: "", startsAt: from,
                                          candidate: candidate, applicationID: "21")
        try await connector.addNote("Signal only", to: interview)
        let note = stub.bodyJSON(try XCTUnwrap(stub.requests(containing: "/v3/notes").first))
        XCTAssertEqual(note["candidate_id"].double, 41)
        XCTAssertEqual(note["application_id"].double, 21)
        XCTAssertEqual(note["visibility"].string, "private")
        XCTAssertEqual(note["note_type"].string, "NOTE")
    }

    func testGreenhouseMissingCredentialsAndBadSecret() async throws {
        XCTAssertThrowsError(try GreenhouseConnector(credentials: ConnectorCredentials(fields: ["clientID": "c"]), transport: StubTransport()))
        let stub = StubTransport()
        stub.on("POST", "auth.greenhouse.io/token", status: 400, json: #"{"error":"invalid_client"}"#)
        let connector = try GreenhouseConnector(credentials: ConnectorCredentials(fields: ["clientID": "c", "clientSecret": "bad"]), transport: stub)
        await XCTAssertThrowsAsync(try await connector.verify(), .unauthorized)
    }

    func testLeverReadsInterviewsPerOpportunity() async throws {
        let stub = StubTransport()
        stub.on("GET", "/v1/opportunities?", json: #"{"data":[{"id":"opp1","name":"Shane Smith","emails":["shane@example.com"]},{"id":"opp2","name":"No Interviews"}],"hasNext":false}"#)
        stub.on("GET", "/opportunities/opp1/interviews", json: #"{"data":[{"id":"iv1","subject":"On-site interview - Shane Smith","interviewers":[{"name":"Rachel Green","email":"rachel@acme.com"}],"date":1794150000000,"duration":45,"location":"Call","canceledAt":null,"postings":["post1"],"conferences":[{"source":"Zoom","entryPoints":[{"type":"video","uri":"https://zoom.us/j/999"}]}]},{"id":"iv2","date":1794150000000,"canceledAt":1700000000000},{"id":"iv3","date":1000000000000,"canceledAt":null}],"hasNext":false}"#)
        stub.on("GET", "/opportunities/opp2/interviews", json: #"{"data":[],"hasNext":false}"#)
        stub.on("GET", "/postings/post1", json: #"{"data":{"id":"post1","text":"Infrastructure Engineer"}}"#)
        let connector = try LeverConnector(credentials: ConnectorCredentials(fields: ["apiKey": "key"]), transport: stub)

        let interviews = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(interviews.map(\.externalID), ["iv1"], "cancelled and past interviews are left out")
        let interview = interviews[0]
        XCTAssertEqual(interview.startsAt, date("2026-11-08T15:00:00Z"))
        XCTAssertEqual(interview.endsAt, date("2026-11-08T15:45:00Z"))
        XCTAssertEqual(interview.candidate?.name, "Shane Smith")
        XCTAssertEqual(interview.job?.title, "Infrastructure Engineer")
        XCTAssertEqual(interview.meetingURL?.absoluteString, "https://zoom.us/j/999")
        XCTAssertEqual(interview.applicationID, "opp1")
        XCTAssertEqual(stub.requests[0].value(forHTTPHeaderField: "Authorization"), APIClient.basic("key"))
        XCTAssertTrue(stub.requests[0].url!.absoluteString.contains("archived=false"))
    }

    func testLeverPostingResumeAndSecretNote() async throws {
        let stub = StubTransport()
        stub.on("GET", "/postings/p1", json: #"{"data":{"text":"Infra","content":{"descriptionHtml":"<div>Run the platform.</div>","lists":[{"text":"Requirements","content":"<li>Go</li>"}],"closingHtml":"<p>EOE</p>"}}}"#)
        stub.on("GET", "/opportunities/opp1/resumes", json: #"{"data":[{"id":"r1","file":{"name":"shane.pdf","status":"processed"}}]}"#)
        stub.on("GET", "/opportunities/opp1", json: #"{"data":{"id":"opp1","name":"Shane Smith","emails":["s@x.com"]}}"#)
        stub.on("POST", "/opportunities/opp1/notes", status: 201, json: #"{"data":{"noteId":"n1"}}"#)
        let connector = try LeverConnector(credentials: ConnectorCredentials(fields: ["apiKey": "key"]), transport: stub)

        let job = try await connector.job(id: "p1")
        XCTAssertEqual(job.description, "Run the platform.\n\nRequirements\n\n\u{2022} Go\n\nEOE")
        let candidate = try await connector.candidate(id: "opp1")
        XCTAssertEqual(candidate.resume?.url.absoluteString, "https://api.lever.co/v1/opportunities/opp1/resumes/r1/download")
        XCTAssertEqual(candidate.resume?.needsAuth, true)
        try await connector.addNote("Note", to: ExternalInterview(source: .lever, externalID: "iv1", title: "", startsAt: from,
                                                                  applicationID: "opp1"))
        let note = stub.bodyJSON(try XCTUnwrap(stub.requests(containing: "/notes").first))
        XCTAssertEqual(note["secret"].bool, true)
        XCTAssertEqual(note["value"].string, "Note")
    }
}

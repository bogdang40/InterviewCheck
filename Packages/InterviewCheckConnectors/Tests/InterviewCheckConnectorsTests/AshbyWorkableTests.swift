import XCTest
@testable import InterviewCheckConnectors

final class AshbyWorkableTests: XCTestCase {
    private let from = date("2026-11-07T00:00:00Z")
    private let to = date("2026-11-21T00:00:00Z")

    func testAshbyScheduledEventsWithApplication() async throws {
        let stub = StubTransport()
        stub.on("POST", "/interviewSchedule.list", json: #"{"success":true,"results":[{"id":"s1","status":"Scheduled","applicationId":"app1","interviewEvents":[{"id":"e1","startTime":"2026-11-10T15:00:00.000Z","endTime":"2026-11-10T16:00:00.000Z","interviewers":[{"firstName":"George","lastName":"Bluth","email":"george@bluth.example"}],"meetingLink":"https://meet.google.com/abc-defg-hij"},{"id":"e0","startTime":"2026-10-01T15:00:00.000Z"}]},{"id":"s2","status":"Cancelled","applicationId":"app2","interviewEvents":[{"id":"e2","startTime":"2026-11-10T15:00:00.000Z"}]}],"moreDataAvailable":false}"#)
        stub.on("POST", "/application.info", json: #"{"success":true,"results":{"id":"app1","candidate":{"id":"c1","name":"Adam Hart","primaryEmailAddress":{"value":"adam@example.com"}},"job":{"id":"j1","title":"First Designer"}}}"#)
        let connector = try AshbyConnector(credentials: ConnectorCredentials(fields: ["apiKey": "k"]), transport: stub)

        let interviews = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(interviews.map(\.externalID), ["e1"])
        XCTAssertEqual(interviews[0].candidate, ExternalCandidate(externalID: "c1", name: "Adam Hart", email: "adam@example.com"))
        XCTAssertEqual(interviews[0].job?.externalID, "j1")
        XCTAssertEqual(interviews[0].interviewers.first?.name, "George Bluth")
        XCTAssertEqual(stub.requests[0].value(forHTTPHeaderField: "Accept"), "application/json; version=1")
        XCTAssertNotNil(stub.bodyJSON(stub.requests[0])["createdAfter"].double)
    }

    func testAshbyErrorsInsideA200AndResumeHandle() async throws {
        let stub = StubTransport()
        stub.on("POST", "/interviewSchedule.list", json: #"{"success":false,"errors":["missing_endpoint_permission"]}"#)
        stub.on("POST", "/candidate.info", json: #"{"success":true,"results":{"id":"c1","name":"Adam Hart","resumeFileHandle":{"name":"resume.pdf","handle":"eyJh+b/c="}}}"#)
        stub.on("POST", "/file.info", json: #"{"success":true,"results":{"url":"https://s3.example.com/resume.pdf"}}"#)
        stub.on("GET", "s3.example.com/resume.pdf", json: "PDFDATA", headers: ["Content-Type": "application/pdf"])
        stub.on("POST", "/candidate.createNote", json: #"{"success":true,"results":{"id":"n1"}}"#)
        let connector = try AshbyConnector(credentials: ConnectorCredentials(fields: ["apiKey": "k"]), transport: stub)

        await XCTAssertThrowsAsync(try await connector.verify(), .forbidden("missing_endpoint_permission"))
        let candidate = try await connector.candidate(id: "c1")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try await connector.download(try XCTUnwrap(candidate.resume), into: folder)
        XCTAssertEqual(file.lastPathComponent, "resume.pdf")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "PDFDATA")
        XCTAssertEqual(stub.bodyJSON(try XCTUnwrap(stub.requests(containing: "file.info").first))["fileHandle"].string, "eyJh+b/c=")

        try await connector.addNote("Note", to: ExternalInterview(source: .ashby, externalID: "e1", title: "", startsAt: from,
                                                                  candidate: candidate))
        let note = stub.bodyJSON(try XCTUnwrap(stub.requests(containing: "createNote").first))
        XCTAssertEqual(note["isPrivate"].bool, true)
        XCTAssertEqual(note.at("note.type").string, "text/plain")
    }

    func testWorkableEventsPagingJobAndComment() async throws {
        let stub = StubTransport()
        stub.on("GET", "acme.workable.com/spi/v3/events?", json: #"{"events":[{"id":"47fdddd","title":"Interview with Wayne Walsh","type":"InterviewEvent","starts_at":"2026-11-10T22:00:00.000Z","ends_at":"2026-11-10T22:30:00.000Z","cancelled":false,"job":{"shortcode":"GROOV001","title":"Operations Manager"},"members":[{"id":"m1","name":"Natalie Sung"}],"candidate":{"id":"2b50e243","name":"Wayne Walsh"},"conference":{"type":"zoom_meeting","url":"https://zoom.us/j/1100001"}}],"paging":{"next":"https://www.workable.com/spi/v3/accounts/acme/events?since_id=47fdddd"}}"#)
        stub.on("GET", "accounts/acme/events?since_id", json: #"{"events":[{"id":"x2","starts_at":"2026-11-12T10:00:00Z","cancelled":true}]}"#)
        stub.on("GET", "/jobs/GROOV001", json: #"{"title":"Operations Manager","full_description":"<p>Run operations.</p><p><strong>Requirements</strong></p><ul><li>Calm</li></ul>"}"#)
        stub.on("POST", "/candidates/2b50e243/comments", status: 201, json: "")
        let connector = try WorkableConnector(credentials: ConnectorCredentials(fields: ["subdomain": "https://acme.workable.com",
                                                                                        "apiKey": "tok", "memberID": "m1"]),
                                              transport: stub)
        let interviews = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(interviews.map(\.externalID), ["47fdddd"], "cancelled events are left out")
        XCTAssertEqual(interviews[0].candidate?.name, "Wayne Walsh")
        XCTAssertEqual(interviews[0].job?.externalID, "GROOV001")
        XCTAssertEqual(interviews[0].meetingURL?.absoluteString, "https://zoom.us/j/1100001")
        XCTAssertTrue(stub.requests[0].url!.absoluteString.contains("member_id=m1"))
        XCTAssertEqual(stub.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        let job = try await connector.job(id: "GROOV001")
        XCTAssertEqual(job.description, "Run operations.\n\nRequirements\n\n\u{2022} Calm")
        try await connector.addNote("Note", to: interviews[0])
        let comment = stub.bodyJSON(try XCTUnwrap(stub.requests(containing: "/comments").first))
        XCTAssertEqual(comment["member_id"].string, "m1")
        XCTAssertEqual(comment.at("comment.policy.0").string, "admin")
    }

    func testFactoryBuildsTheImplementedATSs() {
        for kind in [ConnectorKind.greenhouse, .lever, .ashby, .workable, .appleCalendar] {
            XCTAssertTrue(ConnectorFactory.implemented.contains(kind), kind.rawValue)
        }
    }
}

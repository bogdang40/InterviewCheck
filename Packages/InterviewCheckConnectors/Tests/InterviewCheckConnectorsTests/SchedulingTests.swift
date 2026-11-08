import XCTest
@testable import InterviewCheckConnectors

final class SchedulingTests: XCTestCase {
    private let from = date("2026-11-07T00:00:00Z")
    private let to = date("2026-11-21T00:00:00Z")

    func testCalendlyBookingsBecomeInterviews() async throws {
        let stub = StubTransport()
        stub.on("GET", "api.calendly.com/users/me", json: #"{"resource":{"uri":"https://api.calendly.com/users/U1","name":"Lee Engineer","email":"lee@acme.com"}}"#)
        stub.on("GET", "/scheduled_events/E1/invitees", json: #"{"collection":[{"name":"Jane Doe","email":"jane.doe@gmail.com","status":"active","questions_and_answers":[{"question":"LinkedIn","answer":"linkedin.com/in/janedoe","position":0}]}],"pagination":{"next_page":null}}"#)
        stub.on("GET", "page_token=abc", json: #"{"collection":[{"uri":"https://api.calendly.com/scheduled_events/E3","name":"Technical Interview","status":"active","start_time":"2026-11-12T15:00:00.000000Z","end_time":"2026-11-12T16:00:00.000000Z","location":{"type":"custom","location":"https://whereby.com/acme-room"},"event_memberships":[]}],"pagination":{"next_page":null}}"#)
        stub.on("GET", "/scheduled_events/E3/invitees", json: #"{"collection":[{"name":"Max Roe","email":"max@example.com","status":"active","questions_and_answers":[]}],"pagination":{"next_page":null}}"#)
        stub.on("GET", "api.calendly.com/scheduled_events?", json: #"""
        {"collection":[
          {"uri":"https://api.calendly.com/scheduled_events/E1","name":"Phone Screen - Backend Engineer","status":"active",
           "start_time":"2026-11-10T15:00:00.000000Z","end_time":"2026-11-10T15:30:00.000000Z",
           "location":{"type":"zoom","join_url":"https://acme.zoom.us/j/81234567890","status":"pushed"},
           "event_memberships":[{"user":"https://api.calendly.com/users/U1","user_email":"lee@acme.com","user_name":"Lee Engineer"}],
           "invitees_counter":{"total":1,"active":1,"limit":1}},
          {"uri":"https://api.calendly.com/scheduled_events/E2","name":"Coffee chat","status":"active",
           "start_time":"2026-11-11T15:00:00.000000Z","end_time":"2026-11-11T15:30:00.000000Z","location":{"type":"physical","location":"Cafe"},
           "event_memberships":[]}],
         "pagination":{"next_page":"https://api.calendly.com/scheduled_events?page_token=abc&count=100","next_page_token":"abc"}}
        """#)
        let connector = try CalendlyConnector(credentials: ConnectorCredentials(fields: ["apiKey": "pat"]), transport: stub)
        let interviews = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(interviews.map(\.externalID), ["E1", "E3"], "the coffee chat is not an interview; the second page is read")
        let screen = interviews[0]
        XCTAssertEqual(screen.candidate?.email, "jane.doe@gmail.com")
        XCTAssertEqual(screen.candidate?.profileURL?.absoluteString, "https://linkedin.com/in/janedoe")
        XCTAssertEqual(screen.job?.title, "Backend Engineer")
        XCTAssertEqual(screen.meetingURL?.host, "acme.zoom.us")
        XCTAssertEqual(screen.interviewers.first?.email, "lee@acme.com")
        XCTAssertEqual(interviews[1].meetingURL?.absoluteString, "https://whereby.com/acme-room", "a custom room link is kept")
        let list = try XCTUnwrap(stub.requests(containing: "scheduled_events?user=").first)
        XCTAssertTrue(list.url!.absoluteString.contains("status=active"))
        XCTAssertEqual(list.value(forHTTPHeaderField: "Authorization"), "Bearer pat")
        let label = try await connector.verify()
        XCTAssertEqual(label, "lee@acme.com")
    }

    func testCalendlyNeverFollowsAnotherHost() async throws {
        let stub = StubTransport()
        stub.on("GET", "users/me", json: #"{"resource":{"uri":"https://api.calendly.com/users/U1"}}"#)
        stub.on("GET", "evil.example.com", json: #"{"collection":[]}"#)
        stub.on("GET", "scheduled_events?", json: #"{"collection":[],"pagination":{"next_page":"https://evil.example.com/steal"}}"#)
        let connector = try CalendlyConnector(credentials: ConnectorCredentials(fields: ["apiKey": "pat"]), transport: stub)
        _ = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertTrue(stub.requests(containing: "evil.example.com").isEmpty, "the token is only sent to Calendly")
    }

    func testEveryBookingSwitchKeepsAllBookings() async throws {
        let stub = StubTransport()
        stub.on("GET", "users/me", json: #"{"resource":{"uri":"https://api.calendly.com/users/U1"}}"#)
        stub.on("GET", "/invitees", json: #"{"collection":[{"name":"Ana Pop","email":"ana@example.com"}]}"#)
        stub.on("GET", "scheduled_events?", json: #"{"collection":[{"uri":"https://api.calendly.com/scheduled_events/E9","name":"30 Minute Meeting","status":"active","start_time":"2026-11-10T15:00:00Z"}],"pagination":{"next_page":null}}"#)
        let all = try CalendlyConnector(credentials: ConnectorCredentials(fields: ["apiKey": "p", "everyBooking": "true"]), transport: stub)
        let interviews = try await all.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(interviews.first?.candidate?.name, "Ana Pop")
        XCTAssertNil(interviews.first?.job, "no role in a generic booking name")
        XCTAssertNil(BookingFilter.job(from: "Technical Interview"))
        XCTAssertEqual(BookingFilter.job(from: "Senior iOS Developer - Final Round")?.title, "Senior iOS Developer")
    }

    func testCalComBookingsWithCursorPaging() async throws {
        let stub = StubTransport()
        stub.on("GET", "status=past", json: #"{"status":"success","data":[{"id":0,"uid":"b0","title":"Phone screen with Ana Pop","status":"accepted","start":"2026-11-07T15:00:00Z","end":"2026-11-07T15:30:00Z","attendees":[{"name":"Ana Pop","email":"ana@example.com"}]}],"pagination":{"nextCursor":null,"hasMore":false}}"#)
        stub.on("GET", "cursor=c2", json: #"{"status":"success","data":[{"id":2,"uid":"b2","title":"Onsite interview with Max Roe","status":"cancelled","start":"2026-11-13T15:00:00Z","end":"2026-11-13T16:00:00Z","attendees":[]}],"pagination":{"nextCursor":null,"hasMore":false}}"#)
        stub.on("GET", "api.cal.com/v2/bookings?", json: #"""
        {"status":"success","data":[
          {"id":1,"uid":"b1","title":"Technical Interview between Lee Engineer and Jane Doe","status":"accepted",
           "start":"2026-11-12T15:00:00Z","end":"2026-11-12T16:00:00Z","location":"https://app.cal.com/video/abc123",
           "hosts":[{"id":7,"name":"Lee Engineer","email":"lee@acme.com"}],
           "attendees":[{"name":"Jane Doe","email":"jane.doe@gmail.com","timeZone":"America/New_York"}]}],
         "pagination":{"nextCursor":"c2","hasMore":true}}
        """#)
        stub.on("GET", "api.cal.com/v2/me", json: #"{"status":"success","data":{"id":7,"email":"lee@acme.com","username":"lee"}}"#)
        let connector = try CalComConnector(credentials: ConnectorCredentials(fields: ["apiKey": "cal_live_x"]), transport: stub)
        let interviews = try await connector.upcomingInterviews(from: from, to: to)
        XCTAssertEqual(interviews.map(\.externalID), ["b1", "b0"],
                       "the cancelled booking on page two is left out; a finished one is kept for matching recordings")
        XCTAssertEqual(interviews.first?.candidate?.email, "jane.doe@gmail.com")
        XCTAssertEqual(interviews.first?.meetingURL?.absoluteString, "https://app.cal.com/video/abc123")
        XCTAssertEqual(interviews.first?.interviewers.first?.name, "Lee Engineer")
        let first = try XCTUnwrap(stub.requests(containing: "/bookings?").first)
        XCTAssertEqual(first.value(forHTTPHeaderField: "cal-api-version"), "2026-05-01")
        XCTAssertTrue(first.url!.absoluteString.contains("status=upcoming"))
        XCTAssertEqual(stub.requests(containing: "cursor=c2").count, 1)
        let label = try await connector.verify()
        XCTAssertEqual(label, "lee@acme.com")
    }

    func testCalComSelfHostedNeedsHTTPS() {
        XCTAssertThrowsError(try CalComConnector(credentials: ConnectorCredentials(fields: ["apiKey": "k", "url": "http://cal.local/api/v2"]),
                                                 transport: StubTransport()))
        XCTAssertNoThrow(try CalComConnector(credentials: ConnectorCredentials(fields: ["apiKey": "k", "url": "https://cal.acme.com/api/v2"]),
                                             transport: StubTransport()))
    }

    func testProfileLinksFromBookingAnswers() {
        XCTAssertEqual(CalendlyConnector.profileLink(in: ["see https://github.com/jane and www.linkedin.com/in/jane"])?.host, "www.linkedin.com")
        XCTAssertEqual(CalendlyConnector.profileLink(in: ["https://github.com/jane"])?.host, "github.com")
        XCTAssertNil(CalendlyConnector.profileLink(in: ["I am available after 3pm"]))
    }
}

final class SyncNotesTests: XCTestCase {
    func testABookingListCutAtThePageLimitIsNoted() async throws {
        let stub = StubTransport()
        stub.on("GET", "users/me", json: #"{"resource":{"uri":"https://api.calendly.com/users/U1"}}"#)
        stub.on("GET", "/invitees", json: #"{"collection":[]}"#)
        stub.on("GET", "scheduled_events", json: #"{"collection":[{"uri":"https://api.calendly.com/scheduled_events/E1","name":"Interview","status":"active","start_time":"2026-11-10T15:00:00Z"}],"pagination":{"next_page":"https://api.calendly.com/scheduled_events?page_token=more"}}"#)
        let connector = try CalendlyConnector(credentials: ConnectorCredentials(fields: ["apiKey": "p"]), transport: stub)
        let notes = SyncNotes()
        _ = try await SyncNotes.$current.withValue(notes) {
            try await connector.upcomingInterviews(from: date("2026-11-07T00:00:00Z"), to: date("2026-11-21T00:00:00Z"))
        }
        XCTAssertEqual(notes.messages, ["Stopped after 10 bookings; some may be missing."])
        XCTAssertEqual(stub.requests(containing: "scheduled_events?").count, CalendlyConnector.pageLimit)
    }

    func testNotesOutsideASyncGoNowhere() {
        SyncNotes.note("ignored")
        XCTAssertNil(SyncNotes.current)
    }
}

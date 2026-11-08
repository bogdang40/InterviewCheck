import XCTest
@testable import InterviewCheckConnectors

final class CalendarFeedTests: XCTestCase {
    private let feed = """
    BEGIN:VCALENDAR\r
    PRODID:-//Google Inc//Google Calendar 70.9054//EN\r
    BEGIN:VTIMEZONE\r
    TZID:America/New_York\r
    END:VTIMEZONE\r
    BEGIN:VEVENT\r
    UID:a1@google.com\r
    DTSTART;TZID=America/New_York:20261110T100000\r
    DTEND;TZID=America/New_York:20261110T110000\r
    SUMMARY:Interview: Jane Doe - Backend Engineer\r
    LOCATION:https://meet.google.com/abc-defg-hij\r
    ORGANIZER;CN=Sam:mailto:sam@acme.com\r
    ATTENDEE;CN=Jane Doe:mailto:jane@gmail.com\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:a2@google.com\r
    DTSTART:20261111T150000Z\r
    SUMMARY:Dentist\r
    END:VEVENT\r
    BEGIN:VEVENT\r
    UID:a3@google.com\r
    DTSTART:20261112T150000Z\r
    STATUS:CANCELLED\r
    SUMMARY:Phone screen with Max Roe\r
    END:VEVENT\r
    END:VCALENDAR\r

    """

    func testFeedInterviewsWithTimeZones() async throws {
        let stub = StubTransport()
        stub.on("GET", "calendar.google.com/calendar/ical/", json: feed)
        let connector = try CalendarFeedConnector(
            credentials: ConnectorCredentials(fields: ["url": "webcal://calendar.google.com/calendar/ical/x%40acme.com/private-abc/basic.ics"]),
            transport: stub)
        let interviews = try await connector.upcomingInterviews(from: date("2026-11-07T00:00:00Z"), to: date("2026-11-21T00:00:00Z"))
        XCTAssertEqual(interviews.map(\.externalID), ["a1@google.com"], "the dentist and the cancelled screen are left out")
        XCTAssertEqual(interviews.first?.startsAt, date("2026-11-10T15:00:00Z"), "10:00 in New York")
        XCTAssertEqual(interviews.first?.source, .icsFeed)
        XCTAssertEqual(interviews.first?.candidate?.email, "jane@gmail.com")
        XCTAssertEqual(stub.requests.first?.url?.scheme, "https", "webcal is fetched over https")
        let label = try await connector.verify()
        XCTAssertEqual(label, "calendar.google.com \u{00B7} 3 events")
    }

    func testOnlyHTTPSFeeds() {
        XCTAssertThrowsError(try CalendarFeedConnector(credentials: ConnectorCredentials(fields: ["url": "http://example.com/a.ics"]),
                                                       transport: StubTransport()))
        XCTAssertThrowsError(try CalendarFeedConnector(credentials: ConnectorCredentials(fields: [:]), transport: StubTransport()))
    }

    func testOneBrokenFeedOfSeveralIsANote() async throws {
        let stub = StubTransport()
        stub.on("GET", "good.example.com", json: feed)
        stub.on("GET", "gone.example.com", status: 404, json: "")
        let connector = try CalendarFeedConnector(
            credentials: ConnectorCredentials(fields: ["url": "https://good.example.com/a.ics\nhttps://gone.example.com/b.ics"]), transport: stub)
        let notes = SyncNotes()
        let interviews = try await SyncNotes.$current.withValue(notes) {
            try await connector.upcomingInterviews(from: date("2026-11-07T00:00:00Z"), to: date("2026-11-21T00:00:00Z"))
        }
        XCTAssertEqual(interviews.count, 1)
        XCTAssertEqual(notes.messages.count, 1)
        XCTAssertTrue(notes.messages[0].contains("gone.example.com"))
    }
}

import XCTest
@testable import InterviewCheckConnectors

final class CalendarParsingTests: XCTestCase {
    func testICSInviteBecomesAnInterview() throws {
        let ics = """
        BEGIN:VCALENDAR\r
        VERSION:2.0\r
        BEGIN:VEVENT\r
        UID:gh-123@greenhouse.io\r
        SUMMARY:Interview with Jane Doe for Senior Backend Engineer\r
        DTSTART:20261110T150000Z\r
        DTEND:20261110T160000Z\r
        LOCATION:https://acme.zoom.us/j/81234567890?pwd=abc\r
        DESCRIPTION:Agenda:\\nSystem design\\, then questions. Longer text that is fold\r
         ed onto the next line.\r
        ORGANIZER;CN=Sam Recruiter:mailto:sam@acme.com\r
        ATTENDEE;CN="Jane Doe";ROLE=REQ-PARTICIPANT:mailto:jane.doe@gmail.com\r
        ATTENDEE;CN=Lee Engineer:mailto:lee@acme.com\r
        END:VEVENT\r
        END:VCALENDAR\r
        """
        let events = ICSParser.events(in: ics)
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.startsAt, date("2026-11-10T15:00:00Z"))
        XCTAssertEqual(event.notes, "Agenda:\nSystem design, then questions. Longer text that is folded onto the next line.")
        XCTAssertEqual(event.attendees.map(\.email), ["jane.doe@gmail.com", "lee@acme.com"])
        XCTAssertTrue(InterviewEventClassifier.isInterview(event))

        let interview = InterviewEventClassifier.interview(from: event, source: .icsFile)
        XCTAssertEqual(interview.candidate?.name, "Jane Doe")
        XCTAssertEqual(interview.candidate?.email, "jane.doe@gmail.com", "the outside attendee's email")
        XCTAssertEqual(interview.job?.title, "Senior Backend Engineer")
        XCTAssertEqual(interview.meetingURL?.host, "acme.zoom.us")
        XCTAssertEqual(interview.id, "icsFile:gh-123@greenhouse.io")
    }

    func testTimeZoneAndAllDayDates() {
        let berlin = ICSParser.date("20261110T160000", params: ["TZID": "Europe/Berlin"])
        XCTAssertEqual(berlin, date("2026-11-10T15:00:00Z"))
        XCTAssertNotNil(ICSParser.date("20261110", params: [:]))
    }

    func testTitlesFromCommonSchedulers() {
        let cases: [(String, String?, String?)] = [
            ("Jane Doe <> Acme | Backend Engineer Interview", "Jane Doe", "Acme"),
            ("Phone Screen: Priya Natarajan - Data Scientist", "Priya Natarajan", "Data Scientist"),
            ("Interview with Marcus Lee", "Marcus Lee", nil),
            ("Technical Interview - Staff Engineer - Ana Silva", "Ana Silva", "Staff Engineer"),
        ]
        for (title, candidate, role) in cases {
            let guess = InterviewEventClassifier.guess(CalendarEvent(id: "1", title: title, startsAt: Date()))
            XCTAssertEqual(guess.candidate, candidate, title)
            XCTAssertEqual(guess.role, role, title)
        }
        XCTAssertFalse(InterviewEventClassifier.isInterview(CalendarEvent(id: "2", title: "Team standup", startsAt: Date())))
        XCTAssertTrue(InterviewEventClassifier.isInterview(CalendarEvent(id: "3", title: "Sync", startsAt: Date()),
                                                           extraKeywords: ["sync"]))
    }
}

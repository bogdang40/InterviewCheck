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

    func testOutlookZonesQuotedColonsAndGuestEmail() {
        let ics = """
        BEGIN:VEVENT
        UID:o1
        SUMMARY:Interview - Jane Doe - Backend Engineer
        DTSTART;TZID=Pacific Standard Time:20261110T100000
        ORGANIZER;SENT-BY="mailto:assistant@acme.com";CN=Sam:mailto:sam@acme.com
        ATTENDEE:mailto:jane.doe@gmail.com
        END:VEVENT
        """
        let event = ICSParser.events(in: ics)[0]
        XCTAssertEqual(event.startsAt, date("2026-11-10T18:00:00Z"), "Windows zone names are understood")
        XCTAssertEqual(event.organizer?.email, "sam@acme.com", "a colon inside quotes is not the value separator")
        let interview = InterviewEventClassifier.interview(from: event, source: .icsFile)
        XCTAssertEqual(interview.candidate?.email, "jane.doe@gmail.com", "the one outside guest is the candidate")
    }

    func testTimeZoneAndAllDayDates() {
        let berlin = ICSParser.date("20261110T160000", params: ["TZID": "Europe/Berlin"])
        XCTAssertEqual(berlin, date("2026-11-10T15:00:00Z"))
        XCTAssertNotNil(ICSParser.date("20261110", params: [:]))
    }

    func testTitlesFromCommonSchedulers() {
        let cases: [(String, String?, String?)] = [
            ("Jane Doe <> Acme | Backend Engineer Interview", "Jane Doe", "Backend Engineer"),
            ("Callum Smith - Backend Engineer - Onsite", "Callum Smith", "Backend Engineer"),
            ("Interview: Priya Chatterjee", "Priya Chatterjee", nil),
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

    func testAllDayCancelledAndLookAlikeLinks() {
        let allDay = ICSParser.events(in: "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:x\r\nDTSTART;VALUE=DATE:20261110\r\nSUMMARY:Onsite interview - Jane Doe\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
        XCTAssertEqual(allDay.first?.isAllDay, true)
        XCTAssertFalse(InterviewEventClassifier.isInterview(allDay[0]), "a whole-day block has no time to prepare for")
        let google = GoogleWorkspaceConnector.calendarEvent(try! JSONValue.parse(Data(#"{"id":"g1","status":"confirmed","summary":"Interview: Jane Doe","start":{"dateTime":"2026-11-10T15:00:00Z"},"attendees":[{"email":"me@acme.com","self":true,"responseStatus":"declined"},{"email":"jane@gmail.com"}]}"#.utf8)))
        XCTAssertEqual(google?.isCancelled, true, "an invitation the user declined is not their interview")
        XCTAssertEqual(MeetingLinks.platform(of: URL(string: "https://login.xzoom.us/j/1")!), .other)
        XCTAssertEqual(MeetingLinks.platform(of: URL(string: "https://acme.zoom.us/j/1")!), .zoom)
        XCTAssertEqual(MeetingLinks.platform(of: URL(string: "http://acme.zoom.us/j/1")!), .other, "https only")
    }
}

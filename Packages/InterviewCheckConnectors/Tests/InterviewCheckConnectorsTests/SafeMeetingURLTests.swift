import XCTest
@testable import InterviewCheckConnectors

final class SafeMeetingURLTests: XCTestCase {
    func testOnlyHTTPSLinksWithAHostAreAccepted() {
        for text in ["file:///Applications/Calculator.app", "smb://files.example.com/share", "http://acme.zoom.us/j/1",
                     "zoommtg://zoom.us/join?confno=1", "javascript:alert(1)", "https:///nohost", "ftp://example.com/x"] {
            XCTAssertNil(SafeMeetingURL(URL(string: text)), text)
        }
        XCTAssertNil(SafeMeetingURL(nil))
        XCTAssertNotNil(SafeMeetingURL(URL(string: "https://whereby.com/acme")))
    }

    func testOnlyKnownMeetingPlatformsOpenWithoutAClick() throws {
        let zoom = try XCTUnwrap(SafeMeetingURL(URL(string: "https://acme.zoom.us/j/81234567890")))
        XCTAssertTrue(zoom.opensAutomatically)
        XCTAssertEqual(zoom.platform, .zoom)
        let other = try XCTUnwrap(SafeMeetingURL(URL(string: "https://evil.example.com/j/1")))
        XCTAssertFalse(other.opensAutomatically)
        XCTAssertFalse(try XCTUnwrap(SafeMeetingURL(URL(string: "https://xzoom.us/j/1"))).opensAutomatically)
    }

    func testAnInterviewExposesOnlyASafeLink() {
        var interview = ExternalInterview(source: .greenhouse, externalID: "1", title: "Screen", startsAt: Date(),
                                          meetingURL: URL(string: "file:///etc/passwd"))
        XCTAssertNil(interview.safeMeetingLink)
        interview.meetingURL = URL(string: "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(interview.safeMeetingLink?.platform, .googleMeet)
    }
}

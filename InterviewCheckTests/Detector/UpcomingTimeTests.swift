import XCTest
@testable import InterviewCheck

final class UpcomingTimeTests: XCTestCase {
    func testLabels() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 22, minute: 30))!
        let soon = now.addingTimeInterval(25 * 60)
        XCTAssertTrue(UpcomingTime.label(soon, now: now, calendar: calendar).hasPrefix("Today, "))
        XCTAssertTrue(UpcomingTime.label(soon, now: now, calendar: calendar).hasSuffix("in 25 min"))
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 9))!
        XCTAssertTrue(UpcomingTime.label(tomorrow, now: now, calendar: calendar).hasPrefix("Tomorrow, "))
        let later = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9))!
        XCTAssertFalse(UpcomingTime.label(later, now: now, calendar: calendar).contains("Today"))
        XCTAssertTrue(UpcomingTime.label(now.addingTimeInterval(-600), now: now, calendar: calendar).hasSuffix("started 10 min ago"))
        XCTAssertTrue(UpcomingTime.isSoon(soon, now: now))
        XCTAssertFalse(UpcomingTime.isSoon(tomorrow, now: now))
    }
}

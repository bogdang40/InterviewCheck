import XCTest
@testable import InterviewCheck

final class PreviousInterviewsTests: XCTestCase {
    func testMatchesTheSameFullNameOnly() {
        let path = NSTemporaryDirectory() + "previous-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = SessionDatabase(databasePath: path)
        let earlier = Date(timeIntervalSince1970: 1_790_000_000)
        database.saveInterview(InterviewRecord(id: "a", workspaceID: nil, roleTitle: "Backend", candidateName: "José Núñez",
                                               consentConfirmedAt: nil, startedAt: earlier, endedAt: earlier, overallPercent: 72))
        database.saveInterview(InterviewRecord(id: "live", workspaceID: nil, roleTitle: "", candidateName: "Ana Pop",
                                               consentConfirmedAt: nil, startedAt: Date()))

        XCTAssertEqual(PreviousInterviews.latest(for: "jose nunez", database: database)?.id, "a", "case and accents don't matter")
        XCTAssertNil(PreviousInterviews.latest(for: "José", database: database), "a first name alone is not enough")
        XCTAssertNil(PreviousInterviews.latest(for: "Ana Pop", database: database), "an interview still running is not 'before'")
        XCTAssertNil(PreviousInterviews.latest(for: "José Núñez Jr", database: database))
    }
}

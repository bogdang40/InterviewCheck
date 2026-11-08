import XCTest
@testable import InterviewCheck

final class RetentionTests: XCTestCase {
    private var path: String!
    private var database: SessionDatabase!

    override func setUp() {
        path = NSTemporaryDirectory() + "retention-\(UUID().uuidString).sqlite"
        database = SessionDatabase(databasePath: path)
    }

    override func tearDown() {
        database = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    private func interview(daysAgo: Int, now: Date) -> InterviewRecord {
        InterviewRecord(id: UUID().uuidString, workspaceID: nil, roleTitle: "", candidateName: "C\(daysAgo)",
                        consentConfirmedAt: nil, startedAt: now.addingTimeInterval(-Double(daysAgo) * 86_400))
    }

    func testRetentionDeletesOnlyOlderInterviews() {
        let now = Date()
        [5, 40, 120].forEach { database.saveInterview(interview(daysAgo: $0, now: now)) }
        XCTAssertEqual(InterviewRetention.apply(days: 0, database: database, now: now), 0, "forever keeps all")
        XCTAssertEqual(InterviewRetention.apply(days: 30, database: database, now: now), 2)
        XCTAssertEqual(database.loadInterviews().map(\.candidateName), ["C5"])
    }

    func testDeleteAllRemovesEveryInterview() {
        let now = Date()
        [1, 2].forEach { database.saveInterview(interview(daysAgo: $0, now: now)) }
        XCTAssertEqual(database.deleteAllInterviews(), 2)
        XCTAssertTrue(database.loadInterviews().isEmpty)
    }
}

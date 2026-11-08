import XCTest
@testable import InterviewCheck

final class ReportFilterTests: XCTestCase {
    private func interview(_ name: String, role: String, day: Double, percent: Int?, flagged: Int) -> InterviewRecord {
        InterviewRecord(id: name, workspaceID: nil, roleTitle: role, candidateName: name, consentConfirmedAt: nil,
                        startedAt: Date(timeIntervalSince1970: day * 86_400), overallPercent: percent,
                        flaggedCount: flagged, questionCount: 3)
    }

    private lazy var all = [
        interview("bea", role: "Backend", day: 1, percent: 30, flagged: 0),
        interview("Al", role: "Frontend", day: 3, percent: 81, flagged: 2),
        interview("cy", role: "Backend", day: 2, percent: nil, flagged: 0),
        interview("Di", role: "Backend", day: 4, percent: 64, flagged: 1),
    ]

    func testSortOrders() {
        XCTAssertEqual(ReportFilter(sort: .newest).apply(all).map(\.id), ["Di", "Al", "cy", "bea"])
        XCTAssertEqual(ReportFilter(sort: .oldest).apply(all).map(\.id), ["bea", "cy", "Al", "Di"])
        XCTAssertEqual(ReportFilter(sort: .highestScore).apply(all).map(\.id), ["Al", "Di", "bea", "cy"])
        XCTAssertEqual(ReportFilter(sort: .candidate).apply(all).map(\.id), ["Al", "bea", "cy", "Di"])
    }

    func testFiltersCombine() {
        XCTAssertEqual(ReportFilter(flaggedOnly: true).apply(all).map(\.id), ["Di", "Al"])
        XCTAssertEqual(ReportFilter(flaggedOnly: true, roleTitle: "Backend").apply(all).map(\.id), ["Di"])
        XCTAssertEqual(ReportFilter(search: "front").apply(all).map(\.id), ["Al"])
        XCTAssertTrue(ReportFilter(search: "zzz").apply(all).isEmpty)
    }
}

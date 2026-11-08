import XCTest
@testable import memanager

final class QuickAssistTurnNavigatorTests: XCTestCase {
    func testSelectedIndexDefaultsToLast() {
        let model = QuickAssistTurnNavigatorModel(turnSummaries: makeSummaries(count: 3), selectedIndex: nil, isLoading: false)
        XCTAssertEqual(model.effectiveSelected, 2)
        XCTAssertEqual(model.label, "3 of 3")
    }

    func testSelectedIndexRespectsExplicitValue() {
        let model = QuickAssistTurnNavigatorModel(turnSummaries: makeSummaries(count: 5), selectedIndex: 1, isLoading: false)
        XCTAssertEqual(model.effectiveSelected, 1)
        XCTAssertEqual(model.label, "2 of 5")
    }

    func testPreviousDisabledAtFirstTurn() {
        let model = QuickAssistTurnNavigatorModel(turnSummaries: makeSummaries(count: 5), selectedIndex: 0, isLoading: false)
        XCTAssertTrue(model.isPreviousDisabled)
        XCTAssertFalse(model.isNextDisabled)
    }

    func testNextDisabledAtLastTurn() {
        let model = QuickAssistTurnNavigatorModel(turnSummaries: makeSummaries(count: 5), selectedIndex: 4, isLoading: false)
        XCTAssertTrue(model.isNextDisabled)
        XCTAssertFalse(model.isPreviousDisabled)
    }

    func testNavigationDisabledWhileLoading() {
        let model = QuickAssistTurnNavigatorModel(turnSummaries: makeSummaries(count: 5), selectedIndex: 2, isLoading: true)
        XCTAssertTrue(model.isPreviousDisabled)
        XCTAssertTrue(model.isNextDisabled)
    }

    func testEmptyLabelAndSelection() {
        let model = QuickAssistTurnNavigatorModel(turnSummaries: [], selectedIndex: nil, isLoading: false)
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.label, "0 of 0")
        XCTAssertTrue(model.isPreviousDisabled)
        XCTAssertTrue(model.isNextDisabled)
    }

    func testDotToneFollowsVerification() {
        let summaries = makeSummaries(count: 2)
        let model = QuickAssistTurnNavigatorModel(turnSummaries: summaries, selectedIndex: 0, isLoading: false)
        XCTAssertEqual(model.tone(for: summaries[0]), .success)
        XCTAssertEqual(model.tone(for: summaries[1]), .warning)
        XCTAssertTrue(model.isSelected(summaries[0]))
        XCTAssertFalse(model.isSelected(summaries[1]))
    }

    private func makeSummaries(count: Int) -> [QuickAssistTurnSummary] {
        (0..<count).map { index in
            QuickAssistTurnSummary(id: UUID(), index: index, verificationStatus: index % 2 == 0 ? .verified : .needsReview)
        }
    }
}

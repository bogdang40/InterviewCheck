import XCTest
@testable import memanager

final class QuickAssistStudioLayoutResolverTests: XCTestCase {
    func testCompactWidthWrapsHeaderAndShrinksToolbar() {
        let plan = QuickAssistStudioLayoutResolver.resolve(availableWidth: 440)

        XCTAssertEqual(plan.breakpoint, .compact)
        XCTAssertTrue(plan.headerWrapsToTwoRows)
        XCTAssertTrue(plan.toolbarUsesIconActions)
        XCTAssertFalse(plan.showsResolvedModeCaption)
        XCTAssertEqual(plan.readingWidth, OverlayLayout.readingWidth(for: 440))
    }

    func testRegularWidthKeepsOneRowAndHidesCaption() {
        let plan = QuickAssistStudioLayoutResolver.resolve(availableWidth: 720)

        XCTAssertEqual(plan.breakpoint, .regular)
        XCTAssertFalse(plan.headerWrapsToTwoRows)
        XCTAssertFalse(plan.toolbarUsesIconActions)
        XCTAssertFalse(plan.showsResolvedModeCaption)
    }

    func testWideWidthShowsEverythingWithinReadingColumn() {
        let plan = QuickAssistStudioLayoutResolver.resolve(availableWidth: 1200)

        XCTAssertEqual(plan.breakpoint, .wide)
        XCTAssertFalse(plan.headerWrapsToTwoRows)
        XCTAssertTrue(plan.showsResolvedModeCaption)
        XCTAssertEqual(plan.readingWidth, OverlayLayout.readingColumnMaximum)
    }
}

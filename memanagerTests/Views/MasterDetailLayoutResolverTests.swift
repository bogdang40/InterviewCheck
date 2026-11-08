import XCTest
@testable import memanager

/// Sizing rules shared by the two column overlay screens.
final class MasterDetailLayoutResolverTests: XCTestCase {
    func testSplitReservesACompleteReadingPaneBelow900Points() {
        XCTAssertFalse(MasterDetailLayoutResolver.isSplit(width: 440))
        XCTAssertFalse(MasterDetailLayoutResolver.isSplit(width: 899))
        XCTAssertTrue(MasterDetailLayoutResolver.isSplit(width: 900))
        XCTAssertTrue(MasterDetailLayoutResolver.isSplit(width: 1000))
    }

    func testListWidthStaysReadableAndYieldsTheRest() {
        XCTAssertEqual(MasterDetailLayoutResolver.listWidth(for: 560), OverlayColumnWidth.minimumList)
        XCTAssertEqual(MasterDetailLayoutResolver.listWidth(for: 900), 270, accuracy: 0.01)
        XCTAssertEqual(MasterDetailLayoutResolver.listWidth(for: 1200), OverlayColumnWidth.maximumList)
    }

    func testSelectionOpensTheDetailOnlyOnASinglePane() {
        XCTAssertEqual(MasterDetailLayoutResolver.pane(afterSelectionIn: 440, current: .list), .detail)
        XCTAssertEqual(MasterDetailLayoutResolver.pane(afterSelectionIn: 440, current: .detail), .detail)
        XCTAssertEqual(MasterDetailLayoutResolver.pane(afterSelectionIn: 899, current: .list), .detail)
        XCTAssertEqual(MasterDetailLayoutResolver.pane(afterSelectionIn: 900, current: .list), .list)
    }
}

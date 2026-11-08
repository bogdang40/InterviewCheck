import AppKit
import XCTest
@testable import memanager

final class OverlayGapMousePassthroughTests: XCTestCase {
    func testRoundedIslandCornersAndDesktopGapsPassThrough() {
        let geometry = FloatingShellGeometry(size: CGSize(width: 1200, height: 900), borderWidth: 12)
        let regions = [geometry.navigation, geometry.content, geometry.dock].map {
            OverlayGlassHitRegion(rect: $0.insetBy(dx: -12, dy: -12), cornerRadius: 38)
        }
        let middle = CGPoint(x: geometry.content.midX, y: geometry.content.midY)
        let gap = CGPoint(x: (regions[0].rect.maxX + regions[1].rect.minX) / 2, y: middle.y)
        let corner = CGPoint(x: regions[1].rect.minX + 1, y: regions[1].rect.minY + 1)
        XCTAssertTrue(regions.contains { $0.contains(middle) })
        XCTAssertFalse(regions.contains { $0.contains(gap) })
        XCTAssertFalse(regions.contains { $0.contains(corner) })
        XCTAssertTrue(regions[1].contains(CGPoint(x: regions[1].rect.midX, y: regions[1].rect.minY + 1)))
    }

    func testTextSelectionDragKeepsOverlayOwnershipAcrossAGapUntilAllButtonsRelease() {
        var policy = OverlayGapPointerPolicy()
        XCTAssertFalse(policy.update(insideRegion: true, pressedButtons: 0))
        XCTAssertFalse(policy.update(insideRegion: true, pressedButtons: 1, dragBeganInOverlay: true))
        XCTAssertFalse(policy.update(insideRegion: false, pressedButtons: 1))
        XCTAssertFalse(policy.update(insideRegion: false, pressedButtons: 3, dragBeganInOverlay: false))
        XCTAssertFalse(policy.update(insideRegion: false, pressedButtons: 2))
        XCTAssertTrue(policy.update(insideRegion: false, pressedButtons: 0))
        XCTAssertFalse(policy.update(insideRegion: true, pressedButtons: 0))
    }

    func testDesktopDragCannotBeStolenWhenCrossingAnIsland() {
        var policy = OverlayGapPointerPolicy()
        XCTAssertTrue(policy.update(insideRegion: false, pressedButtons: 0))
        XCTAssertTrue(policy.update(insideRegion: false, pressedButtons: 1, dragBeganInOverlay: false))
        XCTAssertTrue(policy.update(insideRegion: true, pressedButtons: 1))
        XCTAssertFalse(policy.update(insideRegion: true, pressedButtons: 0))
    }

    func testSheetOwnsPointerAndResizingDuringAnUnknownDragPreservesRouting() {
        var policy = OverlayGapPointerPolicy()
        XCTAssertTrue(policy.update(insideRegion: false, pressedButtons: 0))
        XCTAssertTrue(policy.update(insideRegion: true, pressedButtons: 1))
        XCTAssertFalse(policy.update(insideRegion: false, pressedButtons: 0, hasModalContent: true))
        XCTAssertTrue(policy.update(insideRegion: false, pressedButtons: 0))
        policy.reset()
        XCTAssertFalse(policy.ignoresMouseEvents)
        XCTAssertNil(policy.dragBelongsToOverlay)
    }

    func testInvalidRegionsNeverCaptureTheDesktop() {
        let point = CGPoint(x: 2, y: 2)
        XCTAssertFalse(OverlayGlassHitRegion(rect: .zero, cornerRadius: 4).contains(point))
        XCTAssertFalse(OverlayGlassHitRegion(rect: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 40),
            cornerRadius: 4).contains(point))
        XCTAssertFalse(OverlayGlassHitRegion(rect: CGRect(x: 0, y: 0, width: 40, height: 40),
            cornerRadius: 4).contains(CGPoint(x: CGFloat.nan, y: 2)))
    }
}

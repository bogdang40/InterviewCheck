import XCTest
@testable import memanager

final class ScreenCaptureGeometryTests: XCTestCase {
    func testRegionUsesSelectedDisplaysGlobalOrigin() {
        let local = CGRect(x: 80, y: 120, width: 300, height: 200)
        for origin in [CGPoint(x: 1920, y: 0), CGPoint(x: -1600, y: -900)] {
            let display = CGRect(origin: origin, size: CGSize(width: 1600, height: 900))
            XCTAssertEqual(ScreenCaptureGeometry.region(local, in: display),
                           CGRect(x: origin.x + 80, y: origin.y + 580, width: 300, height: 200))
        }
    }

    func testSelectionClipsAtDisplayEdgeAndRejectsInvalidBounds() {
        let display = CGRect(x: 1920, y: 0, width: 1600, height: 900)
        XCTAssertEqual(ScreenCaptureGeometry.region(CGRect(x: -20, y: 50, width: 100, height: 100), in: display),
                       CGRect(x: 1920, y: 750, width: 80, height: 100))
        XCTAssertNil(ScreenCaptureGeometry.region(.zero, in: display))
        XCTAssertNil(ScreenCaptureGeometry.region(CGRect(x: 2000, y: 0, width: 100, height: 100), in: display))
        XCTAssertNil(ScreenCaptureGeometry.region(CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100), in: display))
    }
}

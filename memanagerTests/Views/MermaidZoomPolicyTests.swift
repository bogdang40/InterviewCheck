import XCTest
@testable import memanager

final class MermaidZoomPolicyTests: XCTestCase {
    func testClampStaysWithinLimits() {
        XCTAssertEqual(MermaidZoomPolicy.clamp(0.1), MermaidZoomPolicy.minimum)
        XCTAssertEqual(MermaidZoomPolicy.clamp(5), MermaidZoomPolicy.maximum)
        XCTAssertEqual(MermaidZoomPolicy.clamp(1.2), 1.2)
    }

    func testStepsMoveByTheIncrementAndStopAtTheEdges() {
        XCTAssertEqual(MermaidZoomPolicy.zoomedIn(1.0), 1.15, accuracy: 0.0001)
        XCTAssertEqual(MermaidZoomPolicy.zoomedOut(1.0), 0.85, accuracy: 0.0001)
        XCTAssertEqual(MermaidZoomPolicy.zoomedIn(MermaidZoomPolicy.maximum), MermaidZoomPolicy.maximum)
        XCTAssertFalse(MermaidZoomPolicy.canZoomIn(MermaidZoomPolicy.maximum))
        XCTAssertFalse(MermaidZoomPolicy.canZoomOut(MermaidZoomPolicy.minimum))
        XCTAssertTrue(MermaidZoomPolicy.canZoomIn(1.0))
    }

    func testPercentLabelRounds() {
        XCTAssertEqual(MermaidZoomPolicy.percentLabel(1.0), "100%")
        XCTAssertEqual(MermaidZoomPolicy.percentLabel(1.149), "115%")
        XCTAssertEqual(MermaidZoomPolicy.percent(0.7), 70)
    }
}

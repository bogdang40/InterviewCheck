import AppKit
import XCTest
@testable import memanager

@MainActor
final class OverlayWindowGeometryTests: XCTestCase {
    func testBothAnchorsUseTheEntireUsableScreenHeight() {
        let visibleFrame = NSRect(x: 0, y: 80, width: 1512, height: 870)
        let requested = NSRect(x: 300, y: 200, width: 700, height: 450)

        for edge in [OverlayWindow.AnchorEdge.left, .right] {
            let frame = OverlayWindow.anchoredFrame(requested, in: visibleFrame, edge: edge)
            XCTAssertEqual(frame.minY, visibleFrame.minY)
            XCTAssertEqual(frame.maxY, visibleFrame.maxY)
            XCTAssertEqual(frame.width, requested.width)
        }
        XCTAssertEqual(OverlayWindow.anchoredFrame(requested, in: visibleFrame, edge: .left).minX, 12)
        XCTAssertEqual(OverlayWindow.anchoredFrame(requested, in: visibleFrame, edge: .right).maxX, 1500)
    }

    func testDisplaysAboveBelowAndLeftOfThePrimaryRetainTheirOrigins() {
        for visibleFrame in [
            NSRect(x: -1920, y: 44, width: 1920, height: 1013),
            NSRect(x: 200, y: 1050, width: 1600, height: 980),
            NSRect(x: 100, y: -1080, width: 1920, height: 1057)
        ] {
            let requested = NSRect(x: 0, y: 0, width: 650, height: 600)
            let left = OverlayWindow.anchoredFrame(requested, in: visibleFrame, edge: .left)
            let right = OverlayWindow.anchoredFrame(requested, in: visibleFrame, edge: .right)
            XCTAssertEqual(left.minY, visibleFrame.minY)
            XCTAssertEqual(right.minY, visibleFrame.minY)
            XCTAssertEqual(left.maxY, visibleFrame.maxY)
            XCTAssertEqual(right.maxY, visibleFrame.maxY)
            XCTAssertEqual(left.minX, visibleFrame.minX + 12)
            XCTAssertEqual(right.maxX, visibleFrame.maxX - 12)
        }
    }

    func testWidthClampingCannotReduceHeightOrExceedUsableWidth() {
        for visibleFrame in [
            NSRect(x: 0, y: 65, width: 1440, height: 812),
            NSRect(x: -320, y: -640, width: 320, height: 640)
        ] {
            for width: CGFloat in [200, 2400] {
                let requested = NSRect(x: 0, y: 0, width: width, height: 100)
                let frame = OverlayWindow.anchoredFrame(requested, in: visibleFrame, edge: .right)
                XCTAssertEqual(frame.height, visibleFrame.height)
                XCTAssertEqual(frame.minY, visibleFrame.minY)
                XCTAssertLessThanOrEqual(frame.width, visibleFrame.width - 24)
                XCTAssertGreaterThanOrEqual(frame.width, min(400, visibleFrame.width - 24))
            }
        }
    }

    func testNativePanelConstraintUsesCurrentScreenVisibleFrame() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let window = OverlayWindow()
        defer { window.close() }
        let requested = NSRect(x: 100, y: 100, width: 650, height: 400)
        let frame = window.constrainFrameRect(requested, to: screen)
        let content = frame.insetBy(dx: window.borderOutset, dy: window.borderOutset)
        XCTAssertEqual(content.minY, screen.visibleFrame.minY)
        XCTAssertEqual(content.maxY, screen.visibleFrame.maxY)
    }

    func testBorderExpandsAroundTheSameContentAtBothAnchorsAndEveryMonitorOrigin() {
        for screen in [
            CGRect(x: 0, y: 80, width: 1512, height: 870),
            CGRect(x: -1920, y: 44, width: 1920, height: 1013),
            CGRect(x: 200, y: 1050, width: 1600, height: 980),
            CGRect(x: 100, y: -1080, width: 1920, height: 1057)
        ] {
            for edge in [OverlayWindow.AnchorEdge.left, .right] {
                let content = OverlayWindowGeometry.contentFrame(
                    CGRect(x: 0, y: 0, width: 650, height: 500), in: screen, edge: edge)
                for width: CGFloat in [0, 2, 12, 48] {
                    let frame = OverlayWindowGeometry.windowFrame(around: content, borderWidth: width)
                    XCTAssertEqual(frame.insetBy(dx: width, dy: width), content)
                    XCTAssertEqual(frame.height, screen.height + 2 * width)
                    XCTAssertEqual(frame.minY + width, screen.minY)
                    XCTAssertEqual(frame.maxY - width, screen.maxY)
                    XCTAssertEqual(frame.width - 2 * width, 650)
                    if width == 0 { XCTAssertEqual(frame, content) }
                }
            }
        }
    }
}

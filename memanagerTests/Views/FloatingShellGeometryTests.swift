import CoreGraphics
import SwiftUI
import XCTest
@testable import memanager

final class FloatingShellGeometryTests: XCTestCase {
    func testCompactContentWidthSurvivesOutwardBorderGrowth() {
        for border: CGFloat in [0, 2, 12, 48] {
            let plan = FloatingShellGeometry(size: CGSize(width: 400 + 2 * border, height: 760 + 2 * border),
                                             borderWidth: border)
            XCTAssertTrue(plan.isCompact)
            XCTAssertEqual(plan.borderWidth, border)
            XCTAssertEqual(plan.content.width, 376)
            XCTAssertEqual(plan.dock.width, plan.content.width)
            XCTAssertEqual(plan.navigation.height, 44)
            XCTAssertEqual(plan.dock.height, 88)
        }
    }

    func testRailBreakpointUsesContentWidthWithoutTheOuterBorder() {
        for border: CGFloat in [0, 12, 48] {
            let compact = FloatingShellGeometry(size: CGSize(width: 759 + 2 * border, height: 900), borderWidth: border)
            let rail = FloatingShellGeometry(size: CGSize(width: 760 + 2 * border, height: 900), borderWidth: border)
            XCTAssertTrue(compact.isCompact)
            XCTAssertFalse(rail.isCompact)
            XCTAssertEqual(rail.navigation.width, 160)
            XCTAssertEqual(rail.navigation.maxY, rail.content.maxY)
        }
    }

    func testNativePaneRimsLeaveRealDesktopGaps() {
        for logicalWidth: CGFloat in [400, 760, 1000, 1440] {
            for border: CGFloat in [0, 12, 48] {
                let size = CGSize(width: logicalWidth + 2 * border, height: 900 + 2 * border)
                let plan = FloatingShellGeometry(size: size, borderWidth: border)
                let navigation = plan.navigation.insetBy(dx: -border, dy: -border)
                let content = plan.content.insetBy(dx: -border, dy: -border)
                let dock = plan.dock.insetBy(dx: -border, dy: -border)
                XCTAssertFalse(navigation.intersects(content))
                XCTAssertFalse(content.intersects(dock))
                XCTAssertEqual(dock.minY - content.maxY, 18)
                if plan.isCompact { XCTAssertEqual(content.minY - navigation.maxY, 16) }
                else { XCTAssertEqual(content.minX - navigation.maxX, 20) }
                for frame in [navigation, content, dock] {
                    XCTAssertTrue(CGRect(origin: .zero, size: size).contains(frame))
                }
            }
        }
    }

    func testWorkspaceSpansContentAndDockWithoutChangingTheirBounds() {
        let plan = FloatingShellGeometry(size: CGSize(width: 1024, height: 784), borderWidth: 12)
        XCTAssertEqual(plan.workspace.minX, plan.content.minX)
        XCTAssertEqual(plan.workspace.minY, plan.content.minY)
        XCTAssertEqual(plan.workspace.maxX, plan.content.maxX)
        XCTAssertEqual(plan.workspace.maxY, plan.dock.maxY)
        XCTAssertEqual(plan.dock.minX, plan.content.minX)
        XCTAssertEqual(plan.dock.width, plan.content.width)
        XCTAssertEqual(plan.dock.height, 64)
        XCTAssertEqual(plan.brandCenter, CGPoint(x: plan.navigation.minX + 28, y: plan.navigation.minY + 36))
    }

    func testDockFitsOneRowAtTheSmallestRailWidthWithMaximumBorder() {
        let plan = FloatingShellGeometry(size: CGSize(width: 856, height: 856), borderWidth: 48)
        XCTAssertFalse(plan.isCompact)
        XCTAssertGreaterThanOrEqual(plan.dock.width, 450)
        XCTAssertEqual(plan.dock.height, 64)
    }

    func testDockMatchesPaneEdgesAcrossSizesAndBorderWidths() {
        for logicalWidth: CGFloat in [400, 560, 759, 760, 1120, 1440] {
            for border: CGFloat in [0, 2, 6, 12, 48] {
                let plan = FloatingShellGeometry(
                    size: CGSize(width: logicalWidth + 2 * border, height: 780 + 2 * border),
                    borderWidth: border)
                XCTAssertEqual(plan.dock.minX, plan.content.minX)
                XCTAssertEqual(plan.dock.maxX, plan.content.maxX)
                XCTAssertEqual(plan.dock.width, plan.content.width)
            }
        }
    }

    func testShortWindowProposalHasFiniteNonnegativeBounds() {
        for size in [CGSize.zero, CGSize(width: 400, height: 220), CGSize(width: CGFloat.nan, height: CGFloat.infinity)] {
            let plan = FloatingShellGeometry(size: size, borderWidth: CGFloat.nan)
            for frame in [plan.navigation, plan.content, plan.dock, plan.workspace] {
                XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite)
                XCTAssertGreaterThanOrEqual(frame.width, 0)
                XCTAssertGreaterThanOrEqual(frame.height, 0)
            }
        }
    }

    func testForegroundClipPreservesPaneInteriorsAndExcludesGapsAndCorners() {
        for width: CGFloat in [424, 1024] {
            let size = CGSize(width: width, height: 784)
            let plan = FloatingShellGeometry(size: size, borderWidth: 12)
            let path = FloatingShellForegroundShape(geometry: plan).path(in: CGRect(origin: .zero, size: size))
            for pane in [plan.navigation, plan.content, plan.dock] {
                XCTAssertTrue(path.contains(CGPoint(x: pane.midX, y: pane.midY)))
                XCTAssertFalse(path.contains(CGPoint(x: pane.minX + 1, y: pane.maxY - 1)))
            }
            XCTAssertFalse(path.contains(CGPoint(x: plan.dock.midX, y: plan.content.maxY + plan.dockGap / 2)))
        }
    }
}

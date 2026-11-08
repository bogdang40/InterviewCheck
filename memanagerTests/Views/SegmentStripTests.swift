import AppKit
import SwiftUI
import XCTest
@testable import memanager

@MainActor
final class SegmentStripTests: XCTestCase {
    func testInitialAndChangedSelectionsScrollIntoView() throws {
        try withFixture { model, scroll in
            waitUntil { self.isAtTrailingEdge(scroll) }
            XCTAssertTrue(isAtTrailingEdge(scroll), "The initially selected last segment must be visible.")

            model.selection = 0
            waitUntil { scroll.documentVisibleRect.minX < 1 }
            XCTAssertLessThan(scroll.documentVisibleRect.minX, 1)

            model.selection = 5
            waitUntil { self.isAtTrailingEdge(scroll) }
            XCTAssertTrue(isAtTrailingEdge(scroll), "Selecting a later segment must reveal it.")
        }
    }

    func testUnrelatedUpdatesDoNotResetManualScrolling() throws {
        try withFixture { model, scroll in
            waitUntil { self.isAtTrailingEdge(scroll) }
            XCTAssertTrue(isAtTrailingEdge(scroll))
            scroll.contentView.scroll(to: NSPoint(x: 30, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            let position = scroll.documentVisibleRect.minX

            model.revision += 1
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))

            XCTAssertEqual(scroll.documentVisibleRect.minX, position, accuracy: 1)
        }
    }

    func testNarrowingViewportKeepsSelectedLastSegmentVisible() async throws {
        let model = FixtureModel()
        let host = NSHostingView(rootView: Fixture(model: model))
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 90),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await waitUntilAsync { self.findScrollView(in: host) != nil }
        let scroll = try XCTUnwrap(findScrollView(in: host))
        try await waitUntilAsync { scroll.documentVisibleRect.width > 700 }
        XCTAssertGreaterThan(scroll.documentVisibleRect.width, 700)
        XCTAssertEqual(model.selection, 5)

        window.setContentSize(NSSize(width: 240, height: 90))
        host.layoutSubtreeIfNeeded()
        try await waitUntilAsync { self.isAtTrailingEdge(scroll) }

        XCTAssertLessThan(scroll.documentVisibleRect.width, 300)
        XCTAssertTrue(isAtTrailingEdge(scroll), "Narrowing the viewport must keep the selected last segment visible.")
        XCTAssertEqual(model.selection, 5)
    }

    private func withFixture(_ check: (FixtureModel, NSScrollView) throws -> Void) throws {
        let model = FixtureModel()
        let size = NSSize(width: 240, height: 90)
        let host = NSHostingView(rootView: Fixture(model: model).frame(width: size.width, height: size.height))
        let window = NSPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        waitUntil { self.findScrollView(in: host) != nil }
        let scroll = try XCTUnwrap(findScrollView(in: host))
        waitUntil { (scroll.documentView?.bounds.width ?? 0) > scroll.documentVisibleRect.width }
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.bounds.width, scroll.documentVisibleRect.width)
        try check(model, scroll)
    }

    private func isAtTrailingEdge(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView,
              document.bounds.width > scroll.documentVisibleRect.width else { return false }
        return scroll.documentVisibleRect.maxX >= document.bounds.maxX - 1
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }

    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(1)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func waitUntilAsync(_ condition: () -> Bool) async throws {
        await Task.yield()
        let deadline = Date().addingTimeInterval(1)
        while !condition() && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private final class FixtureModel: ObservableObject {
        @Published var selection = 5
        @Published var revision = 0
    }

    private struct Fixture: View {
        @ObservedObject var model: FixtureModel

        var body: some View {
            VStack {
                SegmentStrip(items: (0..<6).map { SegmentItem(id: $0, title: "Section \($0)") },
                             selection: $model.selection)
                Text("Revision \(model.revision)")
            }
        }
    }
}

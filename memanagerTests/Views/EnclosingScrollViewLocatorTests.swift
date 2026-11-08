import XCTest
import AppKit
@testable import memanager

final class EnclosingScrollViewLocatorTests: XCTestCase {
    func testFindsScrollViewInSuperviewChain() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let container = NSView()
        let probe = NSView()
        container.addSubview(probe)
        scrollView.documentView = container

        XCTAssertTrue(EnclosingScrollViewLocator.locate(around: probe) === scrollView)
    }

    func testFindsScrollViewInSubtreeWhenNoAncestorMatches() {
        let root = NSView()
        let scrollView = NSScrollView()
        root.addSubview(NSView())
        root.addSubview(scrollView)

        // From the root, neither the enclosing lookup nor the superview
        // chain matches; the subtree fallback finds the child scroll view.
        XCTAssertTrue(EnclosingScrollViewLocator.locate(around: root) === scrollView)
    }

    func testSiblingProbeWithoutSubtreeMatchReturnsNil() {
        let root = NSView()
        root.addSubview(NSScrollView())
        let probe = NSView()
        root.addSubview(probe)

        // The probe's own subtree is empty and no ancestor is a scroll view;
        // a sibling scroll view must NOT be picked up.
        XCTAssertNil(EnclosingScrollViewLocator.locate(around: probe))
    }

    func testReturnsNilWhenNoScrollViewExists() {
        let lonely = NSView()
        XCTAssertNil(EnclosingScrollViewLocator.locate(around: lonely))
    }
}

final class ScrollCoordinatorTests: XCTestCase {
    @MainActor
    func testRetainedRegistrarReclaimsTargetAndInactiveRegistrarCannotReplaceIt() {
        let coordinator = ScrollCoordinator.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let first = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let second = NSScrollView(frame: NSRect(x: 200, y: 0, width: 200, height: 100))
        first.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))
        second.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))
        let firstRegistrar = ScrollViewRegistrar.RegistrarView()
        let secondRegistrar = ScrollViewRegistrar.RegistrarView()
        firstRegistrar.configure(target: .mlGuide, isActive: true)
        secondRegistrar.configure(target: .mlGuide, isActive: false)
        first.documentView?.addSubview(firstRegistrar)
        second.documentView?.addSubview(secondRegistrar)
        container.addSubview(first)
        container.addSubview(second)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        func scroll() {
            // Ownership is independent of AppKit's offscreen animation clock.
            XCTAssertTrue(coordinator.scroll(target: .mlGuide, delta: 40, animated: false))
        }
        scroll()
        XCTAssertGreaterThan(first.contentView.bounds.minY, 0)
        XCTAssertEqual(second.contentView.bounds.minY, 0)
        firstRegistrar.configure(target: .mlGuide, isActive: false)
        secondRegistrar.configure(target: .mlGuide, isActive: true)
        let firstPosition = first.contentView.bounds.minY
        scroll()
        XCTAssertEqual(first.contentView.bounds.minY, firstPosition)
        XCTAssertGreaterThan(second.contentView.bounds.minY, 0)
        firstRegistrar.configure(target: .mlGuide, isActive: true)
        secondRegistrar.configure(target: .mlGuide, isActive: false)
        secondRegistrar.attemptRegistration(allowRetry: false)
        let secondPosition = second.contentView.bounds.minY
        scroll()
        XCTAssertGreaterThan(first.contentView.bounds.minY, firstPosition)
        XCTAssertEqual(second.contentView.bounds.minY, secondPosition)
    }

    func testRegisterScrollAndUnregister() {
        let coordinator = ScrollCoordinator.shared
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))
        scrollView.documentView = document

        coordinator.register(scrollView, for: .mlGuide)
        XCTAssertTrue(coordinator.scroll(target: .mlGuide, delta: 50))

        coordinator.unregister(scrollView, for: .mlGuide)
        XCTAssertFalse(coordinator.scroll(target: .mlGuide, delta: 50), "Unregistered target must miss")
    }

    func testStaleUnregisterCannotEvictNewerRegistration() {
        let coordinator = ScrollCoordinator.shared
        let older = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        older.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))
        let newer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        newer.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 1000))

        coordinator.register(older, for: .mlGuide)
        coordinator.register(newer, for: .mlGuide)
        coordinator.unregister(older, for: .mlGuide)

        XCTAssertTrue(coordinator.scroll(target: .mlGuide, delta: 25), "The newer registration must survive a stale detach")
        coordinator.unregister(newer, for: .mlGuide)
    }
}

import XCTest
@testable import memanager

final class OverlayWindowTests: XCTestCase {
    @MainActor
    private final class RecordingWindow: OverlayWindowPresenting {
        var operations: [String] = []
        var responder: NSResponder? = NSResponder()
        func orderFront(_ sender: Any?) { operations.append("show") }
        func makeKeyAndOrderFront(_ sender: Any?) { operations.append("focus") }
        func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            self.responder = responder
            operations.append("clear responder")
            return true
        }
        func orderOut(_ sender: Any?) { operations.append("hide") }
    }

    @MainActor
    func testViewingAnOverlayNeverRequestsKeyboardFocus() {
        let window = RecordingWindow()
        let presentation = OverlayWindowPresentation(window: window)
        presentation.show()
        presentation.show(intent: .viewing)
        XCTAssertEqual(window.operations, ["show", "show"])
    }

    @MainActor
    func testExplicitInputCanFocusAfterPassiveViewing() {
        let window = RecordingWindow()
        let presentation = OverlayWindowPresentation(window: window)
        presentation.show()
        presentation.show(intent: .keyboardInput)
        XCTAssertEqual(window.operations, ["show", "focus"])
    }

    @MainActor
    func testHidingClearsTheEditorBeforeOrderingOut() {
        let window = RecordingWindow()
        OverlayWindowPresentation(window: window).hide()
        XCTAssertNil(window.responder)
        XCTAssertEqual(window.operations, ["clear responder", "hide"])
    }

    @MainActor
    func testNativePassivePanelPreservesKeyboardOwnershipAndReleasesItsEditor() {
        let window = OverlayWindow()
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        window.contentView = editor
        window.makeFirstResponder(editor)
        let presentation = OverlayWindowPresentation(window: window)
        defer { presentation.hide() }
        let previousKeyWindow = NSApp.keyWindow
        let previousActiveState = NSApp.isActive
        let previousFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        presentation.show()
        presentation.show()

        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertTrue(NSApp.keyWindow === previousKeyWindow)
        XCTAssertEqual(NSApp.isActive, previousActiveState)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, previousFrontmostPID)

        presentation.hide()
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.firstResponder === editor)
    }

    @MainActor
    func testOverlayWindowUsesMousePassthroughDefaults() {
        let window = OverlayWindow()

        // The interviewer version is never hidden from screen sharing.
        XCTAssertNotEqual(window.sharingType, .none)
        XCTAssertFalse(window.collectionBehavior.contains(.stationary))
        XCTAssertFalse(window.ignoresMouseEvents)
        XCTAssertFalse(window.isMovableByWindowBackground)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.canBecomeKey)
    }
}

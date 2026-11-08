import XCTest
@testable import memanager

final class HotkeyManagerTests: XCTestCase {
    func testOrdinaryKeyboardEventsPassThroughTheProductionEventRouter() {
        let manager = HotkeyManager(bindings: HotkeyRegistry.defaultBindings)
        manager.shouldRouteOverlayKeyboardInput = { false }
        var routedCommands = 0
        manager.onPerformOverlayCommand = { _ in
            routedCommands += 1
            return true
        }
        let typingFlags: [CGEventFlags] = [[], .maskShift, .maskAlphaShift, [.maskShift, .maskAlphaShift]]

        for flags in typingFlags {
            for keyCode in UInt16(0)...127 {
                let event = makeEvent(keyCode: keyCode, flags: flags)
                let result = manager.handleEvent(type: .keyDown, event: event)
                XCTAssertTrue(result?.takeUnretainedValue() === event, "Consumed ordinary key \(keyCode) with flags \(flags.rawValue)")
            }
        }
        XCTAssertEqual(routedCommands, 0)
    }

    func testControlModifiedQuickAssistShortcutPassesThrough() {
        let manager = HotkeyManager(bindings: HotkeyRegistry.defaultBindings)
        let event = makeEvent(keyCode: 44, flags: [.maskCommand, .maskControl])
        XCTAssertTrue(manager.handleEvent(type: .keyDown, event: event)?.takeUnretainedValue() === event)
    }

    @MainActor
    func testMatchingHotkeyReturnsBeforeItsUIActionRuns() async {
        let manager = HotkeyManager(bindings: HotkeyRegistry.defaultBindings)
        let performed = expectation(description: "Visibility action queued after event routing")
        var didRun = false
        manager.onToggleVisibility = {
            XCTAssertTrue(Thread.isMainThread)
            didRun = true
            performed.fulfill()
        }
        let event = makeEvent(keyCode: 2, flags: .maskCommand)

        XCTAssertNil(manager.handleEvent(type: .keyDown, event: event))
        XCTAssertFalse(didRun, "Global event callbacks must not synchronously perform UI work")
        await fulfillment(of: [performed], timeout: 2)
        XCTAssertTrue(didRun)
    }

    @MainActor
    func testSectionShortcutQueuesItsArgumentWithoutBlockingTheTap() async {
        let manager = HotkeyManager(bindings: HotkeyRegistry.defaultBindings)
        let performed = expectation(description: "Section action queued after event routing")
        var selectedSection: Int?
        manager.onJumpToSection = { section in
            selectedSection = section
            performed.fulfill()
        }
        let event = makeEvent(keyCode: 18, flags: .maskCommand)

        XCTAssertNil(manager.handleEvent(type: .keyDown, event: event))
        XCTAssertNil(selectedSection)
        await fulfillment(of: [performed], timeout: 2)
        XCTAssertEqual(selectedSection, 0)
    }

    func testRegistryDefaultBindingsIncludeLiveResponseCardHotkeys() {
        XCTAssertEqual(HotkeyRegistry.defaultBindings["cycleLiveResponseCard"], .cycleLiveResponseCard)
        XCTAssertEqual(HotkeyRegistry.defaultBindings["pinLiveResponseCard"], .pinLiveResponseCard)
        XCTAssertEqual(HotkeyRegistry.defaultBindings["quickAssistCycleMode"], .quickAssistCycleMode)
    }

    func testOverlayKeyboardCommandsMapFromExpectedKeys() {
        let nextFocusEvent = makeEvent(keyCode: 48, flags: [])
        XCTAssertEqual(
            HotkeyManager.overlayCommand(
                keyCode: HotkeyManager.Hotkey.overlayNextFocus.keyCode,
                flags: HotkeyManager.Hotkey.overlayNextFocus.modifiers,
                event: nextFocusEvent
            ),
            .nextFocus
        )
        let previousFocusEvent = makeEvent(keyCode: 48, flags: [.maskShift])
        XCTAssertEqual(
            HotkeyManager.overlayCommand(
                keyCode: HotkeyManager.Hotkey.overlayPreviousFocus.keyCode,
                flags: HotkeyManager.Hotkey.overlayPreviousFocus.modifiers,
                event: previousFocusEvent
            ),
            .previousFocus
        )
        let deleteSelectionEvent = makeEvent(keyCode: 51, flags: [.maskCommand])
        XCTAssertEqual(
            HotkeyManager.overlayCommand(
                keyCode: HotkeyManager.Hotkey.overlayDeleteSelection.keyCode,
                flags: HotkeyManager.Hotkey.overlayDeleteSelection.modifiers,
                event: deleteSelectionEvent
            ),
            .deleteSelection
        )
    }

    private func makeEvent(keyCode: UInt16, flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true)!
        event.flags = flags
        return event
    }
}

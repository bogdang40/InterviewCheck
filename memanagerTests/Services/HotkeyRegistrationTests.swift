import AppKit
import XCTest
@testable import memanager

@MainActor
final class HotkeyRegistrationTests: XCTestCase {
    func testPermissionAndFailedTapRemainRetryableWithoutFalseReady() {
        let tap = RegistrationTap(outcomes: [(false, false), (true, true)])
        let manager = HotkeyManager(bindings: HotkeyRegistry.defaultBindings, eventTap: tap)
        let startup = HotkeyStartupRegistration()
        var readyCount = 0
        func attempt(granted: Bool) -> Bool {
            startup.attempt(accessibilityGranted: granted,
                            register: { manager.registerDefaultHotkeys() }, onReady: { readyCount += 1 })
        }

        XCTAssertFalse(attempt(granted: false))
        XCTAssertEqual(tap.installCount, 0, "Denied trust must remain waiting without installing a hook")
        XCTAssertEqual(readyCount, 0)
        XCTAssertFalse(attempt(granted: true))
        XCTAssertFalse(startup.isReady)
        XCTAssertEqual(readyCount, 0, "A trusted process with a failed event tap is not Ready")
        XCTAssertEqual(tap.invalidationCount, 1)

        XCTAssertTrue(attempt(granted: true))
        XCTAssertTrue(startup.isReady)
        XCTAssertEqual(readyCount, 1)
        XCTAssertEqual(tap.installCount, 2)
        XCTAssertTrue(attempt(granted: true))
        XCTAssertTrue(manager.registerDefaultHotkeys())
        XCTAssertEqual(tap.installCount, 2, "Repeated registration must retain the one enabled hook")
        XCTAssertEqual(readyCount, 1, "Ready UI and audio follow-up must run only once")
    }

    func testDisabledTapDoesNotReportSuccessAndCanRetryAfterCleanup() {
        let tap = RegistrationTap(outcomes: [(true, false), (true, true), (true, true)])
        let manager = HotkeyManager(bindings: HotkeyRegistry.defaultBindings, eventTap: tap)
        XCTAssertFalse(manager.registerDefaultHotkeys())
        XCTAssertEqual(tap.invalidationCount, 1)
        XCTAssertTrue(manager.registerDefaultHotkeys())
        manager.unregisterAll()
        XCTAssertFalse(tap.isEnabled)
        XCTAssertEqual(tap.invalidationCount, 2)
        XCTAssertTrue(manager.registerDefaultHotkeys())
        XCTAssertEqual(tap.installCount, 3)
    }

    func testTrustRevocationAndRegrantRecheckReadinessWithoutRepeatingStartup() {
        let tap = RegistrationTap(outcomes: [(true, true), (true, true)])
        let manager = HotkeyManager(bindings: HotkeyRegistry.defaultBindings, eventTap: tap)
        let startup = HotkeyStartupRegistration()
        var readyCount = 0
        func attempt(granted: Bool) -> Bool {
            startup.attempt(accessibilityGranted: granted,
                register: { manager.registerDefaultHotkeys() }, onReady: { readyCount += 1 })
        }

        XCTAssertTrue(attempt(granted: true))
        tap.invalidate()
        XCTAssertFalse(attempt(granted: false))
        XCTAssertFalse(startup.isReady)
        XCTAssertEqual(tap.installCount, 1, "Revoked trust must not reinstall a global hook")
        XCTAssertTrue(attempt(granted: true))
        XCTAssertTrue(startup.isReady)
        XCTAssertEqual(tap.installCount, 2)
        XCTAssertEqual(readyCount, 1, "Recovery must not repeat startup UI or audio prompts")
    }

    func testLostTapAfterStartupRetriesFailedReplacement() {
        let tap = RegistrationTap(outcomes: [(true, true), (false, false), (true, true)])
        let manager = HotkeyManager(bindings: HotkeyRegistry.defaultBindings, eventTap: tap)
        let startup = HotkeyStartupRegistration()
        var readyCount = 0
        func attempt() -> Bool {
            startup.attempt(accessibilityGranted: true,
                register: { manager.registerDefaultHotkeys() }, onReady: { readyCount += 1 })
        }

        XCTAssertTrue(attempt())
        tap.invalidate()
        XCTAssertFalse(attempt())
        XCTAssertFalse(startup.isReady)
        XCTAssertTrue(attempt())
        XCTAssertEqual(tap.installCount, 3)
        XCTAssertEqual(readyCount, 1)
    }

    func testManagerLifetimeInvalidatesAnInstalledHook() {
        let tap = RegistrationTap(outcomes: [(true, true)])
        var manager: HotkeyManager? = HotkeyManager(bindings: HotkeyRegistry.defaultBindings, eventTap: tap)
        XCTAssertTrue(manager!.registerDefaultHotkeys())
        manager = nil
        XCTAssertFalse(tap.isEnabled)
        XCTAssertEqual(tap.invalidationCount, 1)
    }
}

private final class RegistrationTap: HotkeyEventTapControlling {
    private var outcomes: [(registered: Bool, enabled: Bool)]
    private(set) var isEnabled = false
    private(set) var installCount = 0
    private(set) var invalidationCount = 0

    init(outcomes: [(Bool, Bool)]) { self.outcomes = outcomes }

    func install(callback: @escaping CGEventTapCallBack, userInfo: UnsafeMutableRawPointer) -> Bool {
        installCount += 1
        guard !outcomes.isEmpty else { return false }
        let outcome = outcomes.removeFirst()
        isEnabled = outcome.enabled
        return outcome.registered
    }

    func enable() { isEnabled = true }
    func invalidate() { isEnabled = false; invalidationCount += 1 }
}

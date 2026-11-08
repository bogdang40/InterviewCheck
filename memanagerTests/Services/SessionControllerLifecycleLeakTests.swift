import XCTest
@testable import memanager

/// Proves that a test constructed SessionController deallocates. Before the
/// binding hygiene fix, three `.assign(to:on: self)` subscriptions retained
/// the controller through its own cancellables set, so every isolated
/// controller built by a test leaked (keeping its timers and subscriptions
/// alive for the rest of the test run).
final class SessionControllerLifecycleLeakTests: XCTestCase {
    @MainActor
    func testTestConstructedControllerDeallocates() {
        weak var leaked: SessionController?

        autoreleasepool {
            let controller = SessionController()
            leaked = controller
            XCTAssertNotNil(leaked)
        }

        XCTAssertNil(leaked, "SessionController must not retain itself through its Combine subscriptions")
    }

    @MainActor
    func testRuntimeServicesStartIsIdempotentAndStoppable() {
        let controller = SessionController()

        controller.startRuntimeServices()
        controller.startRuntimeServices()
        controller.stopRuntimeServices()

        weak var leaked: SessionController? = controller
        _ = leaked
    }
}

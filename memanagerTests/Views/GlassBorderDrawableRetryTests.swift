import XCTest
@testable import memanager

final class GlassBorderDrawableRetryTests: XCTestCase {
    func testTransientLossReceivesOnlyThreeIncreasingRetries() {
        var retry = GlassBorderDrawableRetry()
        XCTAssertEqual(retry.nextDelay(), 0.016)
        XCTAssertEqual(retry.nextDelay(), 0.032)
        XCTAssertEqual(retry.nextDelay(), 0.064)
        for _ in 0..<100 { XCTAssertNil(retry.nextDelay(), "Missing drawables must not create an idle render loop") }
    }

    func testNewConfigurationOrVisibilityRestoresAnExhaustedBudget() {
        var retry = GlassBorderDrawableRetry()
        for _ in 0..<3 { _ = retry.nextDelay() }
        XCTAssertNil(retry.nextDelay())
        retry.reset()
        XCTAssertEqual(retry.nextDelay(), 0.016)
        XCTAssertEqual(retry.nextDelay(), 0.032)
        XCTAssertEqual(retry.nextDelay(), 0.064)
        XCTAssertNil(retry.nextDelay())
    }
}

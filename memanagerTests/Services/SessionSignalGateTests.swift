import XCTest
@testable import memanager

final class SessionSignalGateTests: XCTestCase {
    func testDisabledNudgesAlwaysClear() {
        let disposition = SessionSignalGate.disposition(
            proactiveNudgesEnabled: false,
            isLoading: true,
            isStreaming: false,
            isQuickAssistLoading: false,
            isMLGuideLoading: false
        )

        XCTAssertEqual(disposition, .clear)
    }

    func testAnyBusyFlagHoldsTheSignal() {
        let busyCombinations: [(Bool, Bool, Bool, Bool)] = [
            (true, false, false, false),
            (false, true, false, false),
            (false, false, true, false),
            (false, false, false, true)
        ]
        for (loading, streaming, quickAssist, mlGuide) in busyCombinations {
            let disposition = SessionSignalGate.disposition(
                proactiveNudgesEnabled: true,
                isLoading: loading,
                isStreaming: streaming,
                isQuickAssistLoading: quickAssist,
                isMLGuideLoading: mlGuide
            )
            XCTAssertEqual(disposition, .hold)
        }
    }

    func testIdleEnabledSessionApplies() {
        let disposition = SessionSignalGate.disposition(
            proactiveNudgesEnabled: true,
            isLoading: false,
            isStreaming: false,
            isQuickAssistLoading: false,
            isMLGuideLoading: false
        )

        XCTAssertEqual(disposition, .apply)
    }
}

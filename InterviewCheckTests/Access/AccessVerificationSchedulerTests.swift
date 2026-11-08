import XCTest
@testable import InterviewCheck

@MainActor
final class AccessVerificationSchedulerTests: XCTestCase {
    func testReplacedPollDoesNotReportFinishedForItsSuccessor() async {
        let scheduler = AccessVerificationScheduler()
        var finished: [String] = []

        scheduler.startCheckoutPolling(interval: 0.01, attempts: 3, verify: { false }, onFinished: { finished.append("first") })
        // The deep link path restarts polling at a shorter interval, which
        // cancels the first task while it sleeps.
        scheduler.startCheckoutPolling(interval: 0.01, attempts: 3, verify: { false }, onFinished: { finished.append("second") })

        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(finished, ["second"], "only the poll that ran to its own end reports back")
    }

    func testPollStopsEarlyWhenVerificationSucceeds() async {
        let scheduler = AccessVerificationScheduler()
        var verifications = 0
        var finished = 0

        scheduler.startCheckoutPolling(interval: 0.01, attempts: 10, verify: {
            verifications += 1
            return verifications == 2
        }, onFinished: { finished += 1 })

        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(verifications, 2)
        XCTAssertEqual(finished, 1)
    }

    func testStoppedPollNeverReportsFinished() async {
        let scheduler = AccessVerificationScheduler()
        var finished = 0

        scheduler.startCheckoutPolling(interval: 0.01, attempts: 3, verify: { false }, onFinished: { finished += 1 })
        scheduler.stopCheckoutPolling()

        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(finished, 0, "the owner already reset the flag when it stopped the poll")
    }
}

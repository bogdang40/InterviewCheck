import XCTest
@testable import InterviewCheck

final class AIStreamTextDeliveryTests: XCTestCase {
    func testFirstTextIsImmediateAndQuietStreamFlushesBeforeCompletion() async {
        let first = expectation(description: "first text")
        let quiet = expectation(description: "quiet connection flush")
        let delivery = AIStreamTextDelivery(policy: .batched(interval: 0.01, flushOnNewline: false)) { chunk in
            if chunk == "first" { first.fulfill() }
            if chunk == " second" { quiet.fulfill() }
        }
        delivery.append("first")
        await fulfillment(of: [first], timeout: 0.5)
        delivery.append(" second")
        // No subsequent append or finish can trigger this expectation.
        await fulfillment(of: [quiet], timeout: 1)
        delivery.finish()
    }

    func testFinishFlushesOnceAndRejectsLateTokens() {
        var chunks: [String] = []
        let delivery = AIStreamTextDelivery(policy: .batched(interval: 60, flushOnNewline: false)) { chunks.append($0) }
        delivery.append("a")
        XCTAssertEqual(chunks, ["a"])
        delivery.append("b")
        delivery.append("c")
        XCTAssertEqual(chunks, ["a"])
        delivery.finish()
        delivery.finish()
        delivery.append("late")
        XCTAssertEqual(chunks, ["a", "bc"])
    }

    func testNewlineFlushKeepsOrderAndStartsANewDeadline() async {
        let complete = expectation(description: "last token")
        let lock = NSLock()
        var text = ""
        let delivery = AIStreamTextDelivery(policy: .batched(interval: 0.02)) { chunk in
            lock.withLock { text += chunk }
            if chunk == "tail" { complete.fulfill() }
        }
        delivery.append("first")
        delivery.append(" line\n")
        delivery.append("tail")
        await fulfillment(of: [complete], timeout: 1)
        delivery.finish()
        XCTAssertEqual(lock.withLock { text }, "first line\ntail")
    }
}

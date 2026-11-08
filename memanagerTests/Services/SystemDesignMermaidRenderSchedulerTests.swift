import XCTest
@testable import memanager

final class SystemDesignMermaidRenderSchedulerTests: XCTestCase {
    func testCoalescesRapidUpdatesForSameSlot() async {
        let scheduler = SystemDesignMermaidRenderScheduler(
            baseIntervalMs: 120,
            minIntervalMs: 50,
            maxIntervalMs: 400,
            increaseStepMs: 50,
            decreaseStepMs: 50,
            isLoggingEnabled: false
        )
        let recorder = RenderRecorder()

        let firstHandle = Task {
            await scheduler.enqueue(slotID: "slot.scalability", requestID: "first")
        }
        let firstDecision = await firstHandle.value
        guard case .dispatch(let firstToken, _) = firstDecision else {
            XCTFail("Expected first request to dispatch")
            return
        }
        await recorder.recordDispatchStart("first")

        let secondHandle = Task {
            await scheduler.enqueue(slotID: "slot.scalability", requestID: "second")
        }
        await Task.yield()
        let thirdHandle = Task {
            await scheduler.enqueue(slotID: "slot.scalability", requestID: "third")
        }

        let secondDecision = await secondHandle.value
        if case .superseded = secondDecision {
            await recorder.recordSuperseded("second")
        } else {
            XCTFail("Expected second request to be superseded")
        }

        await scheduler.reportCompletion(token: firstToken, durationMs: 120, outcome: .success)
        await recorder.recordDispatchEnd()

        let thirdDecision = await thirdHandle.value
        guard case .dispatch(let thirdToken, _) = thirdDecision else {
            XCTFail("Expected third request to dispatch")
            return
        }
        await recorder.recordDispatchStart("third")
        await scheduler.reportCompletion(token: thirdToken, durationMs: 120, outcome: .success)
        await recorder.recordDispatchEnd()

        let isIdle = await scheduler.waitForIdle(timeoutMs: 2000)
        let snapshot = await recorder.snapshot()
        let dispatchedSet = Set(snapshot.dispatched)
        let supersededSet = Set(snapshot.superseded)

        XCTAssertTrue(isIdle)
        XCTAssertTrue(dispatchedSet.contains("third"))
        XCTAssertFalse(dispatchedSet.contains("second"))
        XCTAssertTrue(supersededSet.contains("second"))
        XCTAssertTrue(dispatchedSet.isDisjoint(with: supersededSet))
        XCTAssertEqual(dispatchedSet.union(supersededSet), Set(["first", "second", "third"]))
        XCTAssertLessThanOrEqual(snapshot.dispatched.count, 2)
    }

    func testDispatchesSeriallyAcrossSlots() async {
        let scheduler = SystemDesignMermaidRenderScheduler(
            baseIntervalMs: 15,
            minIntervalMs: 10,
            maxIntervalMs: 120,
            increaseStepMs: 10,
            decreaseStepMs: 10,
            isLoggingEnabled: false
        )
        let recorder = RenderRecorder()

        let handles = ["slot.a", "slot.b", "slot.c"].map { slot in
            Task {
                let decision = await scheduler.enqueue(slotID: slot, requestID: slot)
                guard case .dispatch(let token, _) = decision else { return }
                await recorder.recordDispatchStart(slot)
                try? await Task.sleep(nanoseconds: 60_000_000)
                await scheduler.reportCompletion(token: token, durationMs: 80, outcome: .success)
                await recorder.recordDispatchEnd()
            }
        }

        for handle in handles {
            await handle.value
        }

        let isIdle = await scheduler.waitForIdle(timeoutMs: 2000)
        let snapshot = await recorder.snapshot()

        XCTAssertTrue(isIdle)
        XCTAssertEqual(snapshot.maxConcurrent, 1)
        XCTAssertEqual(snapshot.dispatched.count, 3)
    }

    func testAdaptiveIntervalIncreasesAfterSustainedPressure() async {
        let scheduler = SystemDesignMermaidRenderScheduler(
            baseIntervalMs: 20,
            minIntervalMs: 10,
            maxIntervalMs: 100,
            increaseStepMs: 10,
            decreaseStepMs: 10,
            highPressureSamples: 2,
            lowPressureSamples: 3,
            isLoggingEnabled: false
        )

        await runSingleRequest(
            scheduler: scheduler,
            slotID: "slot.1",
            requestID: "req.1",
            durationMs: 900,
            outcome: .success
        )
        await runSingleRequest(
            scheduler: scheduler,
            slotID: "slot.2",
            requestID: "req.2",
            durationMs: 900,
            outcome: .success
        )

        let isIdle = await scheduler.waitForIdle(timeoutMs: 2000)
        XCTAssertTrue(isIdle)
        let currentInterval = await scheduler.currentIntervalMilliseconds()
        XCTAssertEqual(currentInterval, 30)
    }

    func testAdaptiveIntervalDecreasesAfterSustainedRecovery() async {
        let scheduler = SystemDesignMermaidRenderScheduler(
            baseIntervalMs: 40,
            minIntervalMs: 10,
            maxIntervalMs: 100,
            increaseStepMs: 10,
            decreaseStepMs: 10,
            highPressureSamples: 2,
            lowPressureSamples: 3,
            isLoggingEnabled: false
        )

        await runSingleRequest(
            scheduler: scheduler,
            slotID: "slot.1",
            requestID: "req.1",
            durationMs: 120,
            outcome: .success
        )
        let isIdleAfterFirst = await scheduler.waitForIdle(timeoutMs: 2000)
        XCTAssertTrue(isIdleAfterFirst)
        await runSingleRequest(
            scheduler: scheduler,
            slotID: "slot.2",
            requestID: "req.2",
            durationMs: 120,
            outcome: .success
        )
        let isIdleAfterSecond = await scheduler.waitForIdle(timeoutMs: 2000)
        XCTAssertTrue(isIdleAfterSecond)
        await runSingleRequest(
            scheduler: scheduler,
            slotID: "slot.3",
            requestID: "req.3",
            durationMs: 120,
            outcome: .success
        )

        let isIdle = await scheduler.waitForIdle(timeoutMs: 2000)
        XCTAssertTrue(isIdle)
        let currentInterval = await scheduler.currentIntervalMilliseconds()
        XCTAssertEqual(currentInterval, 30)
    }

    func testTimeoutCompletionUnblocksSubsequentDispatches() async {
        let scheduler = SystemDesignMermaidRenderScheduler(
            baseIntervalMs: 20,
            minIntervalMs: 10,
            maxIntervalMs: 120,
            increaseStepMs: 10,
            decreaseStepMs: 10,
            isLoggingEnabled: false
        )

        let firstCompleted = expectation(description: "first request completed via timeout")
        let secondDispatched = expectation(description: "second request dispatched")

        Task {
            let decision = await scheduler.enqueue(slotID: "slot.first", requestID: "first")
            guard case .dispatch(let token, _) = decision else { return }
            try? await Task.sleep(nanoseconds: 120_000_000)
            await scheduler.reportCompletion(token: token, durationMs: 2500, outcome: .timeout)
            firstCompleted.fulfill()
        }

        Task {
            let decision = await scheduler.enqueue(slotID: "slot.second", requestID: "second")
            guard case .dispatch(let token, _) = decision else { return }
            secondDispatched.fulfill()
            await scheduler.reportCompletion(token: token, durationMs: 120, outcome: .success)
        }

        await fulfillment(
            of: [firstCompleted, secondDispatched],
            timeout: 3.0,
            enforceOrder: true
        )

        let isIdle = await scheduler.waitForIdle(timeoutMs: 3000)
        XCTAssertTrue(isIdle)
    }

    func testColdSlotDispatchesImmediatelyWhileWarmSlotUsesInterval() async {
        let scheduler = SystemDesignMermaidRenderScheduler(
            baseIntervalMs: 240,
            minIntervalMs: 240,
            maxIntervalMs: 240,
            increaseStepMs: 10,
            decreaseStepMs: 10,
            isLoggingEnabled: false
        )

        let firstStart = Date()
        let firstDecision = await scheduler.enqueue(slotID: "slot.a", requestID: "a1")
        let firstElapsed = Date().timeIntervalSince(firstStart)
        guard case .dispatch(let firstToken, _) = firstDecision else {
            XCTFail("Expected first cold dispatch")
            return
        }
        await scheduler.reportCompletion(token: firstToken, durationMs: 80, outcome: .success)

        let warmStart = Date()
        let warmDecision = await scheduler.enqueue(slotID: "slot.a", requestID: "a2")
        let warmElapsed = Date().timeIntervalSince(warmStart)
        guard case .dispatch(let warmToken, _) = warmDecision else {
            XCTFail("Expected warm dispatch")
            return
        }
        await scheduler.reportCompletion(token: warmToken, durationMs: 80, outcome: .success)

        let secondColdStart = Date()
        let secondColdDecision = await scheduler.enqueue(slotID: "slot.b", requestID: "b1")
        let secondColdElapsed = Date().timeIntervalSince(secondColdStart)
        guard case .dispatch(let secondColdToken, _) = secondColdDecision else {
            XCTFail("Expected second cold dispatch")
            return
        }
        await scheduler.reportCompletion(token: secondColdToken, durationMs: 80, outcome: .success)

        let isIdle = await scheduler.waitForIdle(timeoutMs: 3000)
        XCTAssertTrue(isIdle)
        XCTAssertLessThan(firstElapsed, 0.20)
        XCTAssertGreaterThanOrEqual(warmElapsed, 0.15)
        XCTAssertLessThan(secondColdElapsed, 0.20)
    }

    private func runSingleRequest(
        scheduler: SystemDesignMermaidRenderScheduler,
        slotID: String,
        requestID: String,
        durationMs: Int,
        outcome: SystemDesignMermaidRenderScheduler.RenderOutcome
    ) async {
        let decision = await scheduler.enqueue(slotID: slotID, requestID: requestID)
        guard case .dispatch(let token, _) = decision else {
            XCTFail("Expected dispatch for request \(requestID)")
            return
        }
        await scheduler.reportCompletion(token: token, durationMs: durationMs, outcome: outcome)
    }
}

private actor RenderRecorder {
    private var dispatched: [String] = []
    private var superseded: [String] = []
    private var concurrentDispatches = 0
    private var maxConcurrent = 0

    func recordDispatchStart(_ requestID: String) {
        dispatched.append(requestID)
        concurrentDispatches += 1
        maxConcurrent = max(maxConcurrent, concurrentDispatches)
    }

    func recordDispatchEnd() {
        concurrentDispatches = max(0, concurrentDispatches - 1)
    }

    func recordSuperseded(_ requestID: String) {
        superseded.append(requestID)
    }

    func snapshot() -> (dispatched: [String], superseded: [String], maxConcurrent: Int) {
        (dispatched: dispatched, superseded: superseded, maxConcurrent: maxConcurrent)
    }

    func dispatchedIDs() -> [String] { dispatched }
    func supersededIDs() -> [String] { superseded }
    func maxConcurrentDispatches() -> Int { maxConcurrent }
}

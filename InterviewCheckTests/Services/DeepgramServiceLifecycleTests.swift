import XCTest
@testable import InterviewCheck

final class DeepgramServiceLifecycleTests: XCTestCase {
    @MainActor
    func testDisconnectDropsAlreadyQueuedTranscript() async {
        let service = DeepgramService()
        var received: [String] = []
        service.onTranscriptReceived = { received.append($0.text) }
        service.parseAndEmitResponse("""
        {"type":"Results","channel":{"alternatives":[{"transcript":"old stream text","confidence":0.9,"words":[]}]},"is_final":true}
        """)
        service.disconnect()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(received.isEmpty)
        XCTAssertNil(service.currentSpeaker)
    }

    @MainActor
    func testFinalizeWaitsForTheLastWordsThenCompletes() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let service = DualStreamDeepgramService(socketFactory: { _ in nil })
        var controls: [String] = []
        service.transmit = { _, message, _ in
            if case .string(let text) = message { controls.append(text) }
        }
        service.stateLock.withLock { service.micWebSocket = session.webSocketTask(with: URL(string: "wss://localhost/x")!) }
        service.micClock.recordSent(byteCount: 96_000 * 5, capturedAt: 1000)
        var events: [String] = []
        service.onFinalTimedWords = { batch in events.append(batch.words.map(\.word.word).joined(separator: " ")) }
        service.finalize(timeout: 2) { events.append("done") }
        XCTAssertEqual(controls, [DualStreamDeepgramService.finalizeMessage])
        XCTAssertEqual(DualStreamDeepgramService.finalizeMessage, #"{"type":"Finalize"}"#)
        await drainMainQueue()
        XCTAssertEqual(events, [], "still waiting for Deepgram")

        service.testInjectReceivedFrame("""
        {"type":"Results","channel":{"alternatives":[{"transcript":"last words","words":\
        [{"word":"last","start":1.0,"end":1.3},{"word":"words","start":1.3,"end":1.6}]}]},\
        "is_final":true,"from_finalize":true,"start":1.0,"duration":0.6}
        """, source: .microphone)
        await drainMainQueue()
        XCTAssertEqual(events, ["last words", "done"], "the last words reach the timeline before the stream closes")
        service.disconnect()
    }

    @MainActor
    func testFinalizeGivesUpAfterTheTimeoutAndWithoutStreamsAtOnce() async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let service = DualStreamDeepgramService(socketFactory: { _ in nil })
        var immediate = false
        service.finalize(timeout: 2) { immediate = true }
        XCTAssertTrue(immediate, "nothing to wait for")

        service.transmit = { _, _, _ in }
        service.stateLock.withLock { service.systemWebSocket = session.webSocketTask(with: URL(string: "wss://localhost/x")!) }
        let done = expectation(description: "timed out")
        let started = Date()
        service.finalize(timeout: 0.2) { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.19)
        service.disconnect()
    }

    func testStreamingSessionsOutliveALongInterview() {
        let config = DeepgramSessionConfiguration.make()
        XCTAssertEqual(config.timeoutIntervalForRequest, 30)
        XCTAssertGreaterThanOrEqual(config.timeoutIntervalForResource, 12 * 3600)
        let dual = DualStreamDeepgramService(socketFactory: { _ in nil })
        XCTAssertGreaterThanOrEqual(dual.urlSession?.configuration.timeoutIntervalForResource ?? 0, 12 * 3600)
        let legacy = DeepgramService()
        XCTAssertGreaterThanOrEqual(legacy.urlSession?.configuration.timeoutIntervalForResource ?? 0, 12 * 3600)
        legacy.disconnect(notify: false)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testStaleSocketFailureCannotDisconnectReplacement() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let service = DeepgramService()
        let url = URL(string: "wss://localhost/fixture")!
        let oldSocket = session.webSocketTask(with: url)
        let replacement = session.webSocketTask(with: url)
        service.webSocket = replacement
        service.handleDisconnection(
            error: URLError(.networkConnectionLost),
            expectedSocket: oldSocket
        )
        XCTAssertTrue(service.webSocket === replacement)
        XCTAssertEqual(service.connectionEpoch, 0)
        service.disconnect(notify: false)
    }
}

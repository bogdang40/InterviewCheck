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

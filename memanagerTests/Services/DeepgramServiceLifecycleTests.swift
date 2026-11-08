import XCTest
@testable import memanager

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

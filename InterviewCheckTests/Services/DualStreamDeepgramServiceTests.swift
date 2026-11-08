import XCTest
@testable import InterviewCheck

final class DualStreamDeepgramServiceTests: XCTestCase {
    func testSystemResultsFrameUpdatesInboundAndTranscriptMetrics() {
        let service = DualStreamDeepgramService()
        let callback = expectation(description: "system transcript callback")
        var receivedText: String?

        service.onSystemTranscript = { segment in
            receivedText = segment.text
            callback.fulfill()
        }

        service.testInjectReceivedFrame(resultsFrame, source: .systemAudio)
        wait(for: [callback], timeout: 1.0)

        let metrics = service.metricsSnapshot
        XCTAssertEqual(receivedText, "remote hello")
        XCTAssertEqual(metrics.system.inboundMessageCount, 1)
        XCTAssertEqual(metrics.system.nonEmptyTranscriptCount, 1)
        XCTAssertNotNil(metrics.system.lastTranscriptAt)
        XCTAssertEqual(metrics.mic.inboundMessageCount, 0)
        XCTAssertEqual(metrics.mic.nonEmptyTranscriptCount, 0)
    }

    func testErrorFrameRecordsSystemLastErrorWithoutTranscriptIncrement() {
        let service = DualStreamDeepgramService()
        service.testInjectReceivedFrame(errorFrame, source: .systemAudio)

        let metrics = service.metricsSnapshot
        XCTAssertEqual(metrics.system.inboundMessageCount, 1)
        XCTAssertEqual(metrics.system.nonEmptyTranscriptCount, 0)
        XCTAssertEqual(metrics.system.lastError, "rate limit")
    }

    @MainActor
    func testDisconnectDropsAlreadyQueuedTranscript() async {
        let service = DualStreamDeepgramService()
        var received: [String] = []
        service.onSystemTranscript = { received.append($0.text) }
        service.testInjectReceivedFrame(resultsFrame, source: .systemAudio)
        service.disconnect()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(received.isEmpty)
    }

    @MainActor
    func testReconnectDoesNotWaitForPublishedDisconnectState() async {
        var created = 0
        let service = DualStreamDeepgramService(socketFactory: { _ in
            created += 1
            return nil
        })
        service.apiKey = "fixture"
        service.systemConnectionState = .connected
        service.reconnectSystemStream()
        XCTAssertEqual(created, 1, "Reconnect must create a socket even before the UI publishes disconnected")
        service.disconnect()
    }

    @MainActor
    func testSystemReconnectDropsOldTranscriptButPreservesMicTranscript() async {
        let service = DualStreamDeepgramService(socketFactory: { _ in nil })
        service.apiKey = "fixture"
        var systemTexts: [String] = []
        var micTexts: [String] = []
        service.onSystemTranscript = { systemTexts.append($0.text) }
        service.onMicTranscript = { micTexts.append($0.text) }
        service.testInjectReceivedFrame(resultsFrame, source: .systemAudio)
        service.testInjectReceivedFrame(resultsFrame, source: .microphone)
        service.reconnectSystemStream()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertTrue(systemTexts.isEmpty)
        XCTAssertEqual(micTexts, ["remote hello"])
        service.disconnect()
    }

    func testSendSuccessCountersAreTrackedPerStream() {
        let service = DualStreamDeepgramService()

        service.testInjectSendSuccess(source: .microphone)
        service.testInjectSendSuccess(source: .systemAudio)
        service.testInjectSendSuccess(source: .systemAudio)

        let metrics = service.metricsSnapshot
        XCTAssertEqual(metrics.mic.sentChunkCount, 1)
        XCTAssertEqual(metrics.system.sentChunkCount, 2)
    }
}

private let resultsFrame = """
{"type":"Results","channel":{"alternatives":[{"transcript":"remote hello","confidence":0.98,"words":[{"word":"remote","start":0.0,"end":0.4,"speaker":2},{"word":"hello","start":0.4,"end":0.8,"speaker":2}]}]},"is_final":true,"start":0.0,"duration":0.8}
"""

private let errorFrame = """
{"type":"Error","error":"rate limit"}
"""

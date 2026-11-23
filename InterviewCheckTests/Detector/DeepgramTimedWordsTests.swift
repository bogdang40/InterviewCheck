import XCTest
@testable import InterviewCheck

/// The Deepgram service places final words on the host clock using the
/// audio it actually sent on each connection.
final class DeepgramTimedWordsTests: XCTestCase {
    private let finalFrame = """
    {"type":"Results","channel":{"alternatives":[{"transcript":"remote hello","confidence":0.98,\
    "words":[{"word":"remote","start":1.0,"end":1.4,"speaker":2},\
    {"word":"hello","start":1.4,"end":1.8,"speaker":2,"punctuated_word":"hello."}]}]},\
    "is_final":true,"start":1.0,"duration":0.8}
    """

    private let interimFrame = """
    {"type":"Results","channel":{"alternatives":[{"transcript":"remote","words":\
    [{"word":"remote","start":1.0,"end":1.4}]}]},"is_final":false,"start":1.0,"duration":0.4}
    """

    @MainActor
    func testFinalWordsAreMappedOntoTheHostClock() async {
        let service = DualStreamDeepgramService(socketFactory: { _ in nil })
        service.systemClock.recordSent(byteCount: 96_000 * 5, capturedAt: 1000)
        var received: DeepgramTimedWords?
        service.onFinalTimedWords = { received = $0 }

        service.testInjectReceivedFrame(finalFrame, source: .systemAudio)
        await drainMainQueue()

        XCTAssertEqual(received?.source, .systemAudio)
        XCTAssertEqual(received?.words.count, 2)
        XCTAssertEqual(received?.words[0].hostStart ?? 0, 1001.0, accuracy: 1e-9)
        XCTAssertEqual(received?.words[1].hostEnd ?? 0, 1001.8, accuracy: 1e-9)
        XCTAssertEqual(received?.clockBreaks, 0)
        service.disconnect()
    }

    @MainActor
    func testInterimResultsAreNotTimed() async {
        let service = DualStreamDeepgramService(socketFactory: { _ in nil })
        service.micClock.recordSent(byteCount: 96_000 * 5, capturedAt: 1000)
        var count = 0
        service.onFinalTimedWords = { _ in count += 1 }
        service.testInjectReceivedFrame(interimFrame, source: .microphone)
        await drainMainQueue()
        XCTAssertEqual(count, 0)
        service.disconnect()
    }

    @MainActor
    func testWordsBeforeAnyAudioWasSentAreNotTimed() async {
        let service = DualStreamDeepgramService(socketFactory: { _ in nil })
        var count = 0
        service.onFinalTimedWords = { _ in count += 1 }
        service.testInjectReceivedFrame(finalFrame, source: .microphone)
        await drainMainQueue()
        XCTAssertEqual(count, 0)
        service.disconnect()
    }

    func testQueuedAudioIsStampedWhenItArrivesNotWhenItIsSent() {
        let service = DualStreamDeepgramService(socketFactory: { _ in nil })
        var now: TimeInterval = 500
        service.uptime = { now }
        // No socket yet: both chunks queue, stamped at arrival.
        service.sendMicAudio(Data(count: 9_600)) // 0.1 s, arrives at 500.0
        now = 500.1
        service.sendMicAudio(Data(count: 9_600)) // arrives at 500.1
        let stamps = service.pendingMicAudioData.map(\.capturedAt)
        XCTAssertEqual(stamps.count, 2)
        XCTAssertEqual(stamps[0], 499.9, accuracy: 1e-9)
        XCTAssertEqual(stamps[1], 500.0, accuracy: 1e-9)
    }

    func testLiveAudioNeverOvertakesAudioQueuedBeforeTheStreamWasReady() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let service = DualStreamDeepgramService(socketFactory: { _ in nil })
        let sent = SentLog()
        let liveSent = expectation(description: "live chunk sent")
        service.transmit = { _, message, _ in
            guard case .data(let data) = message else { return }
            sent.append(data.count)
            if data.count == 100 {
                // While the queue is flushing, live audio arrives on another thread.
                DispatchQueue.global().async {
                    service.sendMicAudio(Data(count: 300))
                    liveSent.fulfill()
                }
                _ = sent.wait(forCount: 3, timeout: 0.3)
            }
        }
        service.stateLock.withLock { service.micWebSocket = session.webSocketTask(with: URL(string: "wss://localhost/x")!) }
        service.sendMicAudio(Data(count: 100))   // not ready yet: queued
        service.sendMicAudio(Data(count: 200))   // queued
        service.markReadyIfNeeded(.microphone)   // flushes both
        wait(for: [liveSent], timeout: 2)
        XCTAssertEqual(sent.values, [100, 200, 300], "queued audio first, then live audio")
        service.disconnect()
    }

    func testRequestKeepsFillerWords() {
        let url = DeepgramStreamCore.buildWebSocketURL(diarize: true, utterances: false)
        XCTAssertTrue(url?.absoluteString.contains("filler_words=true") ?? false)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
final class ReconnectGapTests: XCTestCase {
    private func batch(_ text: String, at start: TimeInterval, breaks: Int, connection: UInt64) -> DeepgramTimedWords {
        let word = DeepgramWord(word: text, start: 0, end: 0.3, confidence: 0.9, speaker: 1, punctuatedWord: text)
        return DeepgramTimedWords(source: .systemAudio, words: [.init(word: word, hostStart: start, hostEnd: start + 0.3)],
                                  clockBreaks: breaks, connection: connection)
    }

    func testAReconnectIsAGapEvenWhenTheBreakCountMatches() {
        let timeline = InterviewTimeline(uptime: { 0 })
        timeline.ingest(batch("first", at: 10, breaks: 0, connection: 1))
        timeline.ingest(batch("more", at: 11, breaks: 0, connection: 1))
        XCTAssertFalse(timeline.hasGap(between: 20, and: 30))
        // The socket reconnected mid-answer: a fresh clock, no breaks of its own yet.
        timeline.ingest(batch("after", at: 25, breaks: 0, connection: 2))
        XCTAssertTrue(timeline.hasGap(between: 20, and: 30), "audio between the sockets was never heard")

        // A count that goes down (a reconnect without a new epoch) is a gap too.
        let other = InterviewTimeline(uptime: { 0 })
        other.ingest(batch("a", at: 10, breaks: 2, connection: 1))
        other.ingest(batch("b", at: 40, breaks: 1, connection: 1))
        XCTAssertTrue(other.hasGap(between: 38, and: 45))
    }

    func testAReconnectAsksForTheVoiceAgain() {
        let timeline = InterviewTimeline(uptime: { 0 })
        timeline.ingest(batch("hello", at: 10, breaks: 0, connection: 1))
        timeline.candidateSpeakerIndex = 1
        XCTAssertFalse(timeline.voiceNeedsRepick)
        timeline.ingest(batch("again", at: 30, breaks: 0, connection: 2))
        XCTAssertNil(timeline.candidateSpeakerIndex, "voice numbers restart on a new connection")
        XCTAssertTrue(timeline.voiceNeedsRepick)
        timeline.candidateSpeakerIndex = 0
        XCTAssertFalse(timeline.voiceNeedsRepick)
    }
}

/// Sizes of chunks handed to the socket, in order, from any thread.
final class SentLog: @unchecked Sendable {
    private let condition = NSCondition()
    private var sizes: [Int] = []

    var values: [Int] { condition.withLock { sizes } }

    func append(_ size: Int) {
        condition.withLock {
            sizes.append(size)
            condition.broadcast()
        }
    }

    /// True once `count` chunks were sent; false after `timeout`.
    func wait(forCount count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while sizes.count < count {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }
}

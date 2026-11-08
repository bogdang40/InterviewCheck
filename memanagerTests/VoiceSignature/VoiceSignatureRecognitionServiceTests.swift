import XCTest
@testable import memanager

final class VoiceSignatureRecognitionServiceTests: XCTestCase {
    func testProcessingFailureIsReportedOnlyOncePerRun() {
        let service = VoiceSignatureRecognitionService()
        service.testActivate(with: FailingRecognitionEngine(error: .invalidArgument))
        defer { service.stop() }
        var failures: [EagleError] = []
        service.onProcessingError = { if let error = $0 as? EagleError { failures.append(error) } }
        service.testInjectFrame([1], timestamp: 0.1, source: .microphone)
        service.testInjectFrame([2], timestamp: 0.2, source: .systemAudio)
        XCTAssertEqual(failures, [.invalidArgument])
    }

    func testNoVoiceDoesNotReportFailureOrEmitSpeakerScore() {
        let service = VoiceSignatureRecognitionService()
        service.testActivate(with: FailingRecognitionEngine(error: .audioNoVoice))
        defer { service.stop() }
        var failures = 0
        var samples = 0
        service.onProcessingError = { _ in failures += 1 }
        service.onScoreSample = { _ in samples += 1 }
        service.testInjectFrame([1], timestamp: 0.1, source: .microphone)
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(samples, 0)
    }

    func testStoppedServiceRejectsLateFramesWhileReplacementRuns() {
        let stopped = VoiceSignatureRecognitionService()
        let replacement = VoiceSignatureRecognitionService()
        let oldEngine = CountingRecognitionEngine()
        let newEngine = CountingRecognitionEngine()
        stopped.testActivate(with: oldEngine)
        replacement.testActivate(with: newEngine)
        defer { replacement.stop() }

        stopped.stop()
        stopped.testInjectFrame([1, 2, 3], timestamp: 0.1, source: .microphone)
        XCTAssertEqual(oldEngine.processCount, 0)
        XCTAssertEqual(oldEngine.destroyCount, 1)
        XCTAssertEqual(newEngine.processCount, 0)

        replacement.testInjectFrame([4, 5, 6], timestamp: 0.2, source: .microphone)
        XCTAssertEqual(newEngine.processCount, 1)
    }

    func testScoreCallbackCanStopRecognitionWithoutDeadlock() {
        let service = VoiceSignatureRecognitionService()
        let engine = CountingRecognitionEngine()
        service.testActivate(with: engine)
        let finished = expectation(description: "score callback stopped recognition")
        service.onScoreSample = { _ in
            service.stop()
            finished.fulfill()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            service.testInjectFrame([1, 2, 3], timestamp: 0.1, source: .microphone)
        }
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(engine.destroyCount, 1)
        service.onScoreSample = nil
    }

    func testEngineLockIsReleasedWhenProcessThrows() {
        let service = VoiceSignatureRecognitionService()
        let engine = ThrowingThenSucceedingEngine()
        service.testActivate(with: engine)

        let finished = expectation(description: "frames processed without deadlock")
        DispatchQueue.global(qos: .userInitiated).async {
            service.testInjectFrame([1, 2, 3], timestamp: 0.1, source: .microphone)
            service.testInjectFrame([1, 2, 3], timestamp: 0.2, source: .microphone)
            finished.fulfill()
        }

        wait(for: [finished], timeout: 1.0)
        XCTAssertEqual(engine.callCount, 2)
    }
}

private final class FailingRecognitionEngine: EagleEngineProtocol {
    let error: EagleError
    init(error: EagleError) { self.error = error }
    func process(pcm: [Int16]) throws -> Float { throw error }
    func reset() throws {}
    func destroy() {}
}

private final class CountingRecognitionEngine: EagleEngineProtocol {
    private(set) var processCount = 0
    private(set) var destroyCount = 0
    func process(pcm: [Int16]) throws -> Float {
        processCount += 1
        return 0.9
    }
    func reset() throws {}
    func destroy() { destroyCount += 1 }
}

private final class ThrowingThenSucceedingEngine: EagleEngineProtocol {
    private(set) var callCount = 0

    func process(pcm: [Int16]) throws -> Float {
        callCount += 1
        if callCount == 1 {
            throw TestError.intentional
        }
        return 0.9
    }

    func reset() throws {}
    func destroy() {}

    private enum TestError: Error {
        case intentional
    }
}

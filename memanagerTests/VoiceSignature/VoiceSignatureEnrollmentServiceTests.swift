import AVFoundation
import XCTest
@testable import memanager

@MainActor
final class VoiceSignatureEnrollmentServiceTests: XCTestCase {
    func testFirstCompleteBatchClaimsExportBeforeOtherQueuedBatchesRun() async throws {
        let fixture = EnrollmentFixture(firstProgress: 100)
        let service = fixture.service
        defer { service.cancelEnrollment() }
        var failure: EagleError?
        service.onEnrollmentFailed = { failure = $0 }
        try service.startEnrollment()
        let framer = fixture.framers[0]
        framer.onFrameReady?([1, 1, 1, 1], 0)
        framer.onFrameReady?([2, 2, 2, 2], 1)
        framer.onFrameReady?([3, 3, 3, 3], 2)
        try fixture.work.runNext()
        // No main-queue completion has run yet. Later SDK work would now fail.
        fixture.profilers[0].enrollmentError = .runtimeError
        try fixture.work.runNext()
        try fixture.work.runNext()
        framer.onFrameReady?([4, 4, 4, 4], 3)
        XCTAssertNil(service.makeAudioConsumer())
        XCTAssertEqual(fixture.work.count, 0)
        XCTAssertEqual(fixture.profilers[0].enrolledSamples, [[1, 1, 1, 1]])

        await drainMainQueue()
        XCTAssertEqual(fixture.work.count, 1)
        try fixture.work.runNext()
        await drainMainQueue()
        XCTAssertEqual(fixture.profilers[0].exportCount, 1)
        XCTAssertEqual(fixture.savedProfiles.count, 1)
        XCTAssertEqual(service.state, .completed)
        XCTAssertNil(failure)
    }

    func testCanceledQueuedBatchCannotEnrollReplacementProfiler() async throws {
        let fixture = EnrollmentFixture()
        let service = fixture.service
        defer { service.cancelEnrollment() }
        try service.startEnrollment()
        fixture.framers[0].onFrameReady?([1, 1, 1, 1], 0)
        XCTAssertEqual(fixture.work.count, 1)

        service.cancelEnrollment()
        try service.startEnrollment()
        try fixture.work.runNext()
        XCTAssertTrue(fixture.profilers[0].enrolledSamples.isEmpty)
        XCTAssertTrue(fixture.profilers[1].enrolledSamples.isEmpty)
        XCTAssertEqual(fixture.profilers[0].destroyCount, 1)

        fixture.framers[1].onFrameReady?([2, 2, 2, 2], 0)
        try fixture.work.runNext()
        await drainMainQueue()
        XCTAssertEqual(fixture.profilers[1].enrolledSamples, [[2, 2, 2, 2]])
        XCTAssertEqual(service.progress, 25)
    }

    func testLateFramesAndPartialSamplesCannotCrossRetry() async throws {
        let fixture = EnrollmentFixture()
        let service = fixture.service
        defer { service.cancelEnrollment() }
        try service.startEnrollment()
        let oldFramer = fixture.framers[0]
        oldFramer.onFrameReady?([1, 1], 0)

        service.cancelEnrollment()
        try service.startEnrollment()
        let newFramer = fixture.framers[1]
        XCTAssertFalse(oldFramer === newFramer)
        oldFramer.onFrameReady?([2, 2, 2, 2], 0)
        newFramer.onFrameReady?([3, 3], 0)
        XCTAssertEqual(fixture.work.count, 0)

        newFramer.onFrameReady?([4, 4], 0)
        try fixture.work.runNext()
        await drainMainQueue()
        XCTAssertEqual(fixture.profilers[1].enrolledSamples, [[3, 3, 4, 4]])
    }

    func testCanceledQueuedExportCannotExportReplacementProfiler() async throws {
        let fixture = EnrollmentFixture(firstProgress: 100)
        let service = fixture.service
        defer { service.cancelEnrollment() }
        try service.startEnrollment()
        fixture.framers[0].onFrameReady?([1, 1, 1, 1], 0)
        try fixture.work.runNext()
        await drainMainQueue()
        XCTAssertEqual(service.state, .exporting)
        XCTAssertEqual(fixture.work.count, 1)

        service.cancelEnrollment()
        try service.startEnrollment()
        try fixture.work.runNext()
        await drainMainQueue()
        XCTAssertEqual(fixture.profilers[0].exportCount, 0)
        XCTAssertEqual(fixture.profilers[1].exportCount, 0)
        XCTAssertEqual(fixture.profilers[1].destroyCount, 0)
        XCTAssertTrue(fixture.savedProfiles.isEmpty)
        XCTAssertEqual(service.state, .enrolling(progress: 0))
    }

    func testExportResultDeliveredAfterCancelDoesNotSaveOrCompleteReplacement() async throws {
        let fixture = EnrollmentFixture(firstProgress: 100)
        let service = fixture.service
        defer { service.cancelEnrollment() }
        var completed = false
        service.onEnrollmentComplete = { _ in completed = true }
        try service.startEnrollment()
        fixture.framers[0].onFrameReady?([1, 1, 1, 1], 0)
        try fixture.work.runNext()
        await drainMainQueue()
        try fixture.work.runNext()
        XCTAssertEqual(fixture.profilers[0].exportCount, 1)

        // The SDK finished, but its main-queue save is still pending.
        service.cancelEnrollment()
        try service.startEnrollment()
        await drainMainQueue()
        XCTAssertFalse(completed)
        XCTAssertTrue(fixture.savedProfiles.isEmpty)
        XCTAssertEqual(fixture.profilers[0].destroyCount, 1)
        XCTAssertEqual(fixture.profilers[1].destroyCount, 0)
        XCTAssertEqual(service.state, .enrolling(progress: 0))
    }

    func testCanceledEnrollmentErrorCannotFailReplacement() async throws {
        let fixture = EnrollmentFixture()
        fixture.profilers[0].enrollmentError = .invalidState
        let service = fixture.service
        defer { service.cancelEnrollment() }
        var failure: EagleError?
        service.onEnrollmentFailed = { failure = $0 }
        try service.startEnrollment()
        fixture.framers[0].onFrameReady?([1, 1, 1, 1], 0)
        try fixture.work.runNext()
        service.cancelEnrollment()
        try service.startEnrollment()
        await drainMainQueue()

        XCTAssertNil(failure)
        XCTAssertEqual(fixture.profilers[1].destroyCount, 0)
        XCTAssertEqual(service.state, .enrolling(progress: 0))
    }

    func testSuccessfulEnrollmentSavesOnceAndReleasesProfiler() async throws {
        let fixture = EnrollmentFixture(firstProgress: 100)
        let service = fixture.service
        defer { service.cancelEnrollment() }
        var completedProfiles: [Data] = []
        service.onEnrollmentComplete = { completedProfiles.append($0) }
        try service.startEnrollment()
        fixture.framers[0].onFrameReady?([1, 1, 1, 1], 0)
        try fixture.work.runNext()
        await drainMainQueue()
        try fixture.work.runNext()
        await drainMainQueue()

        XCTAssertEqual(service.state, .completed)
        XCTAssertEqual(fixture.savedProfiles, [fixture.profilers[0].profile])
        XCTAssertEqual(completedProfiles, fixture.savedProfiles)
        XCTAssertEqual(fixture.profilers[0].destroyCount, 1)
        fixture.framers[0].onFrameReady?([2, 2, 2, 2], 0)
        XCTAssertEqual(fixture.work.count, 0)
    }

    func testSaveFailureReleasesProfilerAndAllowsRetry() async throws {
        let fixture = EnrollmentFixture(firstProgress: 100, saveSucceeds: false)
        let service = fixture.service
        defer { service.cancelEnrollment() }
        try service.startEnrollment()
        fixture.framers[0].onFrameReady?([1, 1, 1, 1], 0)
        try fixture.work.runNext()
        await drainMainQueue()
        try fixture.work.runNext()
        await drainMainQueue()

        XCTAssertEqual(service.state, .failed("Failed to save voice profile"))
        XCTAssertEqual(fixture.profilers[0].destroyCount, 1)
        try service.startEnrollment()
        await drainMainQueue()
        XCTAssertEqual(service.state, .enrolling(progress: 0))
        XCTAssertEqual(fixture.profilers[1].destroyCount, 0)
    }

    func testEnrollmentFailureReleasesProfilerAndAllowsRetry() async throws {
        let fixture = EnrollmentFixture()
        fixture.profilers[0].enrollmentError = .invalidState
        let service = fixture.service
        defer { service.cancelEnrollment() }
        var failure: EagleError?
        service.onEnrollmentFailed = { failure = $0 }
        try service.startEnrollment()
        fixture.framers[0].onFrameReady?([1, 1, 1, 1], 0)
        try fixture.work.runNext()
        await drainMainQueue()
        XCTAssertEqual(failure, .invalidState)
        XCTAssertEqual(fixture.profilers[0].destroyCount, 1)

        try service.startEnrollment()
        fixture.framers[1].onFrameReady?([2, 2, 2, 2], 0)
        try fixture.work.runNext()
        await drainMainQueue()
        XCTAssertEqual(fixture.profilers[1].enrolledSamples, [[2, 2, 2, 2]])
    }

    func testExportFailureReleasesProfilerWithoutSaving() async throws {
        let fixture = EnrollmentFixture(firstProgress: 100)
        fixture.profilers[0].exportError = .exportFailed
        let service = fixture.service
        defer { service.cancelEnrollment() }
        var failure: EagleError?
        service.onEnrollmentFailed = { failure = $0 }
        try service.startEnrollment()
        fixture.framers[0].onFrameReady?([1, 1, 1, 1], 0)
        try fixture.work.runNext()
        await drainMainQueue()
        try fixture.work.runNext()
        await drainMainQueue()

        XCTAssertEqual(failure, .exportFailed)
        XCTAssertEqual(fixture.profilers[0].destroyCount, 1)
        XCTAssertTrue(fixture.savedProfiles.isEmpty)
        XCTAssertNil(service.makeAudioConsumer())
    }

    func testCancelDiscardsPendingStateFeedbackAndMeterUpdates() async throws {
        let fixture = EnrollmentFixture()
        let service = fixture.service
        try service.startEnrollment()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData?[0][0] = 0.5
        let consume = try XCTUnwrap(service.makeAudioConsumer())
        consume(buffer, 0)
        service.cancelEnrollment()
        await drainMainQueue()

        XCTAssertEqual(service.state, .idle)
        XCTAssertNil(service.feedback)
        XCTAssertEqual(service.audioLevel, 0)
    }

    func testOldMicrophoneConsumerCannotSendAudioIntoReplacementRun() async throws {
        let fixture = EnrollmentFixture()
        let service = fixture.service
        defer { service.cancelEnrollment() }
        XCTAssertNil(service.makeAudioConsumer())
        try service.startEnrollment()
        let oldConsumer = try XCTUnwrap(service.makeAudioConsumer())
        service.cancelEnrollment()
        try service.startEnrollment()

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<1024 { samples[index] = 0.5 }
        oldConsumer(buffer, 0)
        await drainMainQueue()

        XCTAssertEqual(fixture.work.count, 0)
        XCTAssertTrue(fixture.profilers[1].enrolledSamples.isEmpty)
        XCTAssertEqual(service.audioLevel, 0)
        let newConsumer = try XCTUnwrap(service.makeAudioConsumer())
        newConsumer(buffer, 1)
        await drainMainQueue()
        XCTAssertEqual(service.audioLevel, 1)
        XCTAssertGreaterThan(fixture.work.count, 0)
    }

    private func drainMainQueue() async {
        // SDK delivery can enqueue one further state/feedback update.
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

private final class EnrollmentFixture {
    let service: VoiceSignatureEnrollmentService
    let work: EnrollmentWorkQueue
    let profilers: [EnrollmentProfilerStub]
    private let captured: CapturedEnrollment
    var framers: [PCM16ResamplerAndFramer] { captured.framers }
    var savedProfiles: [Data] { captured.savedProfiles }

    init(firstProgress: Float = 25, saveSucceeds: Bool = true) {
        let work = EnrollmentWorkQueue()
        let profilers = [EnrollmentProfilerStub(progress: firstProgress), EnrollmentProfilerStub(progress: 25)]
        let captured = CapturedEnrollment()
        self.work = work
        self.profilers = profilers
        self.captured = captured
        service = VoiceSignatureEnrollmentService(createProfiler: {
            guard captured.createdProfilerCount < profilers.count else { throw EagleError.invalidState }
            defer { captured.createdProfilerCount += 1 }
            return profilers[captured.createdProfilerCount]
        }, saveProfile: {
            captured.savedProfiles.append($0)
            return saveSucceeds
        }, enqueueProcessing: { work.append($0) }, minEnrollSamples: 4, makeFramer: {
            let framer = PCM16ResamplerAndFramer(source: .microphone)
            captured.framers.append(framer)
            return framer
        })
    }
}

private final class CapturedEnrollment {
    var createdProfilerCount = 0
    var framers: [PCM16ResamplerAndFramer] = []
    var savedProfiles: [Data] = []
}

private final class EnrollmentWorkQueue {
    private var pending: [() -> Void] = []
    var count: Int { pending.count }
    func append(_ work: @escaping () -> Void) { pending.append(work) }
    func runNext(file: StaticString = #filePath, line: UInt = #line) throws {
        let work = try XCTUnwrap(pending.first, "Expected queued enrollment work", file: file, line: line)
        pending.removeFirst()
        work()
    }
}

private final class EnrollmentProfilerStub: EagleProfilerProtocol {
    private(set) var enrolledSamples: [[Int16]] = []
    private(set) var exportCount = 0
    private(set) var destroyCount = 0
    let progress: Float
    let profile = Data([1, 2, 3, 4])
    var enrollmentError: EagleError?
    var exportError: EagleError?

    init(progress: Float) { self.progress = progress }
    func enroll(pcm: [Int16]) throws -> (progress: Float, feedback: EagleEnrollmentFeedback) {
        enrolledSamples.append(pcm)
        if let enrollmentError { throw enrollmentError }
        return (progress, .audioOK)
    }
    func exportProfile() throws -> Data {
        exportCount += 1
        if let exportError { throw exportError }
        return profile
    }
    func reset() throws {}
    func destroy() { destroyCount += 1 }
}

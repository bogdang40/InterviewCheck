import AVFoundation
import Combine
import Foundation

// MARK: - Enrollment Service

/// Drives the enrollment flow, emits progress and feedback
final class VoiceSignatureEnrollmentService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: EnrollmentState = .idle
    @Published private(set) var progress: Float = 0.0
    @Published private(set) var feedback: EnrollmentFeedback?
    @Published private(set) var audioLevel: Float = 0.0

    // MARK: - Dependencies

    private let createProfiler: () throws -> EagleProfilerProtocol
    private let saveProfile: (Data) -> Bool
    private let makeFramer: () -> PCM16ResamplerAndFramer
    private let enqueueProcessing: (@escaping () -> Void) -> Void
    private var profiler: EagleProfilerProtocol?
    private var framer: PCM16ResamplerAndFramer?

    // MARK: - Internal State

    private var enrollmentBuffer: [Int16] = []
    private let minEnrollSamples: Int
    private var isEnrollingFlag = false
    private var isExporting = false
    private var enrollmentGeneration = UUID()
    private let enrollmentLock = NSLock()
    private let profilerLock = NSLock()

    // MARK: - Callbacks

    /// Called when enrollment completes successfully with profile data
    var onEnrollmentComplete: ((Data) -> Void)?

    /// Called when enrollment fails
    var onEnrollmentFailed: ((EagleError) -> Void)?

    // MARK: - Initialization

    convenience init(store: VoiceSignatureStore = .shared) {
        let queue = DispatchQueue(label: "VoiceSignatureEnrollment.Processing", qos: .userInitiated)
        self.init(createProfiler: {
            guard let accessKey = store.loadAccessKey(), !accessKey.isEmpty else {
                throw EagleError.invalidAccessKey
            }
            guard !store.modelPath.isEmpty else {
                throw EagleError.modelLoadFailed("Model path is empty")
            }
            return try EagleBindings.createProfiler(accessKey: accessKey, modelPath: store.modelPath)
        }, saveProfile: store.saveProfile, enqueueProcessing: { work in queue.async(execute: work) })
    }

    init(createProfiler: @escaping () throws -> EagleProfilerProtocol,
         saveProfile: @escaping (Data) -> Bool,
         enqueueProcessing: @escaping (@escaping () -> Void) -> Void,
         minEnrollSamples: Int = EagleBindings.minEnrollSamples,
         makeFramer: @escaping () -> PCM16ResamplerAndFramer = { PCM16ResamplerAndFramer(source: .microphone) }) {
        precondition(minEnrollSamples > 0)
        self.createProfiler = createProfiler
        self.saveProfile = saveProfile
        self.enqueueProcessing = enqueueProcessing
        self.minEnrollSamples = minEnrollSamples
        self.makeFramer = makeFramer
    }

    // MARK: - Public Interface

    /// Start enrollment process
    /// - Throws: EagleError if initialization fails
    func startEnrollment() throws {
        // Every owner change takes profilerLock before enrollmentLock. A running
        // SDK operation finishes before cancellation can destroy or replace it.
        profilerLock.lock()
        defer { profilerLock.unlock() }
        guard !isEnrollingActive() else { return }
        let generation = UUID()
        enrollmentLock.lock()
        enrollmentGeneration = generation
        enrollmentLock.unlock()
        updateState(.preparing, generation: generation)

        do {
            profiler?.destroy()
            profiler = nil
            profiler = try createProfiler()
            let newFramer = makeFramer()
            newFramer.onFrameReady = { [weak self] frame, _ in
                self?.accumulateForEnrollment(frame, generation: generation)
            }

            enrollmentLock.lock()
            framer = newFramer
            enrollmentBuffer.removeAll()
            enrollmentBuffer.reserveCapacity(minEnrollSamples * 10)
            isEnrollingFlag = true
            isExporting = false
            enrollmentLock.unlock()
            progress = 0.0

            updateState(.enrolling(progress: 0), generation: generation)
            updateFeedback(.keepSpeaking, generation: generation)

        } catch let error as EagleError {
            updateState(.failed(error.localizedDescription), generation: generation)
            throw error
        } catch {
            let eagleError = EagleError.unknown(-1)
            updateState(.failed(error.localizedDescription), generation: generation)
            throw eagleError
        }
    }

    /// Cancel enrollment in progress
    func cancelEnrollment() {
        profilerLock.lock()
        enrollmentLock.lock()
        isEnrollingFlag = false
        isExporting = false
        enrollmentGeneration = UUID()
        let generation = enrollmentGeneration
        framer = nil
        enrollmentBuffer.removeAll()
        enrollmentLock.unlock()
        profiler?.destroy()
        profiler = nil
        profilerLock.unlock()
        updateState(.idle, generation: generation)
        feedback = nil
        audioLevel = 0
    }

    /// Bind a microphone tap to this run. A late callback from a stopped tap
    /// cannot send its audio into a replacement enrollment.
    func makeAudioConsumer() -> ((AVAudioPCMBuffer, UInt64) -> Void)? {
        enrollmentLock.lock()
        let activeFramer = isEnrollingFlag && !isExporting ? framer : nil
        let generation = enrollmentGeneration
        enrollmentLock.unlock()
        guard let activeFramer else { return nil }

        return { [weak self] buffer, hostTime in
            guard let self, self.isCurrentEnrollment(generation, requireAudio: true) else { return }
            let level = self.calculateAudioLevel(buffer: buffer)
            DispatchQueue.main.async {
                guard self.isCurrentEnrollment(generation) else { return }
                self.audioLevel = level
            }

            activeFramer.process(buffer: buffer, hostTime: hostTime)
        }
    }

    // MARK: - Private Methods

    private func accumulateForEnrollment(_ frame: [Int16], generation: UUID) {
        enrollmentLock.lock()
        guard isEnrollingFlag, !isExporting, enrollmentGeneration == generation else {
            enrollmentLock.unlock()
            return
        }

        enrollmentBuffer.append(contentsOf: frame)
        let shouldProcess = enrollmentBuffer.count >= minEnrollSamples
        enrollmentLock.unlock()

        // Process when we have enough samples
        if shouldProcess {
            processEnrollmentBatch(generation: generation)
        }
    }

    private func processEnrollmentBatch(generation: UUID) {
        enrollmentLock.lock()
        guard isEnrollingFlag, !isExporting, enrollmentGeneration == generation,
              enrollmentBuffer.count >= minEnrollSamples else {
            enrollmentLock.unlock()
            return
        }
        let samplesToProcess = Array(enrollmentBuffer.prefix(minEnrollSamples))
        enrollmentBuffer.removeFirst(minEnrollSamples)
        enrollmentLock.unlock()

        enqueueProcessing { [weak self] in
            guard let self else { return }

            do {
                guard let (newProgress, eagleFeedback) = try self.withProfiler(for: generation, requireAudio: true, {
                    let result = try $0.enroll(pcm: samplesToProcess)
                    if result.progress >= 100, result.feedback != .unknownSpeaker {
                        // Claim completion on the worker while profilerLock is
                        // held, before another queued batch can touch the SDK.
                        self.enrollmentLock.lock()
                        self.isExporting = true
                        self.framer = nil
                        self.enrollmentBuffer.removeAll()
                        self.enrollmentLock.unlock()
                    }
                    return result
                }) else { return }

                DispatchQueue.main.async {
                    guard self.isCurrentEnrollment(generation) else { return }
                    // Handle feedback first
                    self.handleEnrollmentFeedback(eagleFeedback, generation: generation)

                    // Only update progress if:
                    // 1. New progress is higher (prevent regression)
                    // 2. Feedback wasn't unknownSpeaker (rejected samples shouldn't affect progress)
                    let shouldUpdateProgress = eagleFeedback != .unknownSpeaker && newProgress > self.progress

                    if shouldUpdateProgress {
                        self.progress = newProgress
                        self.updateState(.enrolling(progress: newProgress), generation: generation)
                    }

                    // Check if enrollment is complete
                    if self.progress >= 100.0 {
                        self.finalizeEnrollment(generation: generation)
                    }
                }
            } catch let error as EagleError {
                DispatchQueue.main.async {
                    guard self.finishEnrollment(generation: generation) else { return }
                    self.updateState(.failed(error.localizedDescription), generation: generation)
                    self.onEnrollmentFailed?(error)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.finishEnrollment(generation: generation) else { return }
                    self.updateState(.failed(error.localizedDescription), generation: generation)
                }
            }
        }
    }

    private func handleEnrollmentFeedback(_ feedback: EagleEnrollmentFeedback, generation: UUID) {
        switch feedback {
        case .progressOnly:
            updateFeedback(.keepSpeaking, generation: generation)
        case .audioOK:
            updateFeedback(.goodQuality, generation: generation)
        case .audioTooShort:
            updateFeedback(.tooShort, generation: generation)
        case .unknownSpeaker:
            updateFeedback(.onlyYou, generation: generation)
        case .noVoiceFound:
            updateFeedback(.speakLouder, generation: generation)
        case .qualityIssue:
            updateFeedback(.reduceNoise, generation: generation)
        }
    }

    private func finalizeEnrollment(generation: UUID) {
        updateState(.exporting, generation: generation)

        enqueueProcessing { [weak self] in
            guard let self else { return }

            do {
                guard let profileData = try self.withProfiler(for: generation, { try $0.exportProfile() }) else { return }

                DispatchQueue.main.async {
                    guard self.isCurrentEnrollment(generation) else { return }
                    // Save profile
                    if self.saveProfile(profileData) {
                        guard self.finishEnrollment(generation: generation) else { return }
                        self.updateState(.completed, generation: generation)
                        self.onEnrollmentComplete?(profileData)
                    } else {
                        guard self.finishEnrollment(generation: generation) else { return }
                        self.updateState(.failed("Failed to save voice profile"), generation: generation)
                    }
                }
            } catch let error as EagleError {
                DispatchQueue.main.async {
                    guard self.finishEnrollment(generation: generation) else { return }
                    self.updateState(.failed(error.localizedDescription), generation: generation)
                    self.onEnrollmentFailed?(error)
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.finishEnrollment(generation: generation) else { return }
                    self.updateState(.failed(error.localizedDescription), generation: generation)
                }
            }
        }
    }

    private func finishEnrollment(generation: UUID) -> Bool {
        profilerLock.lock()
        defer { profilerLock.unlock() }
        enrollmentLock.lock()
        guard isEnrollingFlag, enrollmentGeneration == generation else {
            enrollmentLock.unlock()
            return false
        }
        isEnrollingFlag = false
        isExporting = false
        framer = nil
        enrollmentBuffer.removeAll()
        enrollmentLock.unlock()
        profiler?.destroy()
        profiler = nil
        return true
    }

    private func withProfiler<Result>(for generation: UUID, requireAudio: Bool = false,
                                      _ operation: (EagleProfilerProtocol) throws -> Result) rethrows -> Result? {
        profilerLock.lock()
        defer { profilerLock.unlock() }
        guard isCurrentEnrollment(generation, requireAudio: requireAudio), let profiler else { return nil }
        return try operation(profiler)
    }

    private func isCurrentEnrollment(_ generation: UUID, requireActive: Bool = true, requireAudio: Bool = false) -> Bool {
        enrollmentLock.lock()
        defer { enrollmentLock.unlock() }
        return (!requireActive || isEnrollingFlag) && (!requireAudio || !isExporting) && enrollmentGeneration == generation
    }

    private func isEnrollingActive() -> Bool {
        enrollmentLock.lock()
        let active = isEnrollingFlag
        enrollmentLock.unlock()
        return active
    }

    private func updateState(_ newState: EnrollmentState, generation: UUID) {
        DispatchQueue.main.async {
            guard self.isCurrentEnrollment(generation, requireActive: false) else { return }
            self.state = newState
        }
    }

    private func updateFeedback(_ newFeedback: EnrollmentFeedback, generation: UUID) {
        DispatchQueue.main.async {
            guard self.isCurrentEnrollment(generation) else { return }
            self.feedback = newFeedback
        }
    }

    private func calculateAudioLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let floatData = buffer.floatChannelData else { return 0 }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        var sum: Float = 0
        let samples = floatData[0]

        for i in 0..<frameLength {
            let sample = samples[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))
        // Convert to 0-1 range (assuming max RMS around 0.5)
        return min(rms * 2.0, 1.0)
    }
}

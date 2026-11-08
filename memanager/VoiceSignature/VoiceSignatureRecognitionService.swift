import AVFoundation
import Combine
import Foundation

/// Runs Eagle on audio stream, emits scores and speaker labels
final class VoiceSignatureRecognitionService: ObservableObject {

    // MARK: - Published State

    @Published var isActive: Bool = false
    @Published var currentLabel: SpeakerLabel = .unknown
    @Published var currentScore: Float = 0.0
    @Published var smoothedScore: Float = 0.0

    // MARK: - Configuration

    var config: SpeakerRecognitionConfig {
        didSet { resetStateMachine() }
    }

    // MARK: - Dependencies

    let store: VoiceSignatureStore
    var engine: EagleEngineProtocol?

    // MARK: - Per-Source Framers

    var micFramer: PCM16ResamplerAndFramer?
    var systemFramer: PCM16ResamplerAndFramer?

    // MARK: - Score Timeline (Ring Buffer)

    var scoreTimeline: [SpeakerScoreSample] = []
    let maxTimelineLength = 6000  // Keep ~60 seconds at typical frame rate
    let timelineLock = NSLock()

    // MARK: - State Machine

    var consecutiveAboveThreshold: Int = 0
    var consecutiveBelowThreshold: Int = 0
    var emaScore: Float = 0.0
    var hasInitializedEMA: Bool = false
    let stateLock = NSLock()
    let engineLock = NSLock()
    var isActiveFlag: Bool = false
    var hasReportedProcessingError = false
    var currentLabelState: SpeakerLabel = .unknown

    // MARK: - Threading

    let micProcessingQueue = DispatchQueue(
        label: "VoiceSignatureRecognition.Mic",
        qos: .userInitiated
    )

    let systemProcessingQueue = DispatchQueue(
        label: "VoiceSignatureRecognition.System",
        qos: .userInitiated
    )

    let queueDepthLock = NSLock()
    let maxPendingBuffersPerSource = 32
    var pendingMicBuffers = 0
    var pendingSystemBuffers = 0
    var droppedMicBuffers = 0
    var droppedSystemBuffers = 0

    // MARK: - Callbacks

    /// Called for each new score sample (for diagnostics/UI)
    var onScoreSample: ((SpeakerScoreSample) -> Void)?

    /// Called when speaker label changes
    var onLabelChanged: ((SpeakerLabel) -> Void)?

    /// One failure per recognition run. Consumers choose how to present or stop it.
    var onProcessingError: ((Error) -> Void)?

    // MARK: - Initialization

    init(store: VoiceSignatureStore = .shared, config: SpeakerRecognitionConfig = .default) {
        self.store = store
        self.config = config

        // Pre-allocate timeline capacity
        scoreTimeline.reserveCapacity(maxTimelineLength)
    }

    // MARK: - Public Interface

    /// Start recognition with the stored profile
    func start() throws {
        guard !isActive else { return }

        guard let accessKey = store.loadAccessKey(), !accessKey.isEmpty else {
            throw EagleError.invalidAccessKey
        }

        guard let profileData = store.loadProfile() else {
            throw EagleError.invalidState
        }

        let modelPath = store.modelPath
        guard !modelPath.isEmpty else {
            throw EagleError.modelLoadFailed("Model path is empty")
        }

        let newEngine = try EagleBindings.createEngine(
            accessKey: accessKey,
            modelPath: modelPath,
            profile: profileData
        )
        engine = newEngine

        // Initialize framers for each source
        micFramer = PCM16ResamplerAndFramer(source: .microphone, frameSize: newEngine.minimumAudioSamples)
        systemFramer = PCM16ResamplerAndFramer(source: .systemAudio, frameSize: newEngine.minimumAudioSamples)

        setupFramerCallbacks()
        resetStateMachine()
        clearTimeline()
        setActiveFlag(true)

        DispatchQueue.main.async {
            self.isActive = true
        }
    }

    /// Stop recognition and release resources
    func stop() {
        setActiveFlag(false)
        engineLock.lock()
        engine?.destroy()
        engine = nil
        engineLock.unlock()
        micFramer = nil
        systemFramer = nil

        DispatchQueue.main.async {
            self.isActive = false
            self.currentLabel = .unknown
            self.currentScore = 0.0
            self.smoothedScore = 0.0
        }

        clearTimeline()
    }

    /// Pause recognition (keeps engine and state, stops processing)
    func pause() {
        // Just mark as inactive - audio processing will be skipped in processMicAudio/processSystemAudio
        // Engine and framers are preserved for quick resume
        setActiveFlag(false)
        DispatchQueue.main.async {
            self.isActive = false
        }
    }

    /// Resume recognition after pause
    func resume() {
        guard engine != nil else { return }
        setActiveFlag(true)
        DispatchQueue.main.async {
            self.isActive = true
        }
    }

    /// Reset for a new session (keeps engine loaded)
    func reset() {
        engineLock.lock()
        try? engine?.reset()
        engineLock.unlock()
        micFramer?.reset()
        systemFramer?.reset()
        resetStateMachine()
        clearTimeline()
        stateLock.withLock { currentLabelState = .unknown }

        DispatchQueue.main.async {
            self.currentLabel = .unknown
            self.currentScore = 0.0
            self.smoothedScore = 0.0
        }
    }

    /// Process audio from microphone
    func processMicAudio(buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard isProcessingActive() else { return }
        guard beginEnqueue(for: .microphone) else { return }
        micProcessingQueue.async { [weak self] in
            defer { self?.finishEnqueue(for: .microphone) }
            self?.micFramer?.process(buffer: buffer, hostTime: hostTime)
        }
    }

    /// Process audio from system audio
    func processSystemAudio(buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard isProcessingActive() else { return }
        guard beginEnqueue(for: .systemAudio) else { return }
        systemProcessingQueue.async { [weak self] in
            defer { self?.finishEnqueue(for: .systemAudio) }
            self?.systemFramer?.process(buffer: buffer, hostTime: hostTime)
        }
    }

    /// Query scores overlapping a time range (for transcript alignment)
    func averageScore(from startTime: TimeInterval, to endTime: TimeInterval) -> Float? {
        timelineLock.lock()
        defer { timelineLock.unlock() }

        let overlapping = scoreTimeline.filter { sample in
            sample.timestamp >= startTime && sample.timestamp <= endTime
        }

        guard !overlapping.isEmpty else { return nil }

        let sum = overlapping.reduce(Float(0)) { $0 + $1.score }
        return sum / Float(overlapping.count)
    }

    /// Get recent average score (for partial transcript labeling)
    func recentAverageScore(windowSeconds: TimeInterval = 1.0) -> Float? {
        timelineLock.lock()
        defer { timelineLock.unlock() }

        guard let lastSample = scoreTimeline.last else { return nil }

        let cutoff = lastSample.timestamp - windowSeconds
        let recent = scoreTimeline.filter { $0.timestamp >= cutoff }

        guard !recent.isEmpty else { return nil }

        let sum = recent.reduce(Float(0)) { $0 + $1.score }
        return sum / Float(recent.count)
    }

    func latestTimestamp(for source: AudioSource) -> TimeInterval? {
        timelineLock.lock()
        defer { timelineLock.unlock() }
        return scoreTimeline.last(where: { $0.source == source })?.timestamp
    }

    // MARK: - Private Methods

    func setupFramerCallbacks() {
        micFramer?.onFrameReady = { [weak self] frame, timestamp in
            self?.processFrame(frame, timestamp: timestamp, source: .microphone)
        }

        systemFramer?.onFrameReady = { [weak self] frame, timestamp in
            self?.processFrame(frame, timestamp: timestamp, source: .systemAudio)
        }
    }

}


#if DEBUG
extension VoiceSignatureRecognitionService {
    func testActivate(with engine: EagleEngineProtocol) {
        engineLock.lock()
        self.engine = engine
        engineLock.unlock()
        resetStateMachine()
        clearTimeline()
        setActiveFlag(true)
        isActive = true
    }

    func testInjectFrame(_ frame: [Int16], timestamp: TimeInterval, source: AudioSource) {
        processFrame(frame, timestamp: timestamp, source: source)
    }

    func testAppendSample(_ sample: SpeakerScoreSample) {
        appendToTimeline(sample)
    }

    var testDroppedBufferCounts: (mic: Int, system: Int) {
        queueDepthLock.lock()
        defer { queueDepthLock.unlock() }
        return (droppedMicBuffers, droppedSystemBuffers)
    }
}
#endif

import AVFoundation
import Combine
import CoreMedia
import Foundation

// MARK: - Dual Stream Deepgram Service

/// Manages two independent Deepgram WebSocket connections for source-based speaker identification.
///
/// Architecture:
/// - **Mic stream**: Transcribes microphone audio, always labeled as "me" (diarize=false)
/// - **System stream**: Transcribes system audio with diarization for multiple speakers
///
/// This approach provides deterministic speaker identification based on audio source
/// rather than acoustic analysis, eliminating the need for voice biometrics.
final class DualStreamDeepgramService: ObservableObject {

    // MARK: - Published State

    @Published var micConnectionState: DeepgramConnectionState = .disconnected
    @Published var systemConnectionState: DeepgramConnectionState = .disconnected

    /// Combined connection state for UI binding
    var isFullyConnected: Bool {
        micConnectionState.isConnected && systemConnectionState.isConnected
    }

    // MARK: - Callbacks

    /// Called when microphone transcript is received (always "me")
    var onMicTranscript: ((DeepgramTranscriptSegment) -> Void)?

    /// Called when system audio transcript is received (with diarization)
    var onSystemTranscript: ((DeepgramTranscriptSegment) -> Void)?

    /// Called when either connection state changes
    var onConnectionStateChanged: ((DualStreamConnectionState) -> Void)?

    // MARK: - Private Properties

    var apiKey: String?

    // Separate WebSocket tasks for each stream
    var micWebSocket: URLSessionWebSocketTask?
    var systemWebSocket: URLSessionWebSocketTask?

    var urlSession: URLSession?
    let socketFactory: ((URLRequest) -> URLSessionWebSocketTask?)?

    // Separate keep-alive timers
    var micKeepAliveTimer: Timer?
    var systemKeepAliveTimer: Timer?
    var lastSpeakerBySource: [AudioSource: Int] = [:]
    var micReady = false
    var systemReady = false
    var connectionEpochs: [AudioSource: UInt64] = [:]

    var pendingMicAudioData: [Data] = []
    var pendingSystemAudioData: [Data] = []
    let pendingAudioLock = NSLock()
    let maxPendingChunks = 100

    let stateLock = NSLock()
    var micMetrics = DualStreamMetrics()
    var systemMetrics = DualStreamMetrics()

    // MARK: - Initialization

    init(socketFactory: ((URLRequest) -> URLSessionWebSocketTask?)? = nil) {
        self.socketFactory = socketFactory
        setupURLSession()
    }

    func makeWebSocket(for request: URLRequest) -> URLSessionWebSocketTask? {
        if let socketFactory { return socketFactory(request) }
        return urlSession?.webSocketTask(with: request)
    }

    deinit {
        disconnect()
        urlSession?.invalidateAndCancel()
    }

    func setupURLSession() {
        let config = TestRuntime.isRunningUnitTests ? URLSessionConfiguration.ephemeral : .default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        urlSession = URLSession(configuration: config)
    }

    // MARK: - Public Interface

    /// Connect both streams to Deepgram
    func connect(apiKey: String) {
        stateLock.lock()
        self.apiKey = apiKey
        lastSpeakerBySource = [:]
        micReady = false
        systemReady = false
        micMetrics = DualStreamMetrics()
        systemMetrics = DualStreamMetrics()
        stateLock.unlock()

        pendingAudioLock.lock()
        pendingMicAudioData.removeAll()
        pendingSystemAudioData.removeAll()
        pendingAudioLock.unlock()

        connectMicStream()
        connectSystemStream()
    }

    /// Disconnect both streams
    func disconnect() {
        // Clear callbacks first to prevent any callbacks firing during teardown
        stateLock.lock()
        onMicTranscript = nil
        onSystemTranscript = nil
        onConnectionStateChanged = nil
        stateLock.unlock()

        disconnectMicStream()
        disconnectSystemStream()

        stateLock.lock()
        apiKey = nil
        micReady = false
        systemReady = false
        micMetrics = DualStreamMetrics()
        systemMetrics = DualStreamMetrics()
        stateLock.unlock()

        pendingAudioLock.lock()
        pendingMicAudioData.removeAll()
        pendingSystemAudioData.removeAll()
        pendingAudioLock.unlock()
    }

    /// Send microphone audio data (always labeled as "me")
    ///
    /// Expected format: PCM16 (Int16), 48kHz, mono
    func sendMicAudio(_ data: Data) {
        let socket = stateLock.withLock { micWebSocket }
        guard let socket = socket else {
            enqueuePendingAudio(data, source: .microphone)
            return
        }

        guard isReady(.microphone) else {
            enqueuePendingAudio(data, source: .microphone)
            return
        }

        let message = URLSessionWebSocketTask.Message.data(data)
        socket.send(message) { [weak self] error in
            guard let self, self.isCurrentSocket(socket, source: .microphone) else { return }
            if let error = error {
                if DeepgramStreamCore.isCancellation(error) { return }
                self.logDebug("[Mic] Send error: \(DeepgramStreamCore.errorSummary(error))")
                self.updateMetricError(source: .microphone, message: DeepgramStreamCore.errorSummary(error))
                return
            }
            self.incrementSentChunks(source: .microphone)
            self.markReadyIfNeeded(.microphone)
        }
    }

    /// Send system audio data (uses diarization for speaker identification)
    ///
    /// Expected format: PCM16 (Int16), 48kHz, mono
    func sendSystemAudio(_ data: Data) {
        let socket = stateLock.withLock { systemWebSocket }
        guard let socket = socket else {
            enqueuePendingAudio(data, source: .systemAudio)
            return
        }

        guard isReady(.systemAudio) else {
            enqueuePendingAudio(data, source: .systemAudio)
            return
        }

        let message = URLSessionWebSocketTask.Message.data(data)
        socket.send(message) { [weak self] error in
            guard let self, self.isCurrentSocket(socket, source: .systemAudio) else { return }
            if let error = error {
                if DeepgramStreamCore.isCancellation(error) { return }
                self.logDebug("[System] Send error: \(DeepgramStreamCore.errorSummary(error))")
                self.updateMetricError(source: .systemAudio, message: DeepgramStreamCore.errorSummary(error))
                return
            }
            self.incrementSentChunks(source: .systemAudio)
            self.markReadyIfNeeded(.systemAudio)
        }
    }

    func reconnectSystemStream() {
        let hasAPIKey = stateLock.withLock { apiKey?.isEmpty == false }
        guard hasAPIKey else {
            logDebug("[System] Reconnect skipped: no API key")
            return
        }
        logDebug("[System] Reconnecting stream")
        disconnectSystemStream()
        connectSystemStream()
    }

    var metricsSnapshot: DualStreamMetricsSnapshot {
        stateLock.withLock {
            DualStreamMetricsSnapshot(mic: micMetrics, system: systemMetrics)
        }
    }

    #if DEBUG
    func testInjectReceivedFrame(_ jsonString: String, source: AudioSource) {
        incrementInboundMessages(source: source)
        parseAndEmitResponse(jsonString, source: source)
    }

    func testInjectSendSuccess(source: AudioSource) {
        incrementSentChunks(source: source)
    }
    #endif

    func isReady(_ source: AudioSource) -> Bool {
        stateLock.lock()
        let ready = source == .microphone ? micReady : systemReady
        stateLock.unlock()
        return ready
    }

    func markReadyIfNeeded(_ source: AudioSource) {
        let shouldUpdate: Bool = stateLock.withLock {
            switch source {
            case .microphone:
                guard !micReady else { return false }
                micReady = true
                return true
            case .systemAudio:
                guard !systemReady else { return false }
                systemReady = true
                return true
            }
        }

        guard shouldUpdate else { return }

        switch source {
        case .microphone:
            updateMicState(.connected)
        case .systemAudio:
            updateSystemState(.connected)
        }

        flushPendingAudio(for: source)
    }

    func enqueuePendingAudio(_ data: Data, source: AudioSource) {
        pendingAudioLock.lock()
        switch source {
        case .microphone:
            if pendingMicAudioData.count < maxPendingChunks {
                pendingMicAudioData.append(data)
            }
        case .systemAudio:
            if pendingSystemAudioData.count < maxPendingChunks {
                pendingSystemAudioData.append(data)
            }
        }
        pendingAudioLock.unlock()
    }

    func flushPendingAudio(for source: AudioSource) {
        let socket = stateLock.withLock {
            source == .microphone ? micWebSocket : systemWebSocket
        }
        guard let socket else { return }

        pendingAudioLock.lock()
        let pending: [Data]
        switch source {
        case .microphone:
            pending = pendingMicAudioData
            pendingMicAudioData.removeAll()
        case .systemAudio:
            pending = pendingSystemAudioData
            pendingSystemAudioData.removeAll()
        }
        pendingAudioLock.unlock()

        guard !pending.isEmpty else { return }

        for data in pending {
            let message = URLSessionWebSocketTask.Message.data(data)
            socket.send(message) { _ in }
        }
    }

}

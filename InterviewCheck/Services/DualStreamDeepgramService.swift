import AVFoundation
import Combine
import CoreMedia
import Foundation
import InterviewCheckKit

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

    /// Called with every final result's words mapped onto the host clock
    /// (`ProcessInfo.systemUptime`), for timing analysis.
    var onFinalTimedWords: ((DeepgramTimedWords) -> Void)?

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

    var pendingMicAudioData: [PendingAudioChunk] = []
    var pendingSystemAudioData: [PendingAudioChunk] = []

    /// Map each connection's Deepgram offsets back to host time.
    let micClock = StreamClock()
    let systemClock = StreamClock()
    /// Host clock; replaceable in tests.
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    let pendingAudioLock = NSLock()
    let maxPendingChunks = 100

    let stateLock = NSLock()
    /// Serializes every audio write with the ready flush. Recursive, so a
    /// send completion that runs at once on this thread cannot deadlock.
    let sendLock = NSRecursiveLock()
    /// Writes one message to a socket; tests replace it to see the order.
    var transmit: (URLSessionWebSocketTask, URLSessionWebSocketTask.Message, @escaping (Error?) -> Void) -> Void = {
        socket, message, completion in socket.send(message, completionHandler: completion)
    }
    /// The pending wait of `finalize`, touched on the main queue only.
    var finalizeWaiter: FinalizeWaiter?
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
        urlSession = URLSession(configuration: DeepgramSessionConfiguration.make())
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
        onFinalTimedWords = nil
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
        sendAudio(data, source: .microphone)
    }

    /// Send system audio data (uses diarization for speaker identification)
    ///
    /// Expected format: PCM16 (Int16), 48kHz, mono
    func sendSystemAudio(_ data: Data) {
        sendAudio(data, source: .systemAudio)
    }

    /// Queues or sends one chunk. Deciding and sending happen under
    /// `sendLock`, the lock the ready flush holds, so live audio can never
    /// reach the socket ahead of audio queued before the stream was ready.
    func sendAudio(_ data: Data, source: AudioSource) {
        let streamClock = clock(for: source)
        let chunk = PendingAudioChunk(data: data, capturedAt: streamClock.captureStart(
            ofBytes: data.count, arrivedAt: uptime()))
        sendLock.lock()
        defer { sendLock.unlock() }
        let socket = stateLock.withLock { source == .microphone ? micWebSocket : systemWebSocket }
        guard let socket, isReady(source) else {
            enqueuePendingAudio(chunk, source: source)
            return
        }

        streamClock.recordSent(byteCount: data.count, capturedAt: chunk.capturedAt)
        transmit(socket, .data(data)) { [weak self] error in
            guard let self, self.isCurrentSocket(socket, source: source) else { return }
            if let error = error {
                if DeepgramStreamCore.isCancellation(error) { return }
                self.logDebug("[\(source.displayName)] Send error: \(DeepgramStreamCore.errorSummary(error))")
                self.updateMetricError(source: source, message: DeepgramStreamCore.errorSummary(error))
                return
            }
            self.incrementSentChunks(source: source)
            self.markReadyIfNeeded(source)
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
        // Ready and flushed in one step, shared with `sendAudio`.
        sendLock.lock()
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
        if shouldUpdate { flushPendingAudio(for: source) }
        sendLock.unlock()

        guard shouldUpdate else { return }

        switch source {
        case .microphone:
            updateMicState(.connected)
        case .systemAudio:
            updateSystemState(.connected)
        }
    }

    func clock(for source: AudioSource) -> StreamClock {
        source == .microphone ? micClock : systemClock
    }

    func enqueuePendingAudio(_ data: PendingAudioChunk, source: AudioSource) {
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

    /// Sends the queued audio in order; callers hold `sendLock`.
    func flushPendingAudio(for source: AudioSource) {
        let socket = stateLock.withLock {
            source == .microphone ? micWebSocket : systemWebSocket
        }
        guard let socket else { return }

        pendingAudioLock.lock()
        let pending: [PendingAudioChunk]
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

        let streamClock = clock(for: source)
        for chunk in pending {
            streamClock.recordSent(byteCount: chunk.data.count, capturedAt: chunk.capturedAt)
            transmit(socket, .data(chunk.data)) { _ in }
        }
    }

}

/// Audio waiting for its socket, stamped with when it was captured.
struct PendingAudioChunk {
    let data: Data
    let capturedAt: TimeInterval
}

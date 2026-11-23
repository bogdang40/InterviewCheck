import AVFoundation
import Combine
import CoreMedia
import Foundation

// MARK: - Deepgram Service

/// Manages a single WebSocket connection to Deepgram for real-time transcription with diarization.
///
/// Designed for unified audio streams where mic + system audio are mixed before sending.
/// Deepgram's diarization handles all speaker identification acoustically.
final class DeepgramService: ObservableObject {

    // MARK: - Published State

    @Published var connectionState: DeepgramConnectionState = .disconnected
    @Published var currentSpeaker: Int?

    // MARK: - Callbacks

    /// Called when a transcript segment is received (partial or final)
    var onTranscriptReceived: ((DeepgramTranscriptSegment) -> Void)?

    /// Called when connection state changes
    var onConnectionStateChanged: ((DeepgramConnectionState) -> Void)?

    // MARK: - Private Properties

    var apiKey: String?
    var webSocket: URLSessionWebSocketTask?
    var urlSession: URLSession?
    var keepAliveTimer: Timer?
    var lastSpeakerId: Int?
    var connectionEpoch: UInt64 = 0

    let stateLock = NSLock()

    // Audio buffering for connection race condition
    var pendingAudioData: [Data] = []
    let pendingAudioLock = NSLock()

    // MARK: - Debug Mode (NDJSON)
    let ndjsonRunId = "run1"
    var ndjsonInboundMessageCount: Int = 0
    var ndjsonLastInboundLogTime: TimeInterval = 0

    // MARK: - Initialization

    init() {
        setupURLSession()
    }

    deinit {
        disconnect(notify: false)
        urlSession?.invalidateAndCancel()
    }

    func setupURLSession() {
        urlSession = URLSession(configuration: DeepgramSessionConfiguration.make())
    }

    // MARK: - Public Interface

    /// Connect to Deepgram with the given API key
    func connect(apiKey: String) {
        stateLock.lock()
        self.apiKey = apiKey
        stateLock.unlock()

        connectWebSocket()
    }

    /// Disconnect from Deepgram
    func disconnect(notify: Bool = true) {
        let (timer, socket): (Timer?, URLSessionWebSocketTask?) = stateLock.withLock {
            let timer = keepAliveTimer
            let socket = webSocket
            keepAliveTimer = nil
            webSocket = nil
            apiKey = nil
            connectionEpoch &+= 1
            lastSpeakerId = nil
            return (timer, socket)
        }

        timer?.invalidate()
        socket?.cancel(with: .normalClosure, reason: nil)
        // Clear any buffered audio
        pendingAudioLock.lock()
        pendingAudioData.removeAll()
        pendingAudioLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.currentSpeaker = nil
        }

        if notify {
            updateState(.disconnected)
        }
        logDebug("WebSocket disconnected")
    }

    /// Send unified audio data to Deepgram
    ///
    /// Expected format: PCM16 (Int16), 48kHz, mono
    /// Buffers audio if WebSocket is not yet ready, flushes when connection established.
    func sendAudio(_ data: Data) {
        let socket = stateLock.withLock { webSocket }

        // If socket not ready, buffer the audio to avoid losing it
        guard let socket = socket else {
            pendingAudioLock.lock()
            // Limit buffer to ~2 seconds of audio (100 chunks at ~20ms each)
            if pendingAudioData.count < 100 {
                pendingAudioData.append(data)
            }
            pendingAudioLock.unlock()
            return
        }

        // Flush any buffered audio first
        flushPendingAudio(to: socket)

        // Send current chunk
        let message = URLSessionWebSocketTask.Message.data(data)
        socket.send(message) { [weak self] error in
            if let error = error {
                guard let self = self else { return }
                if DeepgramStreamCore.isCancellation(error) { return }
                self.logDebug("Send error: \(DeepgramStreamCore.errorSummary(error))")
            }
        }
    }

    /// Flush any buffered audio data to the socket
    func flushPendingAudio(to socket: URLSessionWebSocketTask) {
        pendingAudioLock.lock()
        let pending = pendingAudioData
        pendingAudioData.removeAll()
        pendingAudioLock.unlock()

        guard !pending.isEmpty else { return }

        logDebug("Flushing \(pending.count) buffered audio chunks")

        for data in pending {
            let message = URLSessionWebSocketTask.Message.data(data)
            socket.send(message) { _ in }
        }
    }

    // MARK: - WebSocket Connection

    func connectWebSocket() {
        let key = stateLock.withLock { apiKey }
        guard let apiKey = key, !apiKey.isEmpty else {
            logDebug("Cannot connect: no API key")
            updateState(.error("No API key"))
            return
        }

        guard stateLock.withLock({ webSocket == nil }) else {
            logDebug("Already connected or connecting")
            return
        }

        updateState(.connecting)

        // Unified stream: diarize=true, utterances=true
        guard let url = DeepgramStreamCore.buildWebSocketURL(diarize: true, utterances: true) else {
            updateState(.error("Invalid URL"))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let socket = urlSession?.webSocketTask(with: request)
        stateLock.withLock { webSocket = socket }
        socket?.resume()

        stateLock.withLock { lastSpeakerId = nil }
        startReceiving(socket: socket)
        startKeepAlive()

        updateState(.connected)
        logDebug("WebSocket connected - unified stream ready")
    }

    // MARK: - Keep-Alive

    func startKeepAlive() {
        let timer = Timer.scheduledTimer(
            withTimeInterval: DeepgramStreamCore.Config.keepAliveInterval,
            repeats: true
        ) { [weak self] _ in
            self?.sendKeepAlive()
        }

        stateLock.withLock {
            keepAliveTimer = timer
        }
    }

    func sendKeepAlive() {
        let socket = stateLock.withLock { webSocket }

        // Legacy stream keeps the default no-op onSuccess hook
        DeepgramStreamCore.sendKeepAlive(over: socket) { [weak self] summary in
            self?.logDebug("Keep-alive error: \(summary)")
        }
    }

    // MARK: - Disconnection Handling

    func handleDisconnection(
        error: Error,
        summary: String? = nil,
        expectedSocket: URLSessionWebSocketTask? = nil
    ) {
        let detached: (Timer?, URLSessionWebSocketTask?)? = stateLock.withLock {
            if let expectedSocket, webSocket !== expectedSocket { return nil }
            let timer = keepAliveTimer
            let socket = webSocket
            keepAliveTimer = nil
            webSocket = nil
            connectionEpoch &+= 1
            lastSpeakerId = nil
            return (timer, socket)
        }
        guard let (timer, socket) = detached else { return }
        timer?.invalidate()
        socket?.cancel(with: .normalClosure, reason: nil)
        updateState(.error(summary ?? DeepgramStreamCore.errorSummary(error)))
    }

    // MARK: - State Updates

    func updateState(_ state: DeepgramConnectionState) {
        let epoch = stateLock.withLock { connectionEpoch }
        let stateLabel: String
        let stateError: String
        switch state {
        case .disconnected:
            stateLabel = "disconnected"
            stateError = ""
        case .connecting:
            stateLabel = "connecting"
            stateError = ""
        case .connected:
            stateLabel = "connected"
            stateError = ""
        case .error(let message):
            stateLabel = "error"
            stateError = message
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.stateLock.withLock({ self.connectionEpoch == epoch }) else { return }
            self.connectionState = state
            self.onConnectionStateChanged?(state)

            // #region agent log
            DebugNDJSONLogger.shared.log(
                runId: "run1",
                hypothesisId: "H2",
                location: "DeepgramService.updateState",
                message: "deepgram_state_changed",
                data: [
                    "state": stateLabel,
                    "error": stateError
                ]
            )
            // #endregion
        }
    }

    // MARK: - Debug Logging

    func logDebug(_ message: String) {
        #if DEBUG
        print("[Deepgram] \(message)")
        #endif
    }
}

// MARK: - Convenience Extension

extension DeepgramService {
    /// Check if connected
    var isConnected: Bool {
        connectionState.isConnected
    }
}

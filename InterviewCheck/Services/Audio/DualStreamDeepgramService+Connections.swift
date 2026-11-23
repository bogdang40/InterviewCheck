import AVFoundation
import Combine
import CoreMedia
import Foundation

extension DualStreamDeepgramService {
    // MARK: - Mic Stream Connection

    func connectMicStream() {
        let key = stateLock.withLock { apiKey }
        guard let apiKey = key, !apiKey.isEmpty else {
            logDebug("[Mic] Cannot connect: no API key")
            updateMicState(.error("No API key"))
            return
        }

        guard stateLock.withLock({ micWebSocket == nil }) else {
            logDebug("[Mic] Already connected or connecting")
            return
        }

        updateMicState(.connecting)

        // Mic stream: diarize=false (single speaker, always "me")
        guard let url = DeepgramStreamCore.buildWebSocketURL(diarize: false, utterances: false) else {
            updateMicState(.error("Invalid URL"))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let socket = makeWebSocket(for: request)
        // Deepgram's word offsets restart at zero on every new socket.
        clock(for: .microphone).reset()
        stateLock.withLock { micWebSocket = socket }
        socket?.resume()

        startReceiving(socket: socket, source: .microphone)
        startKeepAlive(for: .microphone)
        logDebug("[Mic] WebSocket connecting - single speaker mode")
    }

    func disconnectMicStream() {
        let (timer, socket): (Timer?, URLSessionWebSocketTask?) = stateLock.withLock {
            let timer = micKeepAliveTimer
            let socket = micWebSocket
            micKeepAliveTimer = nil
            micWebSocket = nil
            micReady = false
            connectionEpochs[.microphone, default: 0] &+= 1
            lastSpeakerBySource.removeValue(forKey: .microphone)
            return (timer, socket)
        }

        timer?.invalidate()
        socket?.cancel(with: .normalClosure, reason: nil)

        updateMicState(.disconnected)
        logDebug("[Mic] WebSocket disconnected")
    }

    // MARK: - System Stream Connection

    func connectSystemStream() {
        let key = stateLock.withLock { apiKey }
        guard let apiKey = key, !apiKey.isEmpty else {
            logDebug("[System] Cannot connect: no API key")
            updateSystemState(.error("No API key"))
            return
        }

        guard stateLock.withLock({ systemWebSocket == nil }) else {
            logDebug("[System] Already connected or connecting")
            return
        }

        updateSystemState(.connecting)

        // System stream: diarize=true (multiple speakers)
        guard let url = DeepgramStreamCore.buildWebSocketURL(diarize: true, utterances: false) else {
            updateSystemState(.error("Invalid URL"))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let socket = makeWebSocket(for: request)
        // Deepgram's word offsets restart at zero on every new socket.
        clock(for: .systemAudio).reset()
        stateLock.withLock { systemWebSocket = socket }
        socket?.resume()

        startReceiving(socket: socket, source: .systemAudio)
        startKeepAlive(for: .systemAudio)
        logDebug("[System] WebSocket connecting - diarization enabled")
    }

    func disconnectSystemStream() {
        let (timer, socket): (Timer?, URLSessionWebSocketTask?) = stateLock.withLock {
            let timer = systemKeepAliveTimer
            let socket = systemWebSocket
            systemKeepAliveTimer = nil
            systemWebSocket = nil
            systemReady = false
            connectionEpochs[.systemAudio, default: 0] &+= 1
            lastSpeakerBySource.removeValue(forKey: .systemAudio)
            return (timer, socket)
        }

        timer?.invalidate()
        socket?.cancel(with: .normalClosure, reason: nil)

        updateSystemState(.disconnected)
        logDebug("[System] WebSocket disconnected")
    }

    // MARK: - Receiving Messages

    // MARK: - Keep-Alive

    func startKeepAlive(for source: AudioSource) {
        let timer = Timer.scheduledTimer(
            withTimeInterval: DeepgramStreamCore.Config.keepAliveInterval,
            repeats: true
        ) { [weak self] _ in
            self?.sendKeepAlive(for: source)
        }

        stateLock.withLock {
            switch source {
            case .microphone:
                micKeepAliveTimer = timer
            case .systemAudio:
                systemKeepAliveTimer = timer
            }
        }

        sendKeepAlive(for: source)
    }

    func sendKeepAlive(for source: AudioSource) {
        let socket = stateLock.withLock {
            source == .microphone ? micWebSocket : systemWebSocket
        }

        // Dual stream marks the source ready on a successful keep-alive send
        DeepgramStreamCore.sendKeepAlive(
            over: socket,
            onError: { [weak self] summary in
                self?.logDebug("[\(source.displayName)] Keep-alive error: \(summary)")
            },
            onSuccess: { [weak self] in
                guard let self, let socket, self.isCurrentSocket(socket, source: source) else { return }
                self.markReadyIfNeeded(source)
            }
        )
    }

    // MARK: - Disconnection Handling

    func handleDisconnection(
        source: AudioSource,
        error: Error,
        summary: String? = nil,
        expectedSocket: URLSessionWebSocketTask? = nil
    ) {
        handleErrorMessage(
            source: source,
            message: summary ?? DeepgramStreamCore.errorSummary(error),
            expectedSocket: expectedSocket
        )
    }

    func handleErrorMessage(
        source: AudioSource,
        message: String,
        expectedSocket: URLSessionWebSocketTask? = nil
    ) {
        let detached: (Timer?, URLSessionWebSocketTask?)? = stateLock.withLock {
            let current = source == .microphone ? micWebSocket : systemWebSocket
            if let expectedSocket, current !== expectedSocket { return nil }
            connectionEpochs[source, default: 0] &+= 1
            lastSpeakerBySource.removeValue(forKey: source)
            switch source {
            case .microphone:
                let timer = micKeepAliveTimer
                micKeepAliveTimer = nil
                micWebSocket = nil
                micReady = false
                micMetrics.lastError = message
                return (timer, current)
            case .systemAudio:
                let timer = systemKeepAliveTimer
                systemKeepAliveTimer = nil
                systemWebSocket = nil
                systemReady = false
                systemMetrics.lastError = message
                return (timer, current)
            }
        }
        guard let (timer, socket) = detached else { return }
        timer?.invalidate()
        socket?.cancel(with: .normalClosure, reason: nil)
        // A stream that ended has nothing more to finalize.
        DispatchQueue.main.async { [weak self] in self?.resolveFinalize(source) }
        switch source {
        case .microphone: updateMicState(.error(message))
        case .systemAudio: updateSystemState(.error(message))
        }
    }

    func isCurrentSocket(_ socket: URLSessionWebSocketTask, source: AudioSource) -> Bool {
        stateLock.withLock {
            (source == .microphone ? micWebSocket : systemWebSocket) === socket
        }
    }

    func connectionEpoch(for source: AudioSource) -> UInt64 {
        stateLock.withLock { connectionEpochs[source, default: 0] }
    }
}

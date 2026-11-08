import AVFoundation
import Combine
import CoreMedia
import Foundation

extension DualStreamDeepgramService {
    func updateMicState(_ state: DeepgramConnectionState) {
        let epoch = connectionEpoch(for: .microphone)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionEpoch(for: .microphone) == epoch else { return }
            self.micConnectionState = state
            self.notifyConnectionStateChange()
        }
    }

    func updateSystemState(_ state: DeepgramConnectionState) {
        let epoch = connectionEpoch(for: .systemAudio)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionEpoch(for: .systemAudio) == epoch else { return }
            self.systemConnectionState = state
            self.notifyConnectionStateChange()
        }
    }

    func notifyConnectionStateChange() {
        let combined = DualStreamConnectionState(
            mic: micConnectionState,
            system: systemConnectionState
        )

        // Capture callback reference for thread safety
        stateLock.lock()
        let callback = onConnectionStateChanged
        stateLock.unlock()

        callback?(combined)

        let micLabel: String
        let micError: String
        switch micConnectionState {
        case .disconnected:
            micLabel = "disconnected"
            micError = ""
        case .connecting:
            micLabel = "connecting"
            micError = ""
        case .connected:
            micLabel = "connected"
            micError = ""
        case .error(let message):
            micLabel = "error"
            micError = message
        }

        let systemLabel: String
        let systemError: String
        switch systemConnectionState {
        case .disconnected:
            systemLabel = "disconnected"
            systemError = ""
        case .connecting:
            systemLabel = "connecting"
            systemError = ""
        case .connected:
            systemLabel = "connected"
            systemError = ""
        case .error(let message):
            systemLabel = "error"
            systemError = message
        }

        // #region agent log
        DebugNDJSONLogger.shared.log(
            runId: "run1",
            hypothesisId: "H2",
            location: "DualStreamDeepgramService.notifyConnectionStateChange",
            message: "dual_deepgram_state_changed",
            data: [
                "mic": micLabel,
                "micError": micError,
                "system": systemLabel,
                "systemError": systemError
            ]
        )
        // #endregion
    }

    // MARK: - Debug Logging

    func logDebug(_ message: String) {
        #if DEBUG
        print("[DualDeepgram] \(message)")
        #endif
    }

    func incrementSentChunks(source: AudioSource) {
        stateLock.withLock {
            switch source {
            case .microphone:
                micMetrics.sentChunkCount += 1
            case .systemAudio:
                systemMetrics.sentChunkCount += 1
            }
        }
    }

    func incrementInboundMessages(source: AudioSource) {
        stateLock.withLock {
            switch source {
            case .microphone:
                micMetrics.inboundMessageCount += 1
            case .systemAudio:
                systemMetrics.inboundMessageCount += 1
            }
        }
    }

    func updateTranscriptMetrics(source: AudioSource) {
        let now = Date()
        stateLock.withLock {
            switch source {
            case .microphone:
                micMetrics.nonEmptyTranscriptCount += 1
                micMetrics.lastTranscriptAt = now
            case .systemAudio:
                systemMetrics.nonEmptyTranscriptCount += 1
                systemMetrics.lastTranscriptAt = now
            }
        }
    }

    func updateMetricError(source: AudioSource, message: String) {
        stateLock.withLock {
            switch source {
            case .microphone:
                micMetrics.lastError = message
            case .systemAudio:
                systemMetrics.lastError = message
            }
        }
    }
}
// MARK: - Supporting Types

/// Combined connection state for both streams
struct DualStreamConnectionState {
    let mic: DeepgramConnectionState
    let system: DeepgramConnectionState

    var isFullyConnected: Bool {
        mic.isConnected && system.isConnected
    }

    var hasAnyError: Bool {
        if case .error = mic { return true }
        if case .error = system { return true }
        return false
    }
}

struct DualStreamMetrics {
    var sentChunkCount: Int = 0
    var inboundMessageCount: Int = 0
    var nonEmptyTranscriptCount: Int = 0
    var lastTranscriptAt: Date?
    var lastError: String?
}

struct DualStreamMetricsSnapshot {
    let mic: DualStreamMetrics
    let system: DualStreamMetrics
}

// MARK: - AudioSource Extension

extension AudioSource {
    var displayName: String {
        switch self {
        case .microphone:
            return "Mic"
        case .systemAudio:
            return "System"
        }
    }
}

import Foundation

extension AudioCaptureService {
    func resetBufferStats() {
        bufferStateLock.lock()
        micBufferCounter = 0
        systemBufferCounter = 0
        mixedBufferCounter = 0
        lastMicBufferUpdate = 0
        lastSystemBufferUpdate = 0
        lastMixedBufferUpdate = 0
        lastMicActivityTime = 0
        lastSystemActivityTime = 0
        lastMixedActivityTime = 0
        bufferStateLock.unlock()
        DispatchQueue.main.async {
            self.micBufferCount = 0
            self.systemBufferCount = 0
            self.mixedBufferCount = 0
            self.micBufferLastTime = nil
            self.systemBufferLastTime = nil
            self.mixedBufferLastTime = nil
        }
    }

    func noteSystemAudioMetrics(_ metrics: SystemAudioBufferMetrics) {
        let now = Date()
        let nowSeconds = CFAbsoluteTimeGetCurrent()
        var snapshot = systemAudioHealth
        snapshot.rmsDb = metrics.rmsDb
        snapshot.lastBufferAt = now
        systemAudioHealth = snapshot
        if metrics.rmsDb >= silenceThresholdDb {
            lastSystemAudibleAt = now
        }

        let rmsDelta = abs(metrics.rmsDb - lastSystemAudioStatsRmsDb)
        let shouldLog = lastSystemAudioStatsLogTime == 0 ||
            nowSeconds - lastSystemAudioStatsLogTime >= systemAudioStatsLogInterval ||
            rmsDelta >= systemAudioStatsLogRmsDelta

        if shouldLog {
            lastSystemAudioStatsLogTime = nowSeconds
            lastSystemAudioStatsRmsDb = metrics.rmsDb
            DebugNDJSONLogger.shared.log(
                runId: ndjsonRunId,
                hypothesisId: "H4",
                location: "AudioCaptureService.noteSystemAudioMetrics",
                message: "system_audio_buffer_stats",
                data: [
                    "rmsDb": metrics.rmsDb,
                    "sourceSampleRate": metrics.sourceSampleRate,
                    "sourceChannels": Int(metrics.sourceChannels),
                    "frameLength": Int(metrics.frameLength),
                    "conversionPath": metrics.conversionPath
                ]
            )
        }
    }

    func noteSystemAudioConversionFailure(_ reason: String) {
        var snapshot = systemAudioHealth
        snapshot.conversionFailureCount += 1
        systemAudioHealth = snapshot
        DebugNDJSONLogger.shared.log(
            runId: ndjsonRunId,
            hypothesisId: "H4",
            location: "AudioCaptureService.noteSystemAudioConversionFailure",
            message: "system_audio_conversion_failure",
            data: [
                "reason": reason,
                "conversionFailureCount": snapshot.conversionFailureCount
            ]
        )
    }

    func noteSystemTranscriptReceived() {
        var snapshot = systemAudioHealth
        snapshot.systemTranscriptCount += 1
        snapshot.lastTranscriptAt = Date()
        systemAudioHealth = snapshot

        let shouldClearError: Bool = {
            if transcriptionError == .systemAudioSilent || transcriptionError == .systemStreamStalled {
                return true
            }
            if let activeError = transcriptionError,
               case .sourceBasedPipelineUnavailable = activeError {
                return true
            }
            return false
        }()

        if shouldClearError {
            clearError()
            DebugNDJSONLogger.shared.log(
                runId: ndjsonRunId,
                hypothesisId: "H4",
                location: "AudioCaptureService.noteSystemTranscriptReceived",
                message: "system_transcript_recovered",
                data: [
                    "systemTranscriptCount": snapshot.systemTranscriptCount
                ]
            )
        }
    }

    func noteMicBuffer() {
        let now = CFAbsoluteTimeGetCurrent()
        var countToPublish: Int?
        var heartbeatSnapshot: [String: Any]?
        bufferStateLock.lock()
        micBufferCounter += 1
        lastMicActivityTime = now
        if now - lastMicBufferUpdate >= bufferUpdateInterval {
            lastMicBufferUpdate = now
            countToPublish = micBufferCounter
        }
        if now - lastNDJSONHeartbeatTime >= 2.0 {
            lastNDJSONHeartbeatTime = now
            heartbeatSnapshot = [
                "now": now,
                "micBufferCounter": micBufferCounter,
                "systemBufferCounter": systemBufferCounter,
                "mixedBufferCounter": mixedBufferCounter,
                "lastMicActivityTime": lastMicActivityTime,
                "lastSystemActivityTime": lastSystemActivityTime,
                "lastMixedActivityTime": lastMixedActivityTime
            ]
        }
        bufferStateLock.unlock()
        if let count = countToPublish {
            DispatchQueue.main.async {
                self.micBufferCount = count
                self.micBufferLastTime = Date()
            }
        }

        if let snapshot = heartbeatSnapshot {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let inputID = AudioDeviceManager.resolvedInputDeviceID()
                let outputID = AudioDeviceManager.resolvedOutputDeviceID()
                let inputName = inputID.flatMap { AudioDeviceManager.deviceName(for: $0) } ?? "nil"
                let outputName = outputID.flatMap { AudioDeviceManager.deviceName(for: $0) } ?? "nil"
                let inputTransport = inputID.map { AudioDeviceManager.transportType(for: $0).description } ?? "nil"
                let outputTransport = outputID.map { AudioDeviceManager.transportType(for: $0).description } ?? "nil"
                // #region agent log
                DebugNDJSONLogger.shared.log(
                    runId: self.ndjsonRunId,
                    hypothesisId: "H1",
                    location: "AudioCaptureService.noteMicBuffer",
                    message: "buffer_heartbeat",
                    data: snapshot.merging([
                        "captureState": self.captureState.displayName,
                        "desiredState": self.desiredState.displayName,
                        "mode": self.activeTranscriptionMode.displayName,
                        "isRecording": self.isRecording,
                        "audioEngineIsRunning": self.isEngineRunning,
                        "inputTapInstalled": self.isInputTapInstalled,
                        "isDeepgramActive": self.isDeepgramActive,
                        "deepgramLegacyState": self.deepgramLegacyState.debugLabel,
                        "deepgramMicState": self.deepgramMicState.debugLabel,
                        "deepgramSystemState": self.deepgramSystemState.debugLabel,
                        "resolvedInputDeviceId": inputID.map { Int($0) } ?? -1,
                        "resolvedInputDeviceName": inputName,
                        "resolvedInputTransport": inputTransport,
                        "resolvedOutputDeviceId": outputID.map { Int($0) } ?? -1,
                        "resolvedOutputDeviceName": outputName,
                        "resolvedOutputTransport": outputTransport,
                        "transcriptEntriesCount": self.transcriptEntries.count
                    ]) { _, new in new }
                )
                // #endregion
            }
        }
    }

    func noteSystemBuffer() {
        let now = CFAbsoluteTimeGetCurrent()
        var countToPublish: Int?
        bufferStateLock.lock()
        systemBufferCounter += 1
        lastSystemActivityTime = now
        if now - lastSystemBufferUpdate >= bufferUpdateInterval {
            lastSystemBufferUpdate = now
            countToPublish = systemBufferCounter
        }
        bufferStateLock.unlock()
        if let count = countToPublish {
            DispatchQueue.main.async {
                self.systemBufferCount = count
                self.systemBufferLastTime = Date()
            }
        }
    }

    func noteMixedBuffer() {
        let now = CFAbsoluteTimeGetCurrent()
        var countToPublish: Int?
        bufferStateLock.lock()
        mixedBufferCounter += 1
        lastMixedActivityTime = now
        if now - lastMixedBufferUpdate >= bufferUpdateInterval {
            lastMixedBufferUpdate = now
            countToPublish = mixedBufferCounter
        }
        bufferStateLock.unlock()
        if let count = countToPublish {
            DispatchQueue.main.async {
                self.mixedBufferCount = count
                self.mixedBufferLastTime = Date()
            }
        }
    }

    func waitForMixedActivity(timeout: TimeInterval) async -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        bufferStateLock.lock()
        let baseline = lastMixedActivityTime
        bufferStateLock.unlock()
        while CFAbsoluteTimeGetCurrent() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            bufferStateLock.lock()
            let current = lastMixedActivityTime
            bufferStateLock.unlock()
            if current != baseline {
                return true
            }
        }
        return false
    }
}

// MARK: - Debug helpers

private extension DeepgramConnectionState {
    var debugLabel: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .error(let message): return "error:\(message)"
        }
    }
}

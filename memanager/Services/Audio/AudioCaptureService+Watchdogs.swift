import AVFoundation

extension AudioCaptureService {
    func resetSystemAudioHealth() {
        lastSystemAudibleAt = nil
        lastSystemReconnectAttemptAt = nil
        systemReconnectAttempts.removeAll()
        systemAudioHealth = SystemAudioHealthSnapshot()
        lastSystemAudioStatsLogTime = 0
        lastSystemAudioStatsRmsDb = -160
    }

    func startSystemHealthWatchdog() {
        stopSystemHealthWatchdog()
        systemHealthWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateSystemStreamHealth()
            }
        }
    }

    func stopSystemHealthWatchdog() {
        systemHealthWatchdogTimer?.invalidate()
        systemHealthWatchdogTimer = nil
    }

    @MainActor
    private func evaluateSystemStreamHealth() {
        guard activeTranscriptionMode.usesDualStreamTopology,
              desiredState == .recording,
              captureState == .recording else { return }

        let now = Date()
        let snapshot = systemAudioHealth
        guard let lastBufferAt = snapshot.lastBufferAt else { return }

        let bufferAge = now.timeIntervalSince(lastBufferAt)
        guard bufferAge <= noTranscriptTimeout else { return }

        let silentForTooLong: Bool = {
            guard let lastSystemAudibleAt else { return true }
            return now.timeIntervalSince(lastSystemAudibleAt) > noTranscriptTimeout
        }()

        if silentForTooLong {
            if transcriptionError != .systemAudioSilent {
                setError(.systemAudioSilent)
            }
            return
        }

        let transcriptAge: TimeInterval = {
            guard let lastTranscriptAt = snapshot.lastTranscriptAt else { return .infinity }
            return now.timeIntervalSince(lastTranscriptAt)
        }()

        guard transcriptAge > noTranscriptTimeout else { return }
        detectSystemTranscriptStall(now: now, snapshot: snapshot)
    }

    @MainActor
    private func detectSystemTranscriptStall(now: Date, snapshot: SystemAudioHealthSnapshot) {
        if let lastAttempt = lastSystemReconnectAttemptAt,
           now.timeIntervalSince(lastAttempt) < reconnectBackoff {
            return
        }

        systemReconnectAttempts.removeAll { now.timeIntervalSince($0) > reconnectWindow }
        if systemReconnectAttempts.count >= maxReconnectAttempts {
            let details = "System transcript stalled after \(maxReconnectAttempts) retries (\(activeTranscriptionMode.displayName))."
            let pipelineError = TranscriptionError.sourceBasedPipelineUnavailable(details)
            if transcriptionError?.errorDescription != pipelineError.errorDescription {
                setError(pipelineError)
            }
            return
        }

        systemReconnectAttempts.append(now)
        lastSystemReconnectAttemptAt = now

        DebugNDJSONLogger.shared.log(
            runId: ndjsonRunId,
            hypothesisId: "H4",
            location: "AudioCaptureService.detectSystemTranscriptStall",
            message: "system_transcript_stall_detected",
            data: [
                "rmsDb": snapshot.rmsDb,
                "systemTranscriptCount": snapshot.systemTranscriptCount,
                "attemptsInWindow": systemReconnectAttempts.count
            ]
        )

        Task { @MainActor in
            await restartSystemStream(reason: "transcript_stall")
        }
    }

    @MainActor
    func restartSystemStream(reason: String) async {
        guard activeTranscriptionMode.usesDualStreamTopology else { return }

        DebugNDJSONLogger.shared.log(
            runId: ndjsonRunId,
            hypothesisId: "H4",
            location: "AudioCaptureService.restartSystemStream",
            message: "system_stream_reconnect_attempt",
            data: [
                "reason": reason,
                "mode": activeTranscriptionMode.displayName,
                "attemptsInWindow": systemReconnectAttempts.count
            ]
        )

        transcriptMerger?.beginSystemStreamEpoch(resetPartials: true)
        if activeTranscriptionMode.usesSourceBasedDeepgram {
            audioRouter?.resetSystemConversionState()
            dualStreamService?.reconnectSystemStream()
        } else {
            restartAppleAnalyzerSystemStream()
        }

        do {
            try await systemAudioCapture.restart()
            systemAudioHealth.selectedDisplayID = systemAudioCapture.activeDisplayID
            isSystemAudioActive = true
            // A fresh analyzer stream restarts its clock at zero, so realign
            // the timestamp base for segments arriving after the restart.
            if activeTranscriptionMode.usesAppleAnalyzer {
                systemTranscriptStartDate = Date()
            }
        } catch {
            setError(.sourceBasedPipelineUnavailable("System stream restart failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Buffer Health Monitoring

    func startBufferHealthMonitoring() {
        stopBufferHealthMonitoring()
        // Check every 2 seconds with 3s timeout - conservative to avoid false triggers
        // This is now the PRIMARY recovery mechanism (not proactive config change handling)
        bufferHealthTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isRecording else { return }
                // Skip if we're handling a configuration change
                guard !self.isHandlingConfigurationChange else { return }

                let now = Date()
                if let lastBuffer = self.micBufferLastTime,
                   now.timeIntervalSince(lastBuffer) > 3.0 {
                    self.handleBufferTimeout()
                }
            }
        }
    }

    func stopBufferHealthMonitoring() {
        bufferHealthTimer?.invalidate()
        bufferHealthTimer = nil
    }

    @MainActor
    private func handleBufferTimeout() {
        logDebug("CRITICAL: Buffer timeout - no mic data for 1.5+ seconds")

        // Prevent overlap with configuration change handling
        guard !isHandlingConfigurationChange else {
            logDebug("Skipping buffer timeout - configuration change in progress")
            return
        }

        isHandlingConfigurationChange = true

        // Stop current capture
        audioEngine.stop()
        removeInputTapIfNeeded()
        stopBufferHealthMonitoring()

        // Attempt recovery
        Task { @MainActor in
            defer { self.isHandlingConfigurationChange = false }

            // Check we still want to be recording
            guard self.desiredState == .recording else {
                logDebug("Desired state changed during timeout recovery - aborting")
                self.isRecording = false
                self.setRecordingFlag(false)
                return
            }

            // Extended delay to let hardware fully stabilize after Bluetooth transitions
            // Bluetooth HFP state machine transitions take 2-5 seconds
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

            logDebug("Attempting engine restart after buffer timeout...")
            let success = await self.startMicEngine(rebuildOnFailure: true)

            if success {
                logDebug("Recovery successful after buffer timeout")
                self.isRecording = true
                self.setRecordingFlag(true)
            } else {
                logDebug("Direct restart failed - trying fallback device")
                if await self.attemptFallbackDevice() {
                    logDebug("Recovery successful with fallback device")
                    self.isRecording = true
                    self.setRecordingFlag(true)
                } else {
                    logDebug("All recovery attempts failed")
                    self.setError(.audioEngineFailure("Audio stopped unexpectedly - please restart"))
                    self.isRecording = false
                    self.setRecordingFlag(false)
                }
            }
        }
    }

    @MainActor
    func restartMicEngineForDeviceChange() async -> Bool {
        return await startMicEngine(rebuildOnFailure: true)
    }
}

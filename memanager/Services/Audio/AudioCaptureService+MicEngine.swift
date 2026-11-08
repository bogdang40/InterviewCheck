import AVFoundation
import Speech

extension AudioCaptureService {
    /// Updates the cached isEngineRunning property from the main thread.
    /// This must be called after any audioEngine.start() or audioEngine.stop() operations.
    @MainActor
    func syncEngineRunningState() {
        // Access on main thread only - queue operations that modify the engine
        // should call this after their work completes
        isEngineRunning = audioEngine.isRunning
    }

    @MainActor
    func startMicEngine(rebuildOnFailure: Bool = true) async -> Bool {
        isRecording = false
        setRecordingFlag(false)
        DebugNDJSONLogger.shared.log(
            runId: ndjsonRunId,
            hypothesisId: "H1",
            location: "AudioCaptureService.startMicEngine",
            message: "mic_engine_enter",
            data: ["rebuildOnFailure": rebuildOnFailure]
        )

        // 1. Stop any existing engine and create FRESH instance
        audioEngine.stop()
        audioEngine.reset()
        removeInputTapIfNeeded()
        syncEngineRunningState()

        // Brief delay to let audio system stabilize before creating new engine
        // This helps prevent crashes when rapidly restarting sessions
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        audioEngine = AVAudioEngine()

        // 2. Use system default device - don't explicitly bind
        // This improves reliability on AirPods and other Bluetooth devices
        logDebug("Using system default input device")
        DebugNDJSONLogger.shared.log(
            runId: ndjsonRunId,
            hypothesisId: "H1",
            location: "AudioCaptureService.startMicEngine",
            message: "mic_engine_prepared",
            data: [:]
        )

        // 3. Get input node format - accessing inputNode implicitly prepares the engine
        // We avoid calling prepare() explicitly as it can throw uncatchable Objective-C exceptions
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        logDebug("Engine format after prepare: sampleRate=\(format.sampleRate), channels=\(format.channelCount)")
        DebugNDJSONLogger.shared.log(
            runId: ndjsonRunId,
            hypothesisId: "H1",
            location: "AudioCaptureService.startMicEngine",
            message: "mic_engine_format",
            data: [
                "sampleRate": format.sampleRate,
                "channels": Int(format.channelCount)
            ]
        )

        if format.sampleRate <= 0 || format.channelCount <= 0 {
            logDebug("CRITICAL: Cannot get valid audio format - no microphone available")
            DebugNDJSONLogger.shared.log(
                runId: ndjsonRunId,
                hypothesisId: "H1",
                location: "AudioCaptureService.startMicEngine",
                message: "mic_engine_invalid_format",
                data: [
                    "sampleRate": format.sampleRate,
                    "channels": Int(format.channelCount)
                ]
            )
            setError(.noAudioInput)
            return false
        }

        // 4. Connect to mixer (for output muting - prevents feedback)
        audioEngine.connect(inputNode, to: audioEngine.mainMixerNode, format: nil)
        audioEngine.mainMixerNode.outputVolume = 0

        // 5. Install tap BEFORE prepare/start (critical for audio route setup)
        DebugNDJSONLogger.shared.log(
            runId: ndjsonRunId,
            hypothesisId: "H1",
            location: "AudioCaptureService.startMicEngine",
            message: "mic_engine_install_tap_begin",
            data: [:]
        )
        installInputTap(on: inputNode, format: format)
        DebugNDJSONLogger.shared.log(
            runId: ndjsonRunId,
            hypothesisId: "H1",
            location: "AudioCaptureService.startMicEngine",
            message: "mic_engine_install_tap_done",
            data: [:]
        )

        // 6. Prepare engine
        audioEngine.prepare()

        // 7. Start engine
        DebugNDJSONLogger.shared.log(
            runId: ndjsonRunId,
            hypothesisId: "H1",
            location: "AudioCaptureService.startMicEngine",
            message: "mic_engine_start_begin",
            data: ["timeout": engineStartTimeout]
        )
        let startResult = await runEngineStart(timeout: engineStartTimeout) {
            try self.audioEngine.start()
        }
        DebugNDJSONLogger.shared.log(
            runId: ndjsonRunId,
            hypothesisId: "H1",
            location: "AudioCaptureService.startMicEngine",
            message: "mic_engine_start_result",
            data: ["result": String(describing: startResult)]
        )

        switch startResult {
        case .success:
            // CRITICAL: Verify engine actually started (Bluetooth HFP state machine can cause false success)
            guard audioEngine.isRunning else {
                logDebug("CRITICAL: audioEngine.start() succeeded but isRunning is false - Bluetooth state conflict")
                DebugNDJSONLogger.shared.log(
                    runId: ndjsonRunId,
                    hypothesisId: "H1",
                    location: "AudioCaptureService.startMicEngine",
                    message: "mic_engine_not_running",
                    data: [:]
                )
                audioEngine.stop()
                removeInputTapIfNeeded()
                // Try fallback to built-in microphone
                if await attemptFallbackDevice() {
                    return true
                }
                setError(.audioEngineFailure("Audio engine failed to start (isRunning=false)"))
                return false
            }
            isRecording = true
            setRecordingFlag(true)
            isStartingCapture = false
            syncEngineRunningState()
            logDebug("AVAudioEngine recording started successfully (isRunning=true)")
            DebugNDJSONLogger.shared.log(
                runId: ndjsonRunId,
                hypothesisId: "H1",
                location: "AudioCaptureService.startMicEngine",
                message: "mic_engine_started",
                data: [:]
            )

        case .failure(let error):
            if rebuildOnFailure, AudioSampleConverter.isAudioUnitInitializationError(error) {
                logDebug("Audio engine init failed (-10875); retrying with fresh engine")
                audioEngine.stop()
                removeInputTapIfNeeded()
                isRecording = false
                setRecordingFlag(false)
                try? await Task.sleep(nanoseconds: 150_000_000)
                return await startMicEngine(rebuildOnFailure: false)
            }
            logDebug("Failed to start audio engine: \(error)")
            DebugNDJSONLogger.shared.log(
                runId: ndjsonRunId,
                hypothesisId: "H1",
                location: "AudioCaptureService.startMicEngine",
                message: "mic_engine_start_failed",
                data: ["error": error.localizedDescription]
            )
            audioEngine.stop()
            removeInputTapIfNeeded()
            isRecording = false
            setRecordingFlag(false)
            setError(.audioEngineFailure(error.localizedDescription))
            cleanupRecording()
            return false

        case .timeout:
            logDebug("Audio engine start timed out after \(engineStartTimeout)s")
            DebugNDJSONLogger.shared.log(
                runId: ndjsonRunId,
                hypothesisId: "H1",
                location: "AudioCaptureService.startMicEngine",
                message: "mic_engine_start_timeout",
                data: ["timeout": engineStartTimeout]
            )
            audioEngine.stop()
            removeInputTapIfNeeded()
            isRecording = false
            setRecordingFlag(false)
            setError(.audioEngineFailure("Audio engine start timed out after \(engineStartTimeout)s"))
            cleanupRecording()
            return false
        }

        // Verify buffers are actually flowing (catches Bluetooth state issues that pass isRunning check)
        let bufferCountBefore = micBufferCount
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

        if micBufferCount == bufferCountBefore {
            logDebug("CRITICAL: Engine running but no buffers received after 300ms")
            DebugNDJSONLogger.shared.log(
                runId: ndjsonRunId,
                hypothesisId: "H1",
                location: "AudioCaptureService.startMicEngine",
                message: "mic_engine_no_buffers",
                data: ["bufferCountBefore": bufferCountBefore]
            )
            audioEngine.stop()
            removeInputTapIfNeeded()
            isRecording = false
            setRecordingFlag(false)
            // Try fallback to built-in mic
            if await attemptFallbackDevice() {
                return true
            }
            setError(.audioEngineFailure("No audio data received from microphone"))
            return false
        }

        logDebug("Buffer flow verified: \(micBufferCount - bufferCountBefore) buffers received in 300ms")

        // Start buffer health monitoring for mid-session failures
        startBufferHealthMonitoring()

        lastResolvedInputDeviceID = AudioDeviceManager.resolvedInputDeviceID()
        lastResolvedOutputDeviceID = AudioDeviceManager.resolvedOutputDeviceID()

        return true
    }

    private func installInputTap(on inputNode: AVAudioInputNode, format: AVAudioFormat?) {
        let captureToken = currentCaptureToken()
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self = self, self.isCaptureTokenActive(captureToken) else { return }
            self.noteMicBuffer()
            guard self.isRecordingActive() else { return }

            switch self.activeTranscriptionMode {
            case .appleAnalyzer:
                self.routeMicBufferToAppleAnalyzer(buffer)
            case .deepgramSourceBased:
                self.audioRouter?.routeMicAudio(buffer)
            case .deepgramLegacy:
                break // the unified mixer has its own tap
            case .appleSpeech:
                self.recognitionRequest?.append(buffer)
            }
        }
        isInputTapInstalled = true
    }

    func removeInputTapIfNeeded() {
        guard isInputTapInstalled else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        isInputTapInstalled = false
    }

    // MARK: - Fallback Device Logic

    /// Attempts to fall back to built-in microphone when Bluetooth or other devices fail.
    /// Used when isRunning check fails or buffers stop flowing.
    @MainActor
    func attemptFallbackDevice() async -> Bool {
        logDebug("Attempting fallback to built-in microphone")

        guard let builtInID = AudioDeviceManager.builtInInputDeviceID() else {
            logDebug("No built-in microphone available for fallback")
            return false
        }

        // Stop current engine state
        audioEngine.stop()
        removeInputTapIfNeeded()
        audioEngine = AVAudioEngine()

        // Force bind to built-in device
        let success = AudioDeviceManager.setInputDevice(builtInID, on: audioEngine)
        if !success {
            logDebug("Failed to set built-in device as input")
            return false
        }

        logDebug("Falling back to built-in microphone (device ID: \(builtInID))")
        return await startMicEngine(rebuildOnFailure: false)
    }
}

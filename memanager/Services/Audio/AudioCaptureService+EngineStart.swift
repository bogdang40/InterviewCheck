import AVFoundation
import Speech

extension AudioCaptureService {
    // MARK: - Recording with AVAudioEngine

    @MainActor
    func startAudioEngineRecording(reason: StartReason) async -> Bool {
        logDebug("Starting AVAudioEngine recording...")

        if let issue = Self.transcriptionCredentialIssue(
            forceAppleSpeech: settings.forceAppleSpeech,
            analyzerReady: SpeechAnalyzerAssetProvisioner.shared.isReadySnapshot,
            deepgramStatus: voiceSignatureStore.deepgramCredentialStatus
        ) {
            setError(.audioEngineFailure(issue))
            return false
        }

        let resolvedMode = resolveTranscriptionMode()
        print("[MIC-DEBUG] Resolved mode: \(resolvedMode)")
        activeTranscriptionMode = resolvedMode

        // Initialize the streaming engine (takes priority over Eagle)
        if resolvedMode.usesDeepgram {
            print("[MIC-DEBUG] Calling initializeDeepgram")
            initializeDeepgram(resetSpeakerMapping: reason == .newSession, mode: resolvedMode)
        } else if resolvedMode.usesAppleAnalyzer {
            initializeAppleAnalyzer()
            isDeepgramActive = false
        } else {
            isDeepgramActive = false
        }

        // Initialize or resume voice signature if enabled and configured (only if Deepgram not active)
        if activeTranscriptionMode == .appleSpeech {
            if reason == .resume, let service = voiceSignatureService {
                service.reset()
                service.resume()
                micStreamStartTime = 0
                systemStreamStartTime = 0
                isVoiceSignatureActive = true
            } else {
                initializeVoiceSignature()
            }
        }

        if activeTranscriptionMode == .appleSpeech {
            // Check if speech recognizer is available (only required when using Apple speech)
            guard let recognizer = speechRecognizer else {
                logDebug("Speech recognizer is nil")
                setError(.recognizerNotSupported)
                isStartingCapture = false
                return false
            }

            guard recognizer.isAvailable else {
                logDebug("Speech recognizer not available (network issue?)")
                setError(.recognizerUnavailable)
                isStartingCapture = false
                return false
            }

            // Create recognition request
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                logDebug("Failed to create recognition request")
                setError(.audioEngineFailure("Failed to create recognition request"))
                isStartingCapture = false
                return false
            }

            recognitionRequest.shouldReportPartialResults = true
            recognitionRequest.addsPunctuation = true

            // Create recognition task
            let captureToken = currentCaptureToken()
            recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                self?.handleRecognitionResult(
                    result,
                    error: error,
                    source: .microphone,
                    captureToken: captureToken
                )
            }
        }

        // Start unified audio mixer for legacy Deepgram (unified stream) before touching our engine.
        // Unified mixer handles mic internally via its own AVAudioEngine, so we skip our engine/tap.
        if activeTranscriptionMode.usesLegacyDeepgram {
            let started = await startUnifiedMixer()
            if !started {
                logDebug("Unified mixer failed in legacy mode; not falling back due to user setting")
            }
            return started
        }

        DebugNDJSONLogger.shared.log(
            runId: ndjsonRunId,
            hypothesisId: "H1",
            location: "AudioCaptureService.startAudioEngineRecording",
            message: "start_mic_engine_begin",
            data: [
                "mode": activeTranscriptionMode.displayName,
                "reason": reason.displayName
            ]
        )
        return await startMicEngine(rebuildOnFailure: true)
    }

    enum EngineStartResult {
        case success
        case failure(Error)
        case timeout
    }

    func runEngineStart(timeout: TimeInterval, _ work: @escaping () throws -> Void) async -> EngineStartResult {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var didFinish = false

            func finish(_ result: EngineStartResult) {
                lock.lock()
                guard !didFinish else {
                    lock.unlock()
                    return
                }
                didFinish = true
                lock.unlock()
                continuation.resume(returning: result)
            }

            audioEngineQueue.async {
                do {
                    try work()
                    finish(.success)
                } catch {
                    finish(.failure(error))
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                finish(.timeout)
            }
        }
    }

    @MainActor
    private func startUnifiedMixer() async -> Bool {
        guard let mixer = unifiedAudioMixer else {
            print("[MIC-DEBUG] ERROR: unifiedAudioMixer is NIL!")
            setError(.audioEngineFailure("Unified mixer not initialized"))
            isStartingCapture = false
            return false
        }

        print("[MIC-DEBUG] Starting mixer.start() via runEngineStart")
        let result = await runEngineStart(timeout: unifiedEngineStartTimeout) {
            try mixer.start()
        }

        switch result {
        case .success:
            print("[MIC-DEBUG] Mixer started successfully!")
            logDebug("Unified audio mixer started")
            let mixedActive = await waitForMixedActivity(timeout: mixedActivationTimeout)
            if !mixedActive {
                logDebug("No mixed buffers received within \(mixedActivationTimeout)s; continuing anyway")
            }
            isRecording = true
            setRecordingFlag(true)
            isStartingCapture = false
            return true
        case .failure(let error):
            print("[MIC-DEBUG] Mixer FAILED: \(error)")
            if let mixerError = error as? UnifiedAudioMixerError {
                logDebug("Failed to start unified mixer: \(mixerError)")
                switch mixerError {
                case .noInputDevice:
                    setError(.noAudioInput)
                case .invalidInputFormat:
                    setError(.invalidAudioFormat)
                }
            } else {
                logDebug("Failed to start unified mixer: \(error)")
                setError(.audioEngineFailure("Unified mixer: \(error.localizedDescription)"))
            }
            mixer.stop()
            isStartingCapture = false
            return false
        case .timeout:
            print("[MIC-DEBUG] Mixer TIMED OUT")
            logDebug("Unified audio mixer start timed out after \(unifiedEngineStartTimeout)s")
            setError(.audioEngineFailure("Unified mixer start timed out after \(unifiedEngineStartTimeout)s"))
            mixer.stop()
            isStartingCapture = false
            return false
        }
    }
}

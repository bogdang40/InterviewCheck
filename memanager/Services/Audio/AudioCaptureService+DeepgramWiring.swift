import Foundation

extension AudioCaptureService {
    // MARK: - Deepgram

    func initializeDeepgram(resetSpeakerMapping: Bool, mode: TranscriptionMode) {
        guard mode.usesDeepgram else { return }

        // Check if Deepgram API key is configured
        guard let apiKey = voiceSignatureStore.loadDeepgramApiKey(), !apiKey.isEmpty else {
            logDebug("Deepgram: no API key configured")
            isDeepgramActive = false
            return
        }

        switch mode {
        case .deepgramSourceBased:
            initializeSourceBasedDeepgram(apiKey: apiKey)
        case .deepgramLegacy:
            initializeLegacyDeepgram(apiKey: apiKey, resetSpeakerMapping: resetSpeakerMapping)
        case .appleSpeech, .appleAnalyzer:
            break
        }
    }

    /// Initialize source-based speaker identification mode
    /// Microphone = "me", System audio = Deepgram diarization for numbered speakers
    private func initializeSourceBasedDeepgram(apiKey: String) {
        // Reuse existing merger to preserve transcript across pause/resume
        if transcriptMerger == nil {
            transcriptMerger = TranscriptMerger()
        }
        transcriptMerger?.onConflictTelemetry = { [weak self] event, data in
            guard let self else { return }
            DebugNDJSONLogger.shared.log(
                runId: self.ndjsonRunId,
                hypothesisId: "H4",
                location: "AudioCaptureService.initializeSourceBasedDeepgram",
                message: event,
                data: data
            )
        }
        
        // Configure echo filter settings from VoiceSignatureStore
        let echoSettings = VoiceSignatureStore.shared
        transcriptMerger?.configureEchoFilter(
            enabled: echoSettings.echoFilterEnabled,
            threshold: echoSettings.echoFilterThreshold,
            timeWindow: echoSettings.echoFilterTimeWindow
        )

        // Create dual-stream Deepgram service
        let dualService = DualStreamDeepgramService()
        let captureToken = currentCaptureToken()

        // Mic transcripts are always "me"
        dualService.onMicTranscript = { [weak self] segment in
            DispatchQueue.main.async {
                guard let self = self,
                      self.isCaptureTokenActive(captureToken),
                      self.shouldAcceptIncomingTranscripts() else { return }
                self.transcriptMerger?.appendMicTranscript(
                    segment,
                    streamStart: self.micTranscriptStartDate,
                    receivedAt: Date()
                )
                self.syncMergedEntries()
            }
        }

        // System transcripts use Deepgram diarization
        dualService.onSystemTranscript = { [weak self] segment in
            DispatchQueue.main.async {
                guard let self = self,
                      self.isCaptureTokenActive(captureToken),
                      self.shouldAcceptIncomingTranscripts() else { return }
                self.transcriptMerger?.appendSystemTranscript(
                    segment,
                    streamStart: self.systemTranscriptStartDate,
                    receivedAt: Date()
                )
                self.noteSystemTranscriptReceived()
                self.syncMergedEntries()
            }
        }

        // Final words on the shared clock feed the cheating detector.
        // Delivered on the main queue, like the transcript callbacks.
        dualService.onFinalTimedWords = { [weak self] batch in
            MainActor.assumeIsolated {
                guard let self, self.isCaptureTokenActive(captureToken),
                      self.shouldAcceptIncomingTranscripts() else { return }
                InterviewTimeline.shared.ingest(batch)
            }
        }

        dualService.onConnectionStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                self?.deepgramMicState = state.mic
                self?.deepgramSystemState = state.system
            }
            self?.logDebug("Dual stream connection: mic=\(state.mic), system=\(state.system)")
        }

        // Create audio router
        let router = SeparateStreamAudioRouter(dualStreamService: dualService)
        router.onSystemAudioMetrics = { [weak self] metrics in
            DispatchQueue.main.async {
                self?.noteSystemAudioMetrics(metrics)
            }
        }
        router.onSystemAudioConversionFailure = { [weak self] reason in
            DispatchQueue.main.async {
                self?.noteSystemAudioConversionFailure(reason)
            }
        }

        // Verify router is ready (audio format creation succeeded)
        guard router.isReady else {
            logDebug("Failed to initialize audio router - audio system unavailable")
            DispatchQueue.main.async {
                self.isDeepgramActive = false
                self.errorMessage = "Audio system unavailable. Please check your audio settings."
            }
            return
        }

        // Connect to Deepgram
        dualService.connect(apiKey: apiKey)
        router.start()

        dualStreamService = dualService
        audioRouter = router
        isDeepgramActive = true
        logDebug("Source-based Deepgram initialized (mic=me, system=diarized)")
    }

    /// Initialize legacy unified audio stream mode
    /// All speakers identified via acoustic diarization on mixed stream
    private func initializeLegacyDeepgram(apiKey: String, resetSpeakerMapping: Bool) {
        if resetSpeakerMapping {
            // Reset speaker mappings for fresh session
            speakerMapper.reset()
            legacySpeakerCount = 0
            legacyLastSpeakerId = nil
            legacyDiarizationLabelsSeen = false
            legacyDiarizationLastLabelTime = nil
        }

        // Create and configure Deepgram service
        let service = DeepgramService()
        let captureToken = currentCaptureToken()

        // Set up transcript callback
        service.onTranscriptReceived = { [weak self] segment in
            self?.handleDeepgramTranscript(segment, captureToken: captureToken)
        }

        // Set up connection state callback
        service.onConnectionStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                self?.deepgramLegacyState = state
            }
            self?.logDebug("Deepgram connection: \(state)")
        }

        // Create unified audio mixer
        let mixer = UnifiedAudioMixer()
        mixer.setBaseMicGain(voiceSignatureStore.legacyMicGain)
        mixer.setBaseSystemGain(voiceSignatureStore.legacySystemGain)
        mixer.setAutoBalanceEnabled(voiceSignatureStore.legacyAutoBalanceEnabled)
        mixer.onMixedAudio = { [weak self] data in
            // Validate audio data before counting and sending
            guard !data.isEmpty else {
                #if DEBUG
                print("[AudioCapture] Skipping empty audio buffer")
                #endif
                return
            }
            self?.noteMixedBuffer()
            self?.deepgramService?.sendAudio(data)
        }
        mixer.onMicBuffer = { [weak self] in
            self?.noteMicBuffer()
        }
        mixer.onConfigurationChange = { [weak self] in
            Task { @MainActor in
                self?.handleEngineConfigurationChange()
            }
        }

        // Initialize voice signature for auto speaker identification
        if voiceSignatureStore.isAutoSpeakerIdentificationEnabled {
            initializeVoiceSignatureForLegacy()
        }

        // Connect to Deepgram
        service.connect(apiKey: apiKey)

        deepgramService = service
        unifiedAudioMixer = mixer
        isDeepgramActive = true
        print("[MIC-DEBUG] Legacy initialized, mixer set: \(unifiedAudioMixer != nil)")
        logDebug("Legacy Deepgram initialized with unified audio mixer")
    }

    /// Initialize voice signature for legacy mode auto speaker identification
    /// When voice signature detects "me" speaking, auto-marks the current Deepgram speaker
    private func initializeVoiceSignatureForLegacy() {
        // Check if voice signature is enabled and configured
        guard voiceSignatureStore.isEnabled else {
            logDebug("Voice signature disabled - auto mode not available")
            return
        }

        guard voiceSignatureStore.loadAccessKey() != nil else {
            logDebug("Voice signature: no AccessKey configured for auto mode")
            return
        }

        guard voiceSignatureStore.loadProfile() != nil else {
            logDebug("Voice signature: no profile enrolled for auto mode")
            return
        }

        // Create recognition service
        let service = VoiceSignatureRecognitionService(
            store: voiceSignatureStore,
            config: SpeakerRecognitionConfig(
                thresholdEnterMe: voiceSignatureStore.thresholdEnterMe,
                thresholdExitMe: voiceSignatureStore.thresholdExitMe
            )
        )

        // Set up auto-mark callback for when voice signature detects "me"
        service.onLabelChanged = { [weak self] label in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.currentSpeakerLabel = label
                // When voice signature detects "me" speaking, auto-mark the current Deepgram speaker
                if label == .me {
                    self.autoMarkCurrentSpeakerAsMe()
                }
            }
        }

        service.onScoreSample = { [weak self] sample in
            DispatchQueue.main.async {
                self?.currentVoiceScore = sample.score
            }
        }

        do {
            try service.start()
            voiceSignatureService = service
            isVoiceSignatureActive = true
            logDebug("Voice signature initialized for legacy auto mode")
        } catch {
            logDebug("Voice signature failed to start for legacy mode: \(error)")
            voiceSignatureService = nil
            isVoiceSignatureActive = false
        }
    }

    /// Auto-mark the current/last Deepgram speaker as "me" when voice signature detects user's voice.
    /// Only used in legacy diarization mode with auto speaker identification enabled.
    private func autoMarkCurrentSpeakerAsMe() {
        guard activeTranscriptionMode == .deepgramLegacy,
              voiceSignatureStore.isAutoSpeakerIdentificationEnabled else {
            return
        }

        // Find the most recent Deepgram speaker ID from partials or recent entries
        // Use partialOtherDeepgramId first (current active speaker), then fall back to partialMeDeepgramId
        if let speakerId = partialOtherDeepgramId ?? partialMeDeepgramId {
            // Only mark if not already marked as "me"
            if speakerMapper.currentMeSpeakerId != speakerId {
                markSpeakerAsMe(speakerId)
                logDebug("Auto-marked Deepgram speaker \(speakerId) as 'me' via voice signature")
            }
        } else if let lastEntry = transcriptEntries.last, let lastSpeakerId = lastEntry.deepgramSpeakerId {
            // Fall back to the last transcript entry's speaker
            if speakerMapper.currentMeSpeakerId != lastSpeakerId {
                markSpeakerAsMe(lastSpeakerId)
                logDebug("Auto-marked Deepgram speaker \(lastSpeakerId) as 'me' via voice signature (from last entry)")
            }
        }
    }

    func shutdownDeepgram(preserveTranscriptState: Bool) {
        stopSystemHealthWatchdog()
        if activeTranscriptionMode.usesSourceBasedDeepgram {
            // Source-based mode cleanup
            audioRouter?.stop()
            audioRouter = nil

            dualStreamService?.disconnect()
            dualStreamService = nil
            DispatchQueue.main.async {
                self.deepgramMicState = .disconnected
                self.deepgramSystemState = .disconnected
            }

            if preserveTranscriptState {
                transcriptMerger?.clearPartials()
                syncMergedEntries()
                logDebug("Source-based Deepgram shut down (transcript preserved)")
            } else {
                transcriptMerger?.reset()
                transcriptMerger = nil
                logDebug("Source-based Deepgram shut down")
            }
        } else {
            // Legacy mode cleanup
            unifiedAudioMixer?.stop()
            unifiedAudioMixer = nil

            deepgramService?.disconnect()
            deepgramService = nil
            DispatchQueue.main.async {
                self.deepgramLegacyState = .disconnected
            }

            if voiceSignatureStore.isAutoSpeakerIdentificationEnabled {
                voiceSignatureService?.stop()
                voiceSignatureService = nil
                isVoiceSignatureActive = false
                currentSpeakerLabel = .unknown
                currentVoiceScore = 0.0
            }

            logDebug("Legacy Deepgram service and unified mixer shut down")
        }

        isDeepgramActive = false
        activeTranscriptionMode = .appleSpeech
    }
}

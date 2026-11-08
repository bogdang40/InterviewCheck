import AVFoundation
import Foundation

extension AudioCaptureService {
    // MARK: - Apple Analyzer (free on device engine, macOS 26+)

    @available(macOS 26.0, *)
    var appleAnalyzerService: AppleAnalyzerDualStreamService? {
        appleAnalyzerBox as? AppleAnalyzerDualStreamService
    }

    /// Initialize the on device analyzer in source based topology:
    /// microphone stream = "me", system audio stream = the other party.
    func initializeAppleAnalyzer() {
        guard #available(macOS 26.0, *) else {
            logDebug("Apple analyzer requested below macOS 26; ignoring")
            return
        }

        // Reuse existing merger to preserve transcript across pause/resume
        if transcriptMerger == nil {
            transcriptMerger = TranscriptMerger()
        }
        transcriptMerger?.onConflictTelemetry = { [weak self] event, data in
            guard let self else { return }
            DebugNDJSONLogger.shared.log(
                runId: self.ndjsonRunId,
                hypothesisId: "H4",
                location: "AudioCaptureService.initializeAppleAnalyzer",
                message: event,
                data: data
            )
        }

        let echoSettings = VoiceSignatureStore.shared
        transcriptMerger?.configureEchoFilter(
            enabled: echoSettings.echoFilterEnabled,
            threshold: echoSettings.echoFilterThreshold,
            timeWindow: echoSettings.echoFilterTimeWindow
        )

        let captureToken = currentCaptureToken()
        let locale = SpeechAnalyzerAssetProvisioner.shared.resolvedLocaleSnapshot
            ?? Locale(identifier: "en_US")
        let service = AppleAnalyzerDualStreamService(locale: locale)

        // Segments arrive on the main queue; mic finals are always "me".
        service.onMicTranscript = { [weak self] segment in
            guard let self,
                  self.isCaptureTokenActive(captureToken),
                  self.shouldAcceptIncomingTranscripts() else { return }
            self.transcriptMerger?.appendMicTranscript(
                segment,
                streamStart: self.micTranscriptStartDate,
                receivedAt: Date()
            )
            self.syncMergedEntries()
        }

        service.onSystemTranscript = { [weak self] segment in
            guard let self,
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

        service.onConnectionStateChanged = { [weak self] state in
            DispatchQueue.main.async {
                self?.deepgramMicState = state.mic
                self?.deepgramSystemState = state.system
            }
            self?.logDebug("Apple analyzer streams: mic=\(state.mic), system=\(state.system)")
        }

        service.onSystemAudioMetrics = { [weak self] metrics in
            DispatchQueue.main.async {
                self?.noteSystemAudioMetrics(metrics)
            }
        }

        service.start()
        appleAnalyzerBox = service
        isAppleAnalyzerActive = true
        logDebug("Apple analyzer transcription initialized (mic=me, system=speaker)")
    }

    func shutdownAppleAnalyzer(preserveTranscriptState: Bool) {
        stopSystemHealthWatchdog()

        if #available(macOS 26.0, *) {
            appleAnalyzerService?.stop()
        }
        appleAnalyzerBox = nil
        DispatchQueue.main.async {
            self.deepgramMicState = .disconnected
            self.deepgramSystemState = .disconnected
        }

        if preserveTranscriptState {
            transcriptMerger?.clearPartials()
            syncMergedEntries()
            logDebug("Apple analyzer shut down (transcript preserved)")
        } else {
            transcriptMerger?.reset()
            transcriptMerger = nil
            logDebug("Apple analyzer shut down")
        }

        isAppleAnalyzerActive = false
        activeTranscriptionMode = .appleSpeech
    }

    /// Mode aware teardown used by the capture state machine.
    func shutdownActiveTranscriptionEngine(preserveTranscriptState: Bool) {
        if activeTranscriptionMode == .appleAnalyzer {
            shutdownAppleAnalyzer(preserveTranscriptState: preserveTranscriptState)
        } else {
            shutdownDeepgram(preserveTranscriptState: preserveTranscriptState)
        }
    }

    func routeMicBufferToAppleAnalyzer(_ buffer: AVAudioPCMBuffer) {
        guard #available(macOS 26.0, *) else { return }
        appleAnalyzerService?.ingestMicBuffer(buffer)
    }

    func routeSystemBufferToAppleAnalyzer(_ buffer: AVAudioPCMBuffer) {
        guard #available(macOS 26.0, *) else { return }
        appleAnalyzerService?.ingestSystemBuffer(buffer)
    }

    func restartAppleAnalyzerSystemStream() {
        guard #available(macOS 26.0, *) else { return }
        appleAnalyzerService?.restartSystemStream()
    }
}

import Foundation

extension AudioCaptureService {
    // MARK: - Voice Signature

    func initializeVoiceSignature() {
        // Check if voice signature is enabled and configured
        guard voiceSignatureStore.isEnabled else {
            logDebug("Voice signature disabled in settings")
            return
        }

        guard voiceSignatureStore.loadAccessKey() != nil else {
            logDebug("Voice signature: no AccessKey configured")
            return
        }

        guard voiceSignatureStore.loadProfile() != nil else {
            logDebug("Voice signature: no profile enrolled")
            return
        }

        // Create and start recognition service
        let service = VoiceSignatureRecognitionService(
            store: voiceSignatureStore,
            config: SpeakerRecognitionConfig(
                thresholdEnterMe: voiceSignatureStore.thresholdEnterMe,
                thresholdExitMe: voiceSignatureStore.thresholdExitMe
            )
        )

        // Create labeler for transcript integration
        transcriptionLabeler = TranscriptionLabeler(
            recognitionService: service,
            config: SpeakerRecognitionConfig(
                thresholdEnterMe: voiceSignatureStore.thresholdEnterMe,
                thresholdExitMe: voiceSignatureStore.thresholdExitMe
            )
        )

        // Set up callbacks for UI updates
        service.onLabelChanged = { [weak self] label in
            DispatchQueue.main.async {
                self?.currentSpeakerLabel = label
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
            micStreamStartTime = 0
            systemStreamStartTime = 0
            isVoiceSignatureActive = true
            logDebug("Voice signature recognition started")
        } catch {
            logDebug("Voice signature failed to start: \(error)")
            voiceSignatureService = nil
            transcriptionLabeler = nil
            isVoiceSignatureActive = false
        }
    }

    func shutdownVoiceSignature() {
        voiceSignatureService?.stop()
        voiceSignatureService = nil
        transcriptionLabeler = nil
        micStreamStartTime = 0
        systemStreamStartTime = 0
        isVoiceSignatureActive = false
        currentSpeakerLabel = .unknown
        currentVoiceScore = 0.0
        logDebug("Voice signature recognition stopped")
    }
}

import Foundation

extension AudioCaptureService {
    /// A pending or denied cloud credential must not select a different engine.
    /// Explicit local engines do not depend on cloud credential availability.
    static func transcriptionCredentialIssue(
        forceAppleSpeech: Bool,
        analyzerReady: Bool,
        deepgramStatus: CredentialStatus
    ) -> String? {
        guard !forceAppleSpeech, !analyzerReady else { return nil }
        switch deepgramStatus {
        case .configured, .missing:
            return nil
        case .loading, .saving:
            return "Voice credentials are still loading or saving. Try starting again when this finishes."
        case .unavailable(let message), .saveFailed(let message):
            return "Voice credentials are unavailable. \(message) Retry in Settings > Voice."
        }
    }

    func shouldRequireSpeechPermission() -> Bool {
        resolveTranscriptionMode() == .appleSpeech
    }

    static func shouldAutoSwitchLegacyDeepgramToSourceBased(
        useSourceBasedPreference: Bool,
        inputTransport: AudioTransportType?,
        outputTransport: AudioTransportType?
    ) -> Bool {
        guard !useSourceBasedPreference else { return false }
        let inputIsBluetooth = inputTransport?.isBluetooth ?? false
        let outputIsBluetooth = outputTransport?.isBluetooth ?? false
        return inputIsBluetooth || outputIsBluetooth
    }

    private func shouldAutoSwitchLegacyDeepgramToSourceBasedForCurrentRoute() -> Bool {
        let inputTransport = AudioDeviceManager.resolvedInputDeviceID()
            .map { AudioDeviceManager.transportType(for: $0) }
        let outputTransport = AudioDeviceManager.resolvedOutputDeviceID()
            .map { AudioDeviceManager.transportType(for: $0) }

        return Self.shouldAutoSwitchLegacyDeepgramToSourceBased(
            useSourceBasedPreference: useSourceBasedIdentification,
            inputTransport: inputTransport,
            outputTransport: outputTransport
        )
    }

    /// Pure decision table for engine selection, unit tested directly.
    ///
    /// Priority: explicit legacy dictation escape hatch, then the free
    /// on device analyzer whenever its model assets are installed, then the
    /// pre existing Deepgram/Apple Speech fallback ladder for older systems.
    static func resolvePreferredTranscriptionMode(
        forceAppleSpeech: Bool,
        analyzerReady: Bool,
        hasDeepgramKey: Bool,
        useSourceBasedPreference: Bool,
        autoSwitchLegacyToSourceBased: Bool
    ) -> TranscriptionMode {
        if forceAppleSpeech {
            return .appleSpeech
        }
        if analyzerReady {
            return .appleAnalyzer
        }
        guard hasDeepgramKey else {
            return .appleSpeech
        }
        if useSourceBasedPreference || autoSwitchLegacyToSourceBased {
            return .deepgramSourceBased
        }
        return .deepgramLegacy
    }

    func resolveTranscriptionMode() -> TranscriptionMode {
        // The cheating detector needs per-word timing on both sides of the
        // call, which only the two-stream Deepgram mode provides. Use it
        // whenever a Deepgram key exists, ahead of the on-device engines.
        if let apiKey = voiceSignatureStore.loadDeepgramApiKey(), !apiKey.isEmpty {
            return .deepgramSourceBased
        }
        if settings.forceAppleSpeech {
            return .appleSpeech
        }
        if SpeechAnalyzerAssetProvisioner.shared.isReadySnapshot {
            return .appleAnalyzer
        }
        guard let apiKey = voiceSignatureStore.loadDeepgramApiKey(), !apiKey.isEmpty else {
            return .appleSpeech
        }
        // Respect user's choice: source-based or legacy diarization
        if useSourceBasedIdentification {
            return .deepgramSourceBased
        } else if shouldAutoSwitchLegacyDeepgramToSourceBasedForCurrentRoute() {
            let inputID = AudioDeviceManager.resolvedInputDeviceID()
            let outputID = AudioDeviceManager.resolvedOutputDeviceID()
            let inputName = inputID.flatMap { AudioDeviceManager.deviceName(for: $0) } ?? "nil"
            let outputName = outputID.flatMap { AudioDeviceManager.deviceName(for: $0) } ?? "nil"
            let inputTransport = inputID.map { AudioDeviceManager.transportType(for: $0).description } ?? "nil"
            let outputTransport = outputID.map { AudioDeviceManager.transportType(for: $0).description } ?? "nil"
            logDebug("Auto-switching legacy Deepgram to source-based on Bluetooth route (input=\(inputName), output=\(outputName))")
            DebugNDJSONLogger.shared.log(
                runId: ndjsonRunId,
                hypothesisId: "H1",
                location: "AudioCaptureService.resolveTranscriptionMode",
                message: "auto_switch_legacy_to_source_based",
                data: [
                    "inputDeviceName": inputName,
                    "inputTransport": inputTransport,
                    "outputDeviceName": outputName,
                    "outputTransport": outputTransport
                ]
            )
            return .deepgramSourceBased
        } else {
            logDebug("Using legacy Deepgram diarization mode")
            return .deepgramLegacy
        }
    }
}

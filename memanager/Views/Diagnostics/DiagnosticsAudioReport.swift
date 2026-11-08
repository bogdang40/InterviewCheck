import Foundation

/// The forty five audio rows: capture state, transcription mode, Deepgram
/// streams, diarization, system audio health, conflicts, voice signature,
/// and buffer counters.
@MainActor
struct DiagnosticsAudioReport {
    let audioService: AudioCaptureService
    let settings: SettingsManager
    let permissionManager: PermissionManager
    let voiceStore: VoiceSignatureStore

    var group: DiagnosticsGroup {
        DiagnosticsGroup(title: "Audio", systemImage: "waveform", rows: captureRows + streamRows + healthRows + voiceRows, startsCollapsed: true)
    }

    private var captureRows: [DiagnosticsRow] {
        [
            row("Capture State", audioService.captureState.displayName),
            row("Start Phase", audioService.startPhase.displayName),
            row("Desired State", audioService.desiredState.displayName),
            row("Pending Start", audioService.pendingStartReasonLabel),
            row("Is Recording", bool(audioService.isRecording)),
            row("Is Starting", bool(audioService.isStartingCaptureFlag)),
            row("Engine Running", bool(audioService.audioEngineRunning)),
            row("Input Tap", bool(audioService.inputTapInstalled)),
            row("Active Mode", audioService.activeTranscriptionModeLabel),
            row("Resolved Mode", audioService.resolvedTranscriptionModeLabel),
            row("Force Apple", bool(settings.forceAppleSpeech))
        ]
    }

    private var streamRows: [DiagnosticsRow] {
        [
            row("Deepgram Active", bool(audioService.isDeepgramActive)),
            row("Deepgram Legacy", DiagnosticsValueFormatter.deepgram(audioService.deepgramLegacyState)),
            row("Deepgram Mic", DiagnosticsValueFormatter.deepgram(audioService.deepgramMicState)),
            row("Deepgram System", DiagnosticsValueFormatter.deepgram(audioService.deepgramSystemState)),
            row("Legacy Speakers", "\(audioService.legacySpeakerCount)"),
            row("Legacy Last Spk", audioService.legacyLastSpeakerId.map(String.init) ?? "n/a"),
            row("Diarization Seen", bool(audioService.legacyDiarizationLabelsSeen)),
            row("Diarization Last", DiagnosticsValueFormatter.timeAgo(audioService.legacyDiarizationLastLabelTime)),
            row("System Audio", bool(audioService.isSystemAudioActive)),
            row("Legacy Sys Audio", legacySystemAudioStatus)
        ]
    }

    private var healthRows: [DiagnosticsRow] {
        let health = audioService.systemAudioHealth
        return [
            row("System RMS (dB)", DiagnosticsValueFormatter.decimal(health.rmsDb, places: 1)),
            row("System Last Buffer", DiagnosticsValueFormatter.timeAgo(health.lastBufferAt)),
            row("System Last Tx", DiagnosticsValueFormatter.timeAgo(health.lastTranscriptAt)),
            row("System Tx Count", "\(health.systemTranscriptCount)"),
            row("System Conv Fail", "\(health.conversionFailureCount)"),
            row("Capture Display", health.selectedDisplayID.map { String($0) } ?? "n/a"),
            row("DG Sys Sent", "\(audioService.deepgramSystemSentChunkCount)"),
            row("DG Sys Inbound", "\(audioService.deepgramSystemInboundMessageCount)"),
            row("DG Sys Tx", "\(audioService.deepgramSystemTranscriptCount)"),
            row("DG Sys Last Err", audioService.deepgramSystemLastError),
            row("Conflict Mic Suppr", "\(audioService.transcriptConflictMicSuppressedCount)"),
            row("Conflict Sys Suppr", "\(audioService.transcriptConflictSystemSuppressedCount)"),
            row("Conflict Retro", "\(audioService.transcriptConflictRetroCorrectionCount)"),
            row("Conflict Last", audioService.transcriptConflictLastDecision),
            row("Capture Sys Audio", bool(settings.captureSystemAudio))
        ]
    }

    private var voiceRows: [DiagnosticsRow] {
        [
            row("Voice Signature", bool(audioService.isVoiceSignatureActive)),
            row("Speaker", audioService.currentSpeakerLabel.displayName),
            row("Voice Score", DiagnosticsValueFormatter.decimal(Double(audioService.currentVoiceScore))),
            row("Deepgram Key", DiagnosticsValueFormatter.accessKey(voiceStore.deepgramApiKeyStatus)),
            row("Source Based ID", bool(voiceStore.useSourceBasedIdentification)),
            row("Legacy AutoBalance", bool(voiceStore.legacyAutoBalanceEnabled)),
            row("Legacy Mic Gain", DiagnosticsValueFormatter.gain(Double(voiceStore.legacyMicGain))),
            row("Legacy Sys Gain", DiagnosticsValueFormatter.gain(Double(voiceStore.legacySystemGain))),
            row("Mic Buffers", DiagnosticsValueFormatter.buffer(count: audioService.micBufferCount, last: audioService.micBufferLastTime)),
            row("Sys Buffers", DiagnosticsValueFormatter.buffer(count: audioService.systemBufferCount, last: audioService.systemBufferLastTime)),
            row("Mix Buffers", DiagnosticsValueFormatter.buffer(count: audioService.mixedBufferCount, last: audioService.mixedBufferLastTime))
        ]
    }

    private var legacySystemAudioStatus: String {
        guard audioService.isLegacyDeepgramMode else { return "n/a" }
        if !settings.captureSystemAudio { return "disabled" }
        if !permissionManager.screenRecordingStatus.isGranted { return "no permission" }
        if !audioService.isSystemAudioActive { return "inactive" }
        return "active (\(DiagnosticsValueFormatter.timeAgo(audioService.systemBufferLastTime)))"
    }

    private func row(_ label: String, _ value: String) -> DiagnosticsRow {
        DiagnosticsRow(label: label, value: value)
    }

    private func bool(_ value: Bool) -> String {
        DiagnosticsValueFormatter.bool(value)
    }
}

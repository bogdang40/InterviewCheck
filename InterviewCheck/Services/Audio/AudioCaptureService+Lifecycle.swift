import AVFoundation
import Combine
import Speech
import AppKit
import CoreMedia
import CoreAudio

extension AudioCaptureService {
    @MainActor
    func performStartCapture(reason: StartReason) async -> Bool {
        logDebug("startCapture requested (reason=\(reason))")

        guard !isStartingCapture else {
            logDebug("startCapture blocked: already starting")
            return false
        }

        isStartingCapture = true
        defer { isStartingCapture = false }
        bumpCaptureToken()
        resetTranscriptStartTimes()
        clearError()
        // Heal a failed or never-started model download; no-op once ready.
        SpeechAnalyzerAssetProvisioner.shared.provisionIfNeeded()
        if reason == .newSession {
            resetBufferStats()
        }
        startPhase = .checkingPermissions

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if micStatus != .authorized || (shouldRequireSpeechPermission() && speechStatus != .authorized) {
            NSApp.activate(ignoringOtherApps: true)
        }

        let micPermission = await PermissionManager.shared.requestMicrophonePermissionAsync()
        guard micPermission.isGranted else {
            setError(.microphoneDenied)
            startPhase = .failed
            isStartingCapture = false
            return false
        }

        if shouldRequireSpeechPermission() {
            let speechPermission = await PermissionManager.shared.requestSpeechRecognitionPermissionAsync()
            guard speechPermission.isGranted else {
                switch speechPermission {
                case .restricted:
                    setError(.speechRecognitionRestricted)
                default:
                    setError(.speechRecognitionDenied)
                }
                startPhase = .failed
                isStartingCapture = false
                return false
            }
        }

        guard desiredState != .idle else {
            startPhase = .failed
            isStartingCapture = false
            return false
        }

        startPhase = .startingEngine

        // #region agent log
        let resolvedModeForLog = resolveTranscriptionMode()
        let inputDeviceID = AudioDeviceManager.resolvedInputDeviceID()
        let outputDeviceID = AudioDeviceManager.resolvedOutputDeviceID()
        let inputDeviceName = inputDeviceID.flatMap { AudioDeviceManager.deviceName(for: $0) } ?? "nil"
        let outputDeviceName = outputDeviceID.flatMap { AudioDeviceManager.deviceName(for: $0) } ?? "nil"
        let inputTransport = inputDeviceID.map { AudioDeviceManager.transportType(for: $0).description } ?? "nil"
        let outputTransport = outputDeviceID.map { AudioDeviceManager.transportType(for: $0).description } ?? "nil"
        DebugNDJSONLogger.shared.log(
            runId: ndjsonRunId,
            hypothesisId: "H1",
            location: "AudioCaptureService.performStartCapture",
            message: "start_capture_begin",
            data: [
                "reason": reason.displayName,
                "desiredState": desiredState.displayName,
                "captureState": captureState.displayName,
                "startPhase": startPhase.displayName,
                "forceAppleSpeech": settings.forceAppleSpeech,
                "captureSystemAudio": settings.captureSystemAudio,
                "useSourceBasedIdentification": useSourceBasedIdentification,
                "resolvedMode": resolvedModeForLog.displayName,
                "inputDeviceId": inputDeviceID.map { Int($0) } ?? -1,
                "inputDeviceName": inputDeviceName,
                "inputTransport": inputTransport,
                "outputDeviceId": outputDeviceID.map { Int($0) } ?? -1,
                "outputDeviceName": outputDeviceName,
                "outputTransport": outputTransport
            ]
        )
        // #endregion

        let started = await startAudioEngineRecording(reason: reason)
        guard started else {
            startPhase = .failed
            if reason == .resume {
                shutdownActiveTranscriptionEngine(preserveTranscriptState: true)
            } else {
                shutdownActiveTranscriptionEngine(preserveTranscriptState: false)
            }
            return false
        }

        micTranscriptStartDate = Date()
        scheduleSystemAudioStart()
        if activeTranscriptionMode.usesDualStreamTopology {
            startSystemHealthWatchdog()
        } else {
            stopSystemHealthWatchdog()
        }
        startPhase = .started

        return true
    }

    @MainActor
    func performPauseCapture() async {
        logDebug("pauseCapture called")

        // Signal to tap callbacks to stop processing FIRST
        bumpCaptureToken()
        resetTranscriptStartTimes()
        isRecording = false
        setRecordingFlag(false)
        isStartingCapture = false
        invalidateSystemAudioStart()

        // Stop buffer health monitoring
        stopBufferHealthMonitoring()

        let usingAppleSpeech = activeTranscriptionMode == .appleSpeech

        if activeTranscriptionMode.usesLegacyDeepgram {
            finalizeLegacyDeepgramPartials()
        }

        // Preserve partials for dual stream modes before shutdown
        transcriptMerger?.finalizePartials()

        // Shutdown external services before audio engine
        shutdownActiveTranscriptionEngine(preserveTranscriptState: true)

        // Stop audio engine and remove tap
        audioEngine.stop()
        removeInputTapIfNeeded()
        syncEngineRunningState()

        // Finalize transcripts (preserves partial speech as entries)
        cleanupRecording(preservePartials: usingAppleSpeech)

        // Stop system audio capture
        await stopSystemAudioRecording(preservePartials: usingAppleSpeech)
        stopSystemHealthWatchdog()

        // Consolidate any fragmented entries
        consolidateTranscriptEntries()

        logDebug("Recording paused (partials preserved)")
    }

    @MainActor
    func performStopCapture() async {
        logDebug("stopCapture called")

        // Signal to tap callbacks to stop processing FIRST
        bumpCaptureToken()
        resetTranscriptStartTimes()
        isRecording = false
        setRecordingFlag(false)
        isStartingCapture = false
        invalidateSystemAudioStart()

        // Stop buffer health monitoring
        stopBufferHealthMonitoring()

        // Shutdown external services before audio engine
        shutdownActiveTranscriptionEngine(preserveTranscriptState: false)

        // Stop audio engine and remove tap if needed
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        removeInputTapIfNeeded()
        syncEngineRunningState()

        // Cleanup recognition requests
        cleanupRecording(preservePartials: false)

        // Stop system audio capture
        await stopSystemAudioRecording(preservePartials: false)
        stopSystemHealthWatchdog()

        // Consolidate any fragmented entries
        consolidateTranscriptEntries()

        logDebug("Recording stopped")
    }
}

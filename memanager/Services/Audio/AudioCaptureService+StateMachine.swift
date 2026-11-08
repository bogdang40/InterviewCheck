import AVFoundation
import Combine
import Speech
import AppKit
import CoreMedia
import CoreAudio

extension AudioCaptureService {
    // MARK: - Public Interface

    func startCapture() {
        Task { @MainActor in
            requestStart(reason: .newSession)
        }
    }

    func stopCapture() {
        Task { @MainActor in
            requestStop(clearTranscript: false)
        }
    }

    /// Pause capture while preserving partial transcripts
    /// Unlike stopCapture(), this finalizes partials into transcript entries
    func pauseCapture() {
        Task { @MainActor in
            requestPause()
        }
    }

    /// Resume capture after pause
    func resumeCapture() {
        Task { @MainActor in
            requestStart(reason: .resume)
        }
    }

    func stopCaptureAndClearTranscript() {
        Task { @MainActor in
            requestStop(clearTranscript: true)
        }
    }

    func retrySystemStream() {
        Task { @MainActor in
            await restartSystemStream(reason: "manual_retry")
        }
    }

    @MainActor
    func stopCaptureAndWait(clearTranscript: Bool, timeout: TimeInterval = 6.0) async -> Bool {
        requestStop(clearTranscript: clearTranscript)
        return await waitForCaptureState(.idle, timeout: timeout)
    }

    @MainActor
    func waitForCaptureState(_ target: CaptureState, timeout: TimeInterval = 6.0) async -> Bool {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while !(captureState == target && transitionTask == nil) {
            if Task.isCancelled {
                return false
            }
            if CFAbsoluteTimeGetCurrent() > deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    // MARK: - Capture State Machine

    @MainActor
    func requestStart(reason: StartReason) {
        pendingStartReason = reason
        desiredState = .recording
        if reason == .newSession {
            shouldClearTranscriptOnStop = true
        }
        scheduleStateMachine()
    }

    @MainActor
    func requestPause() {
        desiredState = .paused
        isRecording = false
        setRecordingFlag(false)
        invalidateSystemAudioStart()
        scheduleStateMachine()
    }

    @MainActor
    func requestStop(clearTranscript: Bool) {
        shouldClearTranscriptOnStop = shouldClearTranscriptOnStop || clearTranscript
        desiredState = .idle
        isRecording = false
        setRecordingFlag(false)
        invalidateSystemAudioStart()
        scheduleStateMachine()
    }

    @MainActor
    func scheduleStateMachine() {
        stateMachineDirty = true
        guard transitionTask == nil else { return }
        transitionTask = Task { [weak self] in
            await self?.runStateMachine()
        }
    }

    @MainActor
    func invalidateSystemAudioStart() {
        systemAudioStartToken &+= 1
        systemAudioStartTask?.cancel()
        systemAudioStartTask = nil
    }

    @MainActor
    func scheduleSystemAudioStart() {
        invalidateSystemAudioStart()
        let token = systemAudioStartToken
        systemAudioStartTask = Task { [weak self] in
            await self?.startSystemAudioRecording(startToken: token)
        }
    }

    @MainActor
    func runStateMachine() async {
        while true {
            stateMachineDirty = false
            switch desiredState {
            case .idle:
                if captureState != .idle {
                    captureState = .stopping
                    await performStopCapture()
                    captureState = .idle
                    startPhase = .idle
                }
                if shouldClearTranscriptOnStop {
                    clearTranscript()
                    shouldClearTranscriptOnStop = false
                }

            case .paused:
                switch captureState {
                case .paused:
                    break
                case .idle:
                    desiredState = .idle
                    continue
                case .recording:
                    captureState = .pausing
                    await performPauseCapture()
                    captureState = .paused
                case .starting, .pausing, .stopping:
                    break
                }

            case .recording:
                if captureState != .recording {
                    if !pendingStartReason.canStart(
                        from: captureState,
                        hasRestoredTranscript: restoredSessionTranscript != nil
                    ) {
                        desiredState = .idle
                        continue
                    }

                    if pendingStartReason == .newSession && captureState != .idle {
                        captureState = .stopping
                        shouldClearTranscriptOnStop = true
                        await performStopCapture()
                        captureState = .idle
                        startPhase = .idle
                        if shouldClearTranscriptOnStop {
                            clearTranscript()
                            shouldClearTranscriptOnStop = false
                        }
                    }

                    let startReason = pendingStartReason

                    if startReason == .newSession && captureState == .idle {
                        clearTranscript()
                        shouldClearTranscriptOnStop = false
                    }

                    captureState = .starting
                    let started = await performStartCapture(reason: startReason)
                    if started {
                        captureState = .recording
                    } else {
                        if startReason == .resume {
                            captureState = .paused
                            desiredState = .paused
                        } else {
                            captureState = .idle
                            desiredState = .idle
                        }
                    }
                }
            }

            if stateMachineDirty {
                continue
            }

            if desiredState == .idle && captureState == .idle {
                startPhase = .idle
                transitionTask = nil
                return
            }
            if desiredState == .paused && captureState == .paused {
                transitionTask = nil
                return
            }
            if desiredState == .recording && captureState == .recording {
                transitionTask = nil
                return
            }

            await Task.yield()
        }
    }
}

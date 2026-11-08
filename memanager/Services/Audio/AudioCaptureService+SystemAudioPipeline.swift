import AVFoundation
import Speech
import CoreMedia
import CoreAudio

extension AudioCaptureService {
    // MARK: - System Audio (Other Speaker)

    func startSystemAudioRecording(startToken: UInt64) async {
        let shouldStart = await MainActor.run {
            self.systemAudioStartToken == startToken &&
            self.desiredState == .recording &&
            self.captureState != .stopping &&
            self.captureState != .idle
        }
        guard shouldStart else { return }

        if !settings.captureSystemAudio {
            if activeTranscriptionMode.forcesSystemAudioCapture {
                logDebug("System audio capture disabled in settings; enabling for \(activeTranscriptionMode.displayName)")
                await MainActor.run {
                    self.settings.captureSystemAudio = true
                }
            } else {
                logDebug("System audio capture disabled in settings")
                return
            }
        }

        await MainActor.run {
            PermissionManager.shared.refreshScreenRecordingStatus()
        }

        // Check screen recording permission (required for ScreenCaptureKit system audio)
        guard PermissionManager.shared.screenRecordingStatus.isGranted else {
            logDebug("Screen recording permission required for system audio capture")
            await MainActor.run {
                if self.systemAudioStartToken == startToken && self.desiredState == .recording {
                    self.setError(.screenRecordingDenied)
                }
            }
            return
        }

        if activeTranscriptionMode == .appleSpeech {
            if systemRecognitionTask == nil {
                guard let recognizer = systemSpeechRecognizer, recognizer.isAvailable else {
                    logDebug("System audio recognizer unavailable - skipping system audio capture")
                    return
                }

                systemRecognitionRequest = SFSpeechAudioBufferRecognitionRequest()
                guard let request = systemRecognitionRequest else {
                    logDebug("Failed to create system recognition request")
                    return
                }

                request.shouldReportPartialResults = true
                request.addsPunctuation = true

                let captureToken = currentCaptureToken()
                systemRecognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    self?.handleRecognitionResult(
                        result,
                        error: error,
                        source: .systemAudio,
                        captureToken: captureToken
                    )
                }
            }
        } else {
            systemRecognitionRequest?.endAudio()
            systemRecognitionTask?.cancel()
            systemRecognitionRequest = nil
            systemRecognitionTask = nil
        }

        let captureToken = currentCaptureToken()
        systemAudioCapture.onSampleBuffer = { [weak self] sampleBuffer in
            guard let self = self, self.isCaptureTokenActive(captureToken) else { return }
            self.noteSystemBuffer()

            // Route audio based on active transcription provider and mode
            switch self.activeTranscriptionMode {
            case .appleAnalyzer:
                // On device analyzer: convert once, feed the system stream
                if let pcmBuffer = self.convertSampleBuffer(sampleBuffer) {
                    self.routeSystemBufferToAppleAnalyzer(pcmBuffer)
                }
            case .deepgramSourceBased:
                // Source-based mode: route system audio directly to audio router
                self.audioRouter?.routeSystemAudio(sampleBuffer)
            case .deepgramLegacy:
                // Legacy mode: inject into unified audio mixer for combined stream
                self.unifiedAudioMixer?.injectSystemAudio(sampleBuffer)
            case .appleSpeech:
                // Use Apple Speech Recognition
                guard let request = self.systemRecognitionRequest else { return }
                self.appendSampleBuffer(sampleBuffer, to: request)
            }
        }

        systemAudioCapture.onError = { [weak self] error in
            self?.logDebug("System audio capture error: \(error)")
        }

        guard !systemAudioCapture.isRunning else { return }

        do {
            try await systemAudioCapture.start()
            let shouldKeep = await MainActor.run {
                self.systemAudioStartToken == startToken &&
                self.desiredState == .recording &&
                (self.captureState == .recording || self.captureState == .starting)
            }
            guard shouldKeep else {
                await stopSystemAudioRecording(preservePartials: false)
                return
            }

            await MainActor.run { self.isSystemAudioActive = true }
            await MainActor.run {
                self.systemTranscriptStartDate = Date()
                self.systemAudioHealth.selectedDisplayID = self.systemAudioCapture.activeDisplayID
            }
            logDebug("System audio capture started successfully")
        } catch {
            logDebug("System audio capture failed to start: \(error)")
            systemRecognitionTask?.cancel()
            systemRecognitionTask = nil
            self.systemRecognitionRequest = nil
            await MainActor.run {
                self.setError(.systemAudioCaptureFailed(error.localizedDescription))
            }
        }
    }

    func stopSystemAudioRecording(preservePartials: Bool = false) async {
        await systemAudioCapture.stop()
        systemRecognitionRequest?.endAudio()
        systemRecognitionTask?.cancel()
        systemRecognitionRequest = nil
        systemRecognitionTask = nil

        await MainActor.run {
            if preservePartials {
                // Finalize partial system transcript as an entry before clearing
                if !self.partialOther.isEmpty {
                    let speaker = self.determineSpeaker(for: .systemAudio)
                    self.appendTranscriptEntry(self.partialOther, speaker: speaker)
                }
            }

            self.partialOther = ""
            self.partialOtherDeepgramId = nil
            self.partialOtherSpeaker = .speaker(0)
            self.systemTranscriptStartDate = nil

            self.isSystemAudioActive = false
            self.systemAudioHealth.selectedDisplayID = nil
            self.rebuildTranscript()
        }

        hasLoggedAudioFormat = false  // Reset for next session
        logDebug("System audio capture stopped")
    }

    private func appendSampleBuffer(_ sampleBuffer: CMSampleBuffer, to request: SFSpeechAudioBufferRecognitionRequest) {
        guard let pcmBuffer = convertSampleBuffer(sampleBuffer) else { return }
        request.append(pcmBuffer)
    }

    /// Logs system audio format details once per session to avoid log spam
    private func logAudioFormatOnce(_ asbd: AudioStreamBasicDescription, sampleCount: Int) {
        guard !hasLoggedAudioFormat else { return }
        hasLoggedAudioFormat = true

        let formatFlags = asbd.mFormatFlags
        let isFloat = (formatFlags & kAudioFormatFlagIsFloat) != 0
        let isInterleaved = (formatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        logDebug("""
            System audio format detected:
            - Sample Rate: \(asbd.mSampleRate) Hz
            - Channels: \(asbd.mChannelsPerFrame)
            - Bits Per Channel: \(asbd.mBitsPerChannel)
            - Is Float: \(isFloat)
            - Is Interleaved: \(isInterleaved)
            - Sample Count: \(sampleCount)
            """)
    }

    private func convertSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        // Get format description from sample buffer
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            logDebug("System audio: Failed to get format description from sample buffer")
            return nil
        }

        // Get the Audio Stream Basic Description for format logging
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            logDebug("System audio: Failed to get ASBD from format description")
            return nil
        }

        let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
        // Empty samples are normal when system audio is silent - don't log
        guard sampleCount > 0 else { return nil }

        // Log format details once for debugging
        logAudioFormatOnce(asbd.pointee, sampleCount: sampleCount)

        // Use AVAudioFormat(cmAudioFormatDescription:) - handles all format types including interleaved
        let audioFormat: AVAudioFormat
        do {
            audioFormat = try AVAudioFormat(cmAudioFormatDescription: formatDescription)
        } catch {
            logDebug("System audio: Failed to create AVAudioFormat from format description: \(error.localizedDescription)")
            return nil
        }

        // Create PCM buffer with the correct format
        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(sampleCount)
        ) else {
            logDebug("System audio: Failed to create PCM buffer (format: \(audioFormat.sampleRate)Hz, \(audioFormat.channelCount)ch, interleaved: \(audioFormat.isInterleaved))")
            return nil
        }

        pcmBuffer.frameLength = AVAudioFrameCount(sampleCount)

        // KEY FIX: Use Apple's API that handles interleaved formats correctly!
        // CMSampleBufferCopyPCMDataIntoAudioBufferList works with both interleaved and non-interleaved audio
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(sampleCount),
            into: pcmBuffer.mutableAudioBufferList
        )

        guard status == noErr else {
            logDebug("System audio: CMSampleBufferCopyPCMDataIntoAudioBufferList failed with status: \(status)")
            return nil
        }

        return pcmBuffer
    }
}

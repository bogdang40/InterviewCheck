import Foundation
import Speech

extension AudioCaptureService {
    func handleRecognitionResult(
        _ result: SFSpeechRecognitionResult?,
        error: Error?,
        source: AudioSource,
        captureToken: UInt64
    ) {
        DispatchQueue.main.async {
            guard self.isCaptureTokenActive(captureToken) else { return }
            if let error = error {
                self.logDebug("Recognition error (\(source.rawValue)): \(error.localizedDescription)")
            }

            guard self.shouldAcceptIncomingTranscripts() else { return }

            if let result = result {
                let text = result.bestTranscription.formattedString

                // Determine speaker using voice signature if available, otherwise fallback to source
                let speaker = self.determineSpeaker(for: source)

                if source == .microphone {
                    self.partialMe = text
                } else {
                    self.partialOther = text
                    self.partialOtherSpeaker = speaker
                }
                self.rebuildTranscript()

                if result.isFinal {
                    // Fallback: use source-based speaker
                    self.appendTranscriptEntry(text, speaker: speaker)

                    if source == .microphone {
                        self.partialMe = ""
                    } else {
                        self.partialOther = ""
                        self.partialOtherSpeaker = .speaker(0)
                    }
                    self.rebuildTranscript()
                }
            }

        }
    }

    /// Determine speaker label based on voice signature or fallback to source
    func determineSpeaker(for source: AudioSource) -> TranscriptSpeaker {
        // Fallback: mic = me, system = Speaker 1
        return source == .microphone ? .me : .speaker(0)
    }

    func handleDeepgramTranscript(
        _ segment: DeepgramTranscriptSegment,
        captureToken: UInt64
    ) {
        DispatchQueue.main.async {
            let tokenOK = self.isCaptureTokenActive(captureToken)
            let acceptOK = self.shouldAcceptIncomingTranscripts()
            if !tokenOK || !acceptOK {
                // #region agent log
                DebugNDJSONLogger.shared.log(
                    runId: self.ndjsonRunId,
                    hypothesisId: "H4",
                    location: "AudioCaptureService.handleDeepgramTranscript",
                    message: "deepgram_segment_dropped",
                    data: [
                        "tokenOK": tokenOK,
                        "acceptOK": acceptOK,
                        "captureState": self.captureState.displayName,
                        "desiredState": self.desiredState.displayName,
                        "mode": self.activeTranscriptionMode.displayName,
                        "isFinal": segment.isFinal,
                        "speaker": segment.speaker ?? -1,
                        "textLength": segment.text.count
                    ]
                )
                // #endregion
                return
            }

            // Map Deepgram speaker ID to TranscriptSpeaker using unified diarization
            // All speaker identification comes from Deepgram's acoustic analysis
            let speaker = self.speakerMapper.mapSpeaker(deepgramId: segment.speaker)
            if let deepgramId = segment.speaker {
                self.legacyLastSpeakerId = deepgramId
                self.legacyDiarizationLabelsSeen = true
                self.legacyDiarizationLastLabelTime = Date()
                self.legacySpeakerCount = self.speakerMapper.speakerCount
            }

            if segment.isFinal {
                // Final transcript - add to entries
                self.appendTranscriptEntry(
                    segment.text,
                    speaker: speaker,
                    deepgramSpeakerId: segment.speaker
                )

                // Clear partial (unified stream uses single partial)
                if speaker.isMe {
                    self.partialMe = ""
                    self.partialMeDeepgramId = nil
                } else {
                    self.partialOther = ""
                    self.partialOtherDeepgramId = nil
                    self.partialOtherSpeaker = .speaker(0)
                }
            } else {
                // Partial transcript - update preview based on speaker
                if speaker.isMe {
                    self.partialMe = segment.text
                    self.partialMeDeepgramId = segment.speaker
                } else {
                    self.partialOther = segment.text
                    self.partialOtherDeepgramId = segment.speaker
                    self.partialOtherSpeaker = speaker
                }
            }

            self.rebuildTranscript()
        }
    }

    func finalizeLegacyDeepgramPartials() {
        var appended = false

        let trimmedMe = partialMe.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMe.isEmpty {
            let speaker = speakerMapper.mapSpeaker(deepgramId: partialMeDeepgramId)
            appendTranscriptEntry(trimmedMe, speaker: speaker, deepgramSpeakerId: partialMeDeepgramId)
            appended = true
        }

        let trimmedOther = partialOther.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOther.isEmpty {
            let speaker = speakerMapper.mapSpeaker(deepgramId: partialOtherDeepgramId)
            appendTranscriptEntry(trimmedOther, speaker: speaker, deepgramSpeakerId: partialOtherDeepgramId)
            appended = true
        }

        partialMe = ""
        partialOther = ""
        partialMeDeepgramId = nil
        partialOtherDeepgramId = nil
        partialOtherSpeaker = .speaker(0)

        if appended {
            rebuildTranscript()
        }
    }
}

// MARK: - Debug helpers

private extension DeepgramConnectionState {
    var debugLabel: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .error(let message): return "error:\(message)"
        }
    }
}

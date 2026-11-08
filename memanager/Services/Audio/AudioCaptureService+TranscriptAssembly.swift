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
                    // For final results, use segment-based labeling if voice signature is active
                    if let labeler = self.transcriptionLabeler,
                       let voiceService = self.voiceSignatureService,
                       voiceService.isActive {
                        let segments = result.bestTranscription.segments
                        if source == .microphone && self.micStreamStartTime == 0 {
                            self.micStreamStartTime = self.inferStreamStartTime(
                                source: source,
                                segments: segments,
                                service: voiceService
                            )
                        } else if source == .systemAudio && self.systemStreamStartTime == 0 {
                            self.systemStreamStartTime = self.inferStreamStartTime(
                                source: source,
                                segments: segments,
                                service: voiceService
                            )
                        }

                        let streamStart = source == .microphone ? self.micStreamStartTime : self.systemStreamStartTime
                        let labeledEntries = labeler.labelFinal(segments: segments, source: source, streamStartTime: streamStart)
                        let mergedEntries = labeler.mergeAdjacentEntries(labeledEntries)

                        // Convert to TranscriptEntry (using SpeakerLabel -> TranscriptSpeaker)
                        for entry in mergedEntries {
                            let transcriptSpeaker: TranscriptSpeaker
                            if entry.label == .me {
                                transcriptSpeaker = .me
                            } else {
                                // For non-"me" speakers, use numbered speakers
                                transcriptSpeaker = .speaker(0)
                            }
                            self.appendTranscriptEntry(entry.text, speaker: transcriptSpeaker)
                        }
                    } else {
                        // Fallback: use source-based speaker
                        self.appendTranscriptEntry(text, speaker: speaker)
                    }

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
        // If voice signature is active, use current label
        if let service = voiceSignatureService, service.isActive {
            let label = service.currentLabel
            if label == .me {
                return .me
            } else {
                // For non-"me", use numbered speakers
                return .speaker(0)
            }
        }

        // Fallback: mic = me, system = Speaker 1
        return source == .microphone ? .me : .speaker(0)
    }

    private func inferStreamStartTime(
        source: AudioSource,
        segments: [SFTranscriptionSegment],
        service: VoiceSignatureRecognitionService
    ) -> TimeInterval {
        guard let latestScoreTimestamp = service.latestTimestamp(for: source),
              let lastSegment = segments.last else {
            return 0
        }

        let segmentEnd = lastSegment.timestamp + lastSegment.duration
        let inferredStart = latestScoreTimestamp - segmentEnd

        if inferredStart.isFinite, inferredStart >= 0, inferredStart < 10 {
            return inferredStart
        }
        return 0
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

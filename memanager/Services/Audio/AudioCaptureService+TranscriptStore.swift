import AVFoundation
import Combine
import Speech
import AppKit
import CoreMedia
import CoreAudio

extension AudioCaptureService {
    func clearTranscript() {
        restoredSessionTranscript = nil
        transcript = ""
        transcriptEntries = []
        partialMe = ""
        partialMeDeepgramId = nil
        partialOther = ""
        partialOtherDeepgramId = nil
        partialOtherSpeaker = .speaker(0)
        legacySpeakerCount = 0
        legacyLastSpeakerId = nil
        legacyDiarizationLabelsSeen = false
        legacyDiarizationLastLabelTime = nil
        speakerMapper.reset()
        transcriptMerger?.reset()
        transcriptMerger = nil
        resetTranscriptStartTimes()
        resetSystemAudioHealth()
        logDebug("Transcript cleared")
    }

    /// Rehydrate text only after the hardware state machine has fully stopped.
    /// A subsequent explicit restoredSession start keeps this prefix intact.
    @MainActor
    @discardableResult
    func restoreTranscriptForResume(_ text: String, entries: [TranscriptEntry]) -> Bool {
        guard captureState == .idle, desiredState == .idle,
              transitionTask == nil, !isRecording, !isEngineRunning else { return false }
        clearTranscript()
        restoredSessionTranscript = RestoredSessionTranscript(text: text, entries: entries)
        transcriptEntries = entries
        transcript = text
        return true
    }

    func shouldAcceptIncomingTranscripts() -> Bool {
        desiredState == .recording && (captureState == .recording || captureState == .starting)
    }

    /// Mark a Deepgram speaker ID as "me" (tap-to-identify).
    ///
    /// Call this when user taps a speaker bubble to identify themselves.
    /// Re-labels all historical and future entries from this speaker as "me".
    func markSpeakerAsMe(_ deepgramSpeakerId: Int) {
        // Update the mapper
        speakerMapper.setMeManually(deepgramSpeakerId)

        // Re-label historical entries from this speaker
        for i in transcriptEntries.indices {
            if transcriptEntries[i].deepgramSpeakerId == deepgramSpeakerId {
                transcriptEntries[i] = TranscriptEntry(
                    id: transcriptEntries[i].id,
                    speaker: .me,
                    text: transcriptEntries[i].text,
                    timestamp: transcriptEntries[i].timestamp,
                    deepgramSpeakerId: deepgramSpeakerId
                )
            }
        }

        rebuildTranscript()
        logDebug("Speaker \(deepgramSpeakerId) marked as 'me' - \(transcriptEntries.filter { $0.speaker.isMe }.count) entries updated")
    }

    /// Mark the most recently active diarized speaker as "me".
    /// Uses current Deepgram speaker if available, otherwise falls back to the latest known entry.
    func markCurrentSpeakerAsMe() {
        DispatchQueue.main.async { [weak self] in
            self?.markCurrentSpeakerAsMeOnMain()
        }
    }

    /// Public method to consolidate transcript entries.
    /// Call this before processing the transcript (e.g., before solve) to ensure clean entries.
    func consolidateEntries() {
        consolidateTranscriptEntries()
    }

    func appendTranscriptEntry(
        _ text: String,
        speaker: TranscriptSpeaker,
        deepgramSpeakerId: Int? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let lastIndex = transcriptEntries.indices.last,
           lastIndex >= (restoredSessionTranscript?.entries.count ?? 0),
           transcriptEntries[lastIndex].speaker == speaker {
            let lastEntry = transcriptEntries[lastIndex]
            let mergedText = lastEntry.text + " " + trimmed
            let mergedDeepgramId = lastEntry.deepgramSpeakerId ?? deepgramSpeakerId
            transcriptEntries[lastIndex] = TranscriptEntry(
                id: lastEntry.id,
                speaker: lastEntry.speaker,
                text: mergedText,
                timestamp: lastEntry.timestamp,
                deepgramSpeakerId: mergedDeepgramId
            )
        } else {
            let newEntry = TranscriptEntry(
                speaker: speaker,
                text: trimmed,
                deepgramSpeakerId: deepgramSpeakerId
            )
            transcriptEntries.append(newEntry)
            
        }
        // Persist each accepted segment. UI consolidation must not discard
        // subsequent words from the same speaker in Review or Summary.
        let sessionId = self.sessionIdentityProvider().uuidString
        let source = speaker == .me ? "microphone" : "system_audio"
        transcriptLogger.logTranscriptEntry(
            sessionId: sessionId,
            speaker: speaker.displayName,
            text: trimmed,
            source: source
        )
    }

    /// Consolidates transcript entries by merging consecutive entries with the same speaker.
    /// This prevents fragmentation caused by Apple's SFSpeechRecognizer segmenting continuous speech.
    func consolidateTranscriptEntries() {
        let restoredEntries = restoredSessionTranscript?.entries ?? []
        let liveEntries = Array(transcriptEntries.dropFirst(restoredEntries.count))
        guard liveEntries.count > 1 else { return }

        var consolidated: [TranscriptEntry] = []
        var currentEntry = liveEntries[0]

        for i in 1..<liveEntries.count {
            let next = liveEntries[i]
            if next.speaker == currentEntry.speaker {
                // Same speaker - merge text, preserve first entry's metadata
                currentEntry = TranscriptEntry(
                    id: currentEntry.id,
                    speaker: currentEntry.speaker,
                    text: currentEntry.text + " " + next.text,
                    timestamp: currentEntry.timestamp,
                    deepgramSpeakerId: currentEntry.deepgramSpeakerId
                )
            } else {
                // Different speaker - finalize current entry, start new one
                consolidated.append(currentEntry)
                currentEntry = next
            }
        }
        // Don't forget the last accumulated entry
        consolidated.append(currentEntry)

        transcriptEntries = restoredEntries + consolidated
        rebuildTranscript()
        logDebug("Consolidated entries: \(transcriptEntries.count) entries after merging")
    }

    func rebuildTranscript() {
        let restoredCount = restoredSessionTranscript?.entries.count ?? 0
        var lines = transcriptEntries.dropFirst(restoredCount).map { "\($0.speaker.displayName): \($0.text)" }
        if let restoredText = restoredSessionTranscript?.text, !restoredText.isEmpty {
            lines.insert(restoredText, at: 0)
        }

        if !partialMe.isEmpty {
            lines.append("Me: \(partialMe)")
        }
        if !partialOther.isEmpty {
            lines.append("\(partialOtherSpeaker.displayName): \(partialOther)")
        }

        transcript = lines.joined(separator: "\n")
    }

    func updatePartialsAfterManualSelection(_ deepgramId: Int) {
        // If the current partial belongs to the newly selected speaker, move it to "me"
        if partialOtherDeepgramId == deepgramId, !partialOther.isEmpty {
            partialMe = partialOther
            partialMeDeepgramId = partialOtherDeepgramId
            partialOther = ""
            partialOtherDeepgramId = nil
            partialOtherSpeaker = .speaker(0)
            rebuildTranscript()
        }
    }

    func markCurrentSpeakerAsMeOnMain() {
        guard isDeepgramActive, !useSourceBasedIdentification else {
            logDebug("Mark current speaker ignored (Deepgram inactive or source-based mode)")
            return
        }

        let candidateId =
            deepgramService?.currentSpeaker ??
            partialOtherDeepgramId ??
            partialMeDeepgramId ??
            transcriptEntries.last(where: { $0.deepgramSpeakerId != nil })?.deepgramSpeakerId

        guard let deepgramId = candidateId else {
            logDebug("No current speaker available to mark as 'me'")
            return
        }

        markSpeakerAsMe(deepgramId)
        updatePartialsAfterManualSelection(deepgramId)
    }

    /// Keep restored history ahead of entries produced by the current stream.
    func replaceLiveTranscriptEntries(_ entries: [TranscriptEntry]) {
        transcriptEntries = (restoredSessionTranscript?.entries ?? []) + entries
    }

    /// Sync merged entries from TranscriptMerger to main transcript state.
    func syncMergedEntries() {
        guard let merger = transcriptMerger else { return }

        DispatchQueue.main.async {
            guard self.transcriptMerger === merger else { return }
            let beforeCount = self.transcriptEntries.count
            self.replaceLiveTranscriptEntries(merger.mergedEntries)
            self.partialMe = merger.partialMic
            // For system partials, show the first one (could have multiple speakers)
            if let first = merger.partialSystemEntries.first {
                self.partialOther = first.text
                self.partialOtherSpeaker = first.speaker
                self.partialOtherDeepgramId = first.deepgramSpeakerId
            } else {
                self.partialOther = ""
                self.partialOtherSpeaker = .speaker(0)
                self.partialOtherDeepgramId = nil
            }
            self.rebuildTranscript()

            let now = Date().timeIntervalSince1970
            if now - self.lastNDJSONMergedSyncTime >= 1.0 || beforeCount != self.transcriptEntries.count {
                self.lastNDJSONMergedSyncTime = now
                let conflictStats = merger.conflictStatsSnapshot
                // #region agent log
                DebugNDJSONLogger.shared.log(
                    runId: self.ndjsonRunId,
                    hypothesisId: "H1",
                    location: "AudioCaptureService.syncMergedEntries",
                    message: "merged_entries_sync",
                    data: [
                        "mergedEntriesCount": self.transcriptEntries.count,
                        "partialMicLength": self.partialMe.count,
                        "partialSystemKeys": merger.partialSystem.keys.count,
                        "captureState": self.captureState.displayName,
                        "desiredState": self.desiredState.displayName,
                        "mode": self.activeTranscriptionMode.displayName,
                        "deepgramMicState": self.deepgramMicState.debugLabel,
                        "deepgramSystemState": self.deepgramSystemState.debugLabel,
                        "conflictMicSuppressed": conflictStats.micDuplicatesSuppressed,
                        "conflictSystemSuppressed": conflictStats.systemDuplicatesSuppressed,
                        "conflictRetroCorrections": conflictStats.retroactiveCorrections,
                        "conflictLastDecision": conflictStats.lastDecision
                    ]
                )
                // #endregion
            }
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

import Combine
import Foundation

extension TranscriptMerger {
    func processFinalSegment(
        text: String,
        speaker: TranscriptSpeaker,
        deepgramSpeakerId: Int?,
        timestamp: Date,
        confidence: Double?,
        source: TranscriptSourceKind,
        receivedAt: Date
    ) {
        let normalized = normalizeText(text)
        var telemetryEvents: [(String, [String: Any])] = []

        lock.lock()
        pruneRecentFinalSegmentsLocked(before: receivedAt.addingTimeInterval(-conflictTimeWindowSeconds))

        var shouldInsertIncoming = true

        if conflictResolutionEnabled, wordCount(normalized) >= minConflictWordCount,
           let conflict = findBestConflictLocked(
               incomingSource: source,
               incomingText: normalized,
               receivedAt: receivedAt
           ) {
            telemetryEvents.append((
                "transcript_conflict_detected",
                [
                    "incomingSource": source.label,
                    "existingSource": conflict.segment.source.label,
                    "similarity": conflict.similarity,
                    "incomingConfidence": confidence ?? -1,
                    "existingConfidence": conflict.segment.confidence ?? -1,
                    "incomingTextLength": text.count
                ]
            ))

            let decision = decideConflict(
                incomingSource: source,
                incomingConfidence: confidence,
                existingConfidence: conflict.segment.confidence
            )
            conflictStats.lastDecision = decision.label

            switch decision {
            case .keepMic:
                if source == .systemAudio {
                    shouldInsertIncoming = false
                    conflictStats.systemDuplicatesSuppressed += 1
                } else if removeEntryLocked(
                    id: conflict.segment.entryId,
                    expectedNormalizedText: conflict.segment.normalizedText
                ) {
                    removeRecentFinalLocked(id: conflict.segment.entryId)
                    conflictStats.retroactiveCorrections += 1
                    telemetryEvents.append((
                        "transcript_retroactive_correction_applied",
                        [
                            "keptSource": source.label,
                            "removedSource": conflict.segment.source.label,
                            "removedEntryId": conflict.segment.entryId.uuidString
                        ]
                    ))
                }

            case .keepSystem:
                if source == .microphone {
                    shouldInsertIncoming = false
                    conflictStats.micDuplicatesSuppressed += 1
                } else if removeEntryLocked(
                    id: conflict.segment.entryId,
                    expectedNormalizedText: conflict.segment.normalizedText
                ) {
                    removeRecentFinalLocked(id: conflict.segment.entryId)
                    conflictStats.retroactiveCorrections += 1
                    telemetryEvents.append((
                        "transcript_retroactive_correction_applied",
                        [
                            "keptSource": source.label,
                            "removedSource": conflict.segment.source.label,
                            "removedEntryId": conflict.segment.entryId.uuidString
                        ]
                    ))
                }


            }

            telemetryEvents.append((
                "transcript_conflict_resolved",
                [
                    "incomingSource": source.label,
                    "existingSource": conflict.segment.source.label,
                    "decision": decision.label,
                    "similarity": conflict.similarity,
                    "incomingConfidence": confidence ?? -1,
                    "existingConfidence": conflict.segment.confidence ?? -1
                ]
            ))
        }

        if shouldInsertIncoming {
            let entry = TranscriptEntry(
                speaker: speaker,
                text: text,
                timestamp: timestamp,
                deepgramSpeakerId: deepgramSpeakerId
            )
            insertSorted(entry)
            addRecentFinalLocked(RecentFinalSegment(
                entryId: entry.id,
                source: source,
                normalizedText: normalized,
                receivedAt: receivedAt,
                confidence: confidence
            ))
        }

        if source == .microphone {
            backingPartialMic = ""
        } else if let deepgramSpeakerId {
            backingPartialSystem.removeValue(forKey: deepgramSpeakerId)
        } else {
            backingPartialSystem.removeValue(forKey: unknownSpeakerKey)
        }

        let entriesSnapshot = backingEntries
        let partialSystemSnapshot = backingPartialSystem
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.mergedEntries = entriesSnapshot
            self?.partialSystem = partialSystemSnapshot
            if source == .microphone {
                self?.partialMic = ""
            }
        }

        emitConflictTelemetry(events: telemetryEvents)
    }

    func decideConflict(
        incomingSource: TranscriptSourceKind,
        incomingConfidence: Double?,
        existingConfidence: Double?
    ) -> TranscriptConflictDecision {
        let incoming = incomingConfidence ?? 0
        let existing = existingConfidence ?? 0

        switch incomingSource {
        case .microphone:
            if incoming > existing + confidenceDecisionDelta {
                return .keepMic
            }
            return .keepSystem
        case .systemAudio:
            if incoming + confidenceDecisionDelta < existing {
                return .keepMic
            }
            return .keepSystem
        }
    }

    // MARK: - Speaker Mapping

    func mappedSpeaker(for speakerId: Int?) -> (TranscriptSpeaker, Int?) {
        guard let speakerId else {
            return (.unknown, nil)
        }

        lock.lock()
        let displaySpeaker: TranscriptSpeaker
        if let existingNumber = speakerMapping[speakerId] {
            displaySpeaker = .speaker(existingNumber)
        } else {
            let newNumber = nextSpeakerNumber
            speakerMapping[speakerId] = newNumber
            nextSpeakerNumber += 1
            displaySpeaker = .speaker(newNumber)
        }
        lock.unlock()

        return (displaySpeaker, speakerId)
    }

    // MARK: - Private Methods

    func timestamp(from streamStart: Date?, startTime: Double) -> Date {
        guard let streamStart else { return Date() }
        return streamStart.addingTimeInterval(startTime)
    }

    /// Insert entry maintaining sorted order by timestamp
    /// MUST be called while holding lock
    func insertSorted(_ entry: TranscriptEntry) {
        let index = backingEntries.firstIndex { $0.timestamp > entry.timestamp } ?? backingEntries.count

        if let prevIndex = index > 0 ? index - 1 : nil,
           shouldConsolidate(backingEntries[prevIndex], entry) {
            let prev = backingEntries[prevIndex]
            let consolidated = TranscriptEntry(
                id: prev.id,
                speaker: prev.speaker,
                text: prev.text + " " + entry.text,
                timestamp: prev.timestamp,
                deepgramSpeakerId: prev.deepgramSpeakerId
            )
            backingEntries[prevIndex] = consolidated
        } else {
            backingEntries.insert(entry, at: index)
        }
    }

    /// Determine if two adjacent entries should be consolidated.
    func shouldConsolidate(_ prev: TranscriptEntry, _ next: TranscriptEntry) -> Bool {
        guard prev.speaker == next.speaker else { return false }
        let gap = next.timestamp.timeIntervalSince(prev.timestamp)
        return gap >= 0 && gap <= consolidationGapSeconds
    }

    // MARK: - Conflict Resolution Helpers
}

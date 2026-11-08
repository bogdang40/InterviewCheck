import Combine
import Foundation

extension TranscriptMerger {
    /// Reset all state for a new session
    func reset() {
        lock.lock()
        backingEntries = []
        backingPartialMic = ""
        backingPartialSystem = [:]
        speakerMapping = [:]
        nextSpeakerNumber = 0
        recentFinalSegments = []
        conflictStats = ConflictStats()
        lock.unlock()

        deduplicator.reset()

        DispatchQueue.main.async { [weak self] in
            self?.mergedEntries = []
            self?.partialMic = ""
            self?.partialSystem = [:]
        }
    }

    /// Clear partials without touching merged entries or speaker mapping
    func clearPartials() {
        lock.lock()
        backingPartialMic = ""
        backingPartialSystem = [:]
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.partialMic = ""
            self?.partialSystem = [:]
        }
    }

    /// Finalize partials into transcript entries, then clear partial buffers
    func finalizePartials() {
        lock.lock()
        let micText = backingPartialMic
        let systemPartials = backingPartialSystem
        let mapping = speakerMapping
        lock.unlock()

        var entriesToInsert: [TranscriptEntry] = []

        let trimmedMic = micText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMic.isEmpty {
            entriesToInsert.append(TranscriptEntry(
                speaker: .me,
                text: trimmedMic,
                timestamp: Date(),
                deepgramSpeakerId: nil
            ))
        }

        for (deepgramId, text) in systemPartials {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let speaker: TranscriptSpeaker
            if deepgramId == unknownSpeakerKey {
                speaker = .unknown
            } else if let speakerNum = mapping[deepgramId] {
                speaker = .speaker(speakerNum)
            } else {
                speaker = .unknown
            }
            entriesToInsert.append(TranscriptEntry(
                speaker: speaker,
                text: trimmed,
                timestamp: Date(),
                deepgramSpeakerId: deepgramId == unknownSpeakerKey ? nil : deepgramId
            ))
        }

        if !entriesToInsert.isEmpty {
            lock.lock()
            for entry in entriesToInsert {
                insertSorted(entry)
            }
            let entriesSnapshot = backingEntries
            lock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.mergedEntries = entriesSnapshot
            }
        }

        clearPartials()
    }

    /// Get current partial text for display (consolidated from all sources)
    /// Thread-safe: reads from backing storage under lock
    var currentPartials: [(speaker: TranscriptSpeaker, text: String)] {
        var result: [(speaker: TranscriptSpeaker, text: String)] = []

        lock.lock()
        let micText = backingPartialMic
        let systemPartials = backingPartialSystem
        let mapping = speakerMapping
        lock.unlock()

        if !micText.isEmpty {
            result.append((.me, micText))
        }

        for (deepgramId, text) in systemPartials {
            if deepgramId == unknownSpeakerKey {
                result.append((.unknown, text))
            } else if let speakerNum = mapping[deepgramId] {
                result.append((.speaker(speakerNum), text))
            } else {
                result.append((.unknown, text))
            }
        }

        return result
    }

    /// Get partial system entries with speaker mapping for UI
    /// Thread-safe: reads from backing storage under lock
    var partialSystemEntries: [(speaker: TranscriptSpeaker, text: String, deepgramSpeakerId: Int?)] {
        var result: [(speaker: TranscriptSpeaker, text: String, deepgramSpeakerId: Int?)] = []

        lock.lock()
        let systemPartials = backingPartialSystem
        let mapping = speakerMapping
        lock.unlock()

        for (deepgramId, text) in systemPartials {
            if deepgramId == unknownSpeakerKey {
                result.append((.unknown, text, nil))
            } else if let speakerNum = mapping[deepgramId] {
                result.append((.speaker(speakerNum), text, deepgramId))
            } else {
                result.append((.unknown, text, nil))
            }
        }

        return result
    }

    // MARK: - Final Segment Processing
}

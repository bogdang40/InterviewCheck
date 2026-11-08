import Foundation
import Speech

// MARK: - Voice Labeled Transcript Entry

/// Extended transcript entry with voice signature labeling
struct VoiceLabeledTranscriptEntry: Identifiable, Codable {
    let id: UUID
    let source: AudioSource
    let label: SpeakerLabel
    let text: String
    let timestamp: Date
    let confidence: Float
    let timeRangeStart: TimeInterval?
    let timeRangeEnd: TimeInterval?

    var timeRange: ClosedRange<TimeInterval>? {
        guard let start = timeRangeStart, let end = timeRangeEnd else { return nil }
        return start...end
    }

    init(
        id: UUID = UUID(),
        source: AudioSource,
        label: SpeakerLabel,
        text: String,
        timestamp: Date = Date(),
        confidence: Float = 0.0,
        timeRangeStart: TimeInterval? = nil,
        timeRangeEnd: TimeInterval? = nil
    ) {
        self.id = id
        self.source = source
        self.label = label
        self.text = text
        self.timestamp = timestamp
        self.confidence = confidence
        self.timeRangeStart = timeRangeStart
        self.timeRangeEnd = timeRangeEnd
    }
}

// MARK: - Transcription Labeler

/// Assigns speaker labels to transcript entries using recognition scores
final class TranscriptionLabeler {

    // MARK: - Dependencies

    private weak var recognitionService: VoiceSignatureRecognitionService?
    private let config: SpeakerRecognitionConfig

    // MARK: - Initialization

    init(recognitionService: VoiceSignatureRecognitionService?, config: SpeakerRecognitionConfig = .default) {
        self.recognitionService = recognitionService
        self.config = config
    }

    // MARK: - Public Interface

    /// Label a partial transcription result (uses current speaker state)
    func labelPartial(
        text: String,
        source: AudioSource
    ) -> VoiceLabeledTranscriptEntry {
        guard let service = recognitionService, service.isActive else {
            // Fallback to source-based labeling
            return labelBySource(text: text, source: source)
        }

        // For partials, use current speaker state
        let label = service.currentLabel
        let confidence = service.smoothedScore

        return VoiceLabeledTranscriptEntry(
            source: source,
            label: label,
            text: text,
            confidence: confidence,
            timeRangeStart: nil,
            timeRangeEnd: nil
        )
    }

    /// Label a final transcription result using segment timestamps
    func labelFinal(
        segments: [SFTranscriptionSegment],
        source: AudioSource,
        streamStartTime: TimeInterval
    ) -> [VoiceLabeledTranscriptEntry] {
        guard let service = recognitionService, service.isActive else {
            // Fallback to source-based labeling for all segments
            return segments.map { segment in
                labelBySource(text: segment.substring, source: source)
            }
        }

        return segments.map { segment in
            let segmentStart = streamStartTime + segment.timestamp
            let segmentEnd = segmentStart + segment.duration

            // Query average score over segment time range
            let avgScore = scoreWithFallback(
                service: service,
                segmentStart: segmentStart,
                segmentEnd: segmentEnd
            )

            // Determine label based on average score
            let label: SpeakerLabel
            let confidence: Float

            if let score = avgScore {
                confidence = score
                if score >= config.thresholdEnterMe {
                    label = .me
                } else if score < config.thresholdExitMe {
                    label = .other
                } else {
                    label = .unknown
                }
            } else {
                // No scores available for this time range - use current state
                label = service.currentLabel
                confidence = service.smoothedScore
            }

            return VoiceLabeledTranscriptEntry(
                source: source,
                label: label,
                text: segment.substring,
                confidence: confidence,
                timeRangeStart: segmentStart,
                timeRangeEnd: segmentEnd
            )
        }
    }

    /// Convenience: Label from source-based capture when voice signature is disabled
    func labelBySource(text: String, source: AudioSource) -> VoiceLabeledTranscriptEntry {
        let label: SpeakerLabel = source == .microphone ? .me : .other
        return VoiceLabeledTranscriptEntry(
            source: source,
            label: label,
            text: text,
            confidence: 1.0,
            timeRangeStart: nil,
            timeRangeEnd: nil
        )
    }

    /// Merge adjacent entries with same label (for cleaner transcript display)
    func mergeAdjacentEntries(_ entries: [VoiceLabeledTranscriptEntry]) -> [VoiceLabeledTranscriptEntry] {
        guard !entries.isEmpty else { return [] }

        var merged: [VoiceLabeledTranscriptEntry] = []
        var currentEntry = entries[0]

        for entry in entries.dropFirst() {
            if entry.label == currentEntry.label && entry.source == currentEntry.source {
                // Merge: combine text and extend time range
                let mergedTimeStart = currentEntry.timeRangeStart ?? entry.timeRangeStart
                let mergedTimeEnd = entry.timeRangeEnd ?? currentEntry.timeRangeEnd
                let mergedConfidence = (currentEntry.confidence + entry.confidence) / 2.0

                currentEntry = VoiceLabeledTranscriptEntry(
                    id: currentEntry.id,  // Keep original ID
                    source: currentEntry.source,
                    label: currentEntry.label,
                    text: currentEntry.text + " " + entry.text,
                    timestamp: currentEntry.timestamp,
                    confidence: mergedConfidence,
                    timeRangeStart: mergedTimeStart,
                    timeRangeEnd: mergedTimeEnd
                )
            } else {
                // Different label/source - save current and start new
                merged.append(currentEntry)
                currentEntry = entry
            }
        }

        // Don't forget the last entry
        merged.append(currentEntry)

        return merged
    }

    private func scoreWithFallback(
        service: VoiceSignatureRecognitionService,
        segmentStart: TimeInterval,
        segmentEnd: TimeInterval
    ) -> Float? {
        if let directScore = service.averageScore(from: segmentStart, to: segmentEnd) {
            return directScore
        }

        // Speech finalization can lag behind score emission; expand lookup window progressively.
        for padding in [0.25, 0.5, 1.0] {
            let expandedStart = max(0, segmentStart - padding)
            let expandedEnd = segmentEnd + padding
            if let expandedScore = service.averageScore(from: expandedStart, to: expandedEnd) {
                return expandedScore
            }
        }

        return service.recentAverageScore(windowSeconds: 1.5)
    }
}

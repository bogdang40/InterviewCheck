import Combine
import Foundation

// MARK: - Transcript Merger

/// Merges transcripts from microphone and system audio into a unified timeline.
///
/// Source-based speaker identification:
/// - Microphone transcripts are always labeled as "me"
/// - System audio transcripts use Deepgram speaker IDs for numbered speakers
///
/// Entries are sorted by start time and consecutive same-speaker entries are consolidated.
///
/// Echo De-duplication:
/// - Uses TranscriptDeduplicator to filter duplicate transcripts caused by:
///   - Mic picking up speaker playback (other person's audio from speakers)
///   - System audio picking up room echo (user's voice reverberating)
///
/// Thread Safety:
/// - Internal state (_entries, _partialMic, _partialSystem) protected by lock
/// - @Published properties ONLY updated on main thread
/// - Public methods callable from any thread
final class TranscriptMerger: ObservableObject {

    // MARK: - Published State (Main Thread Only)

    /// Merged transcript entries, sorted by timestamp
    @Published var mergedEntries: [TranscriptEntry] = []

    /// Current partial transcript from microphone (always "me")
    @Published var partialMic: String = ""

    /// Current partial transcripts from system audio, keyed by Deepgram speaker ID
    @Published var partialSystem: [Int: String] = [:]

    // MARK: - Thread-Safe Backing Storage

    /// Internal entries storage - access only under lock
    var backingEntries: [TranscriptEntry] = []

    /// Internal partial mic storage - access only under lock
    var backingPartialMic: String = ""

    /// Internal partial system storage - access only under lock
    var backingPartialSystem: [Int: String] = [:]

    // MARK: - Private Properties

    let lock = NSLock()

    /// Maps Deepgram speaker IDs to sequential display numbers (0-based for TranscriptSpeaker)
    var speakerMapping: [Int: Int] = [:]
    var nextSpeakerNumber: Int = 0
    let unknownSpeakerKey = Int.min

    /// Echo de-duplication service
    let deduplicator = TranscriptDeduplicator()

    /// Secondary cross-stream conflict resolver (order-insensitive, supports retroactive correction)
    var recentFinalSegments: [RecentFinalSegment] = []
    let maxRecentFinalSegments = 40
    var conflictResolutionEnabled = true
    var conflictSimilarityThreshold: Double = 0.62
    var conflictTimeWindowSeconds: TimeInterval = 2.8
    let confidenceDecisionDelta: Double = 0.10
    let consolidationGapSeconds: TimeInterval = 2.0
    let minConflictWordCount = 3

    struct ConflictStats {
        var micDuplicatesSuppressed: Int = 0
        var systemDuplicatesSuppressed: Int = 0
        var retroactiveCorrections: Int = 0
        var lastDecision: String = "none"
    }
    var conflictStats = ConflictStats()

    /// AudioCaptureService can subscribe to structured conflict telemetry for NDJSON logging.
    var onConflictTelemetry: ((String, [String: Any]) -> Void)?

    // MARK: - Initialization

    init() {}

    // MARK: - Echo Filter Configuration

    /// Configure the echo de-duplication filter
    func configureEchoFilter(enabled: Bool, threshold: Double, timeWindow: Double) {
        deduplicator.configure(enabled: enabled, threshold: threshold, timeWindow: timeWindow)

        // Keep conflict resolver aligned with user settings, while preserving a stable floor.
        lock.withLock {
            conflictResolutionEnabled = enabled
            conflictSimilarityThreshold = max(0.5, min(0.95, threshold))
            conflictTimeWindowSeconds = max(1.0, min(5.0, timeWindow))
        }
    }

    /// Get echo filter statistics for debugging
    var echoFilterStats: (micFiltered: Int, systemFiltered: Int) {
        deduplicator.stats
    }

    /// Stats for cross-stream conflict arbitration.
    var conflictStatsSnapshot: TranscriptConflictStatsSnapshot {
        lock.lock()
        let snapshot = TranscriptConflictStatsSnapshot(
            micDuplicatesSuppressed: conflictStats.micDuplicatesSuppressed,
            systemDuplicatesSuppressed: conflictStats.systemDuplicatesSuppressed,
            retroactiveCorrections: conflictStats.retroactiveCorrections,
            lastDecision: conflictStats.lastDecision
        )
        lock.unlock()
        return snapshot
    }

    /// Called when system stream reconnects so old system history doesn't pollute new conflict checks.
    func beginSystemStreamEpoch(resetPartials: Bool) {
        var shouldPublishPartials = false
        var remainingRecentCount = 0

        lock.lock()
        recentFinalSegments.removeAll { $0.source == .systemAudio }
        conflictStats.lastDecision = "epoch_reset_system"
        remainingRecentCount = recentFinalSegments.count
        if resetPartials {
            backingPartialSystem = [:]
            shouldPublishPartials = true
        }
        lock.unlock()
        deduplicator.reset()

        emitConflictTelemetry(event: "transcript_epoch_reset_system", data: [
            "resetPartials": resetPartials,
            "recentFinalCount": remainingRecentCount
        ])

        if shouldPublishPartials {
            DispatchQueue.main.async { [weak self] in
                self?.partialSystem = [:]
            }
        }
    }

    // MARK: - Public Interface

    /// Append a microphone transcript segment (always labeled as "me")
    func appendMicTranscript(
        _ segment: DeepgramTranscriptSegment,
        streamStart: Date?,
        receivedAt: Date = Date()
    ) {
        let segmentTimestamp = timestamp(from: streamStart, startTime: segment.startTime)

        if segment.isFinal {
            if deduplicator.isMicEcho(text: segment.text, timestamp: segmentTimestamp) {
                lock.lock()
                backingPartialMic = ""
                conflictStats.micDuplicatesSuppressed += 1
                conflictStats.lastDecision = TranscriptConflictDecision.keepSystem.label
                lock.unlock()

                emitConflictTelemetry(event: "transcript_conflict_resolved", data: [
                    "source": TranscriptSourceKind.microphone.label,
                    "decision": TranscriptConflictDecision.keepSystem.label,
                    "reason": "echo_filter"
                ])

                DispatchQueue.main.async { [weak self] in
                    self?.partialMic = ""
                }
                return
            }

            processFinalSegment(
                text: segment.text,
                speaker: .me,
                deepgramSpeakerId: nil,
                timestamp: segmentTimestamp,
                confidence: segment.confidence,
                source: .microphone,
                receivedAt: receivedAt
            )

            DispatchQueue.main.async { [weak self] in
                self?.partialMic = ""
            }
        } else {
            lock.lock()
            backingPartialMic = segment.text
            lock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.partialMic = segment.text
            }
        }
    }

    /// Append a system audio transcript segment (uses Deepgram diarization)
    func appendSystemTranscript(
        _ segment: DeepgramTranscriptSegment,
        streamStart: Date?,
        receivedAt: Date = Date()
    ) {
        let segmentTimestamp = timestamp(from: streamStart, startTime: segment.startTime)

        if segment.isFinal {
            if deduplicator.isSystemEcho(text: segment.text, timestamp: segmentTimestamp) {
                lock.lock()
                if let deepgramId = segment.speaker {
                    backingPartialSystem.removeValue(forKey: deepgramId)
                } else {
                    backingPartialSystem.removeValue(forKey: unknownSpeakerKey)
                }
                let partialSystemSnapshot = backingPartialSystem
                conflictStats.systemDuplicatesSuppressed += 1
                conflictStats.lastDecision = TranscriptConflictDecision.keepMic.label
                lock.unlock()

                emitConflictTelemetry(event: "transcript_conflict_resolved", data: [
                    "source": TranscriptSourceKind.systemAudio.label,
                    "decision": TranscriptConflictDecision.keepMic.label,
                    "reason": "echo_filter"
                ])

                DispatchQueue.main.async { [weak self] in
                    self?.partialSystem = partialSystemSnapshot
                }
                return
            }

            let (displaySpeaker, deepgramId) = mappedSpeaker(for: segment.speaker)

            processFinalSegment(
                text: segment.text,
                speaker: displaySpeaker,
                deepgramSpeakerId: deepgramId,
                timestamp: segmentTimestamp,
                confidence: segment.confidence,
                source: .systemAudio,
                receivedAt: receivedAt
            )

            lock.lock()
            if let deepgramId {
                backingPartialSystem.removeValue(forKey: deepgramId)
            } else {
                backingPartialSystem.removeValue(forKey: unknownSpeakerKey)
            }
            let partialSystemSnapshot = backingPartialSystem
            lock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.partialSystem = partialSystemSnapshot
            }
        } else {
            let deepgramId = segment.speaker ?? unknownSpeakerKey

            // Ensure mapping gets created for partial UI continuity.
            if segment.speaker != nil {
                _ = mappedSpeaker(for: segment.speaker)
            }

            lock.lock()
            backingPartialSystem[deepgramId] = segment.text
            let partialSystemSnapshot = backingPartialSystem
            lock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.partialSystem = partialSystemSnapshot
            }
        }
    }

}

// MARK: - Convenience Extensions

extension TranscriptMerger {
    /// Check if there are any entries (thread-safe)
    var hasEntries: Bool {
        lock.lock()
        let hasAny = !backingEntries.isEmpty
        lock.unlock()
        return hasAny
    }

    /// Get count of unique speakers from system audio (thread-safe)
    var systemSpeakerCount: Int {
        lock.lock()
        let count = speakerMapping.count
        lock.unlock()
        return count
    }

    /// Full transcript text (all entries concatenated) (thread-safe)
    var fullTranscript: String {
        lock.lock()
        let entries = backingEntries
        lock.unlock()

        return entries.map { entry in
            let prefix = entry.speaker.isMe ? "Me: " : "\(entry.speaker.displayName): "
            return prefix + entry.text
        }.joined(separator: "\n")
    }
}

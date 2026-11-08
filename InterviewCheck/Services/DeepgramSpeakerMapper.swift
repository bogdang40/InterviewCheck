import Foundation

/// Maps Deepgram speaker IDs to TranscriptSpeaker values with manual "me" selection.
///
/// With unified audio stream architecture:
/// - All speakers are initially numbered sequentially (Speaker 1, 2, 3...)
/// - User can manually tap to identify which speaker is "me"
/// - Once "me" is identified, that speaker's entries are re-labeled
///
/// Thread-safe via NSLock for concurrent audio processing.
final class DeepgramSpeakerMapper {

    // MARK: - Speaker Mapping State

    /// Maps Deepgram speaker ID -> display number (1-based)
    private var speakerMapping: [Int: Int] = [:]

    /// Next available speaker number for new speakers
    private var nextSpeakerNumber: Int = 1

    /// Deepgram speaker ID that user has identified as "me"
    private var meSpeakerId: Int?

    // MARK: - Thread Safety

    private let lock = NSLock()

    // MARK: - Public Interface

    /// Map a Deepgram speaker ID to TranscriptSpeaker.
    ///
    /// - Parameter deepgramId: Speaker ID from Deepgram diarization
    /// - Returns: Mapped TranscriptSpeaker value
    func mapSpeaker(deepgramId: Int?) -> TranscriptSpeaker {
        lock.lock()
        defer { lock.unlock() }

        guard let id = deepgramId else {
            return .unknown
        }

        // Check if this speaker is manually identified as "me"
        if id == meSpeakerId {
            return .me
        }

        // Get or create speaker number mapping
        if let existingNumber = speakerMapping[id] {
            return .speaker(existingNumber - 1)  // 0-indexed for display
        }

        // New speaker - assign next number
        let assignedNumber = nextSpeakerNumber
        speakerMapping[id] = assignedNumber
        nextSpeakerNumber += 1

        logDebug("Mapped speaker \(id) -> Speaker \(assignedNumber)")
        return .speaker(assignedNumber - 1)
    }

    /// Manually mark a Deepgram speaker ID as "me".
    ///
    /// Call this when user taps a speaker bubble to identify themselves.
    /// All future and historical entries from this speaker will be labeled "me".
    ///
    /// - Parameter deepgramId: The Deepgram speaker ID to mark as "me"
    func setMeManually(_ deepgramId: Int) {
        lock.lock()
        defer { lock.unlock() }

        meSpeakerId = deepgramId
        logDebug("Manual selection: Deepgram speaker \(deepgramId) = Me")
    }

    /// Clear the "me" identification.
    ///
    /// Call this to undo manual speaker selection.
    func clearMeSelection() {
        lock.lock()
        meSpeakerId = nil
        lock.unlock()
        logDebug("Cleared 'me' selection")
    }

    /// Reset all state for a new session.
    ///
    /// Call this when:
    /// - Session starts
    /// - Transcript is cleared
    /// - User explicitly resets speaker mappings
    func reset() {
        lock.lock()
        defer { lock.unlock() }

        speakerMapping.removeAll()
        nextSpeakerNumber = 1
        meSpeakerId = nil

        logDebug("Speaker mapper reset")
    }

    // MARK: - Query Methods

    /// Get the current "me" speaker ID (for re-labeling historical entries)
    var currentMeSpeakerId: Int? {
        lock.lock()
        defer { lock.unlock() }
        return meSpeakerId
    }

    /// Get the display number for a Deepgram speaker ID (1-based)
    func displayNumber(for deepgramId: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return speakerMapping[deepgramId]
    }

    /// Get the number of unique speakers detected
    var speakerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return speakerMapping.count
    }

    /// Get all speaker mappings (for debugging)
    var allMappings: [Int: Int] {
        lock.lock()
        defer { lock.unlock() }
        return speakerMapping
    }

    // MARK: - Debug Logging

    private func logDebug(_ message: String) {
        #if DEBUG
        print("[SpeakerMapper] \(message)")
        #endif
    }
}

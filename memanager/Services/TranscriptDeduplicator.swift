import Foundation

/// Detects and filters duplicate transcriptions between microphone and system audio streams.
///
/// When using dual-stream transcription, echo can cause the same speech to be
/// transcribed from both sources:
/// - Mic picks up speaker playback (other person's audio from speakers)
/// - System audio picks up room echo (user's voice reverberating)
///
/// This service uses text similarity and timing to detect and filter these duplicates.
final class TranscriptDeduplicator {
    
    // MARK: - Configuration
    
    /// Time window in seconds for considering segments as potential duplicates
    var timeWindowSeconds: Double = 3.0
    
    /// Minimum word similarity ratio (0.0-1.0) to consider as duplicate
    var similarityThreshold: Double = 0.6
    
    /// Whether echo filtering is enabled
    var isEnabled: Bool = true
    
    /// Minimum word count to apply deduplication (very short phrases are kept)
    private let minWordCount = 3
    
    // MARK: - Segment Buffers
    
    /// Recent mic segments for comparison
    private var recentMicSegments: [BufferedSegment] = []
    
    /// Recent system segments for comparison
    private var recentSystemSegments: [BufferedSegment] = []
    
    /// Maximum number of segments to keep in buffer
    private let maxBufferSize = 20
    
    // MARK: - Thread Safety
    
    private let lock = NSLock()
    
    // MARK: - Statistics (for debugging)
    
    private(set) var micEchoesFiltered: Int = 0
    private(set) var systemEchoesFiltered: Int = 0
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Public Interface
    
    /// Check if a microphone segment is likely echo from system audio (speaker playback).
    ///
    /// Call this before adding a mic transcript to check if it's actually
    /// the other person's voice being played through speakers.
    ///
    /// - Parameters:
    ///   - text: The transcribed text from microphone
    ///   - timestamp: When the segment was transcribed
    /// - Returns: True if this appears to be echo and should be filtered
    func isMicEcho(text: String, timestamp: Date) -> Bool {
        guard isEnabled else { return false }
        
        let normalized = normalizeText(text)
        guard wordCount(normalized) >= minWordCount else { return false }
        
        lock.lock()
        defer { lock.unlock() }
        
        // Clean old segments
        pruneOldSegments(before: timestamp.addingTimeInterval(-timeWindowSeconds))
        
        // Check against recent system segments
        for sysSegment in recentSystemSegments {
            let timeDiff = abs(timestamp.timeIntervalSince(sysSegment.timestamp))
            
            // Must be within time window
            guard timeDiff <= timeWindowSeconds else { continue }
            
            let similarity = wordSimilarity(normalized, sysSegment.normalizedText)
            
            if similarity >= similarityThreshold {
                // This mic transcript matches recent system audio
                // If system came first, mic is likely speaker playback echo
                if sysSegment.timestamp < timestamp {
                    micEchoesFiltered += 1
                    logDebug("Filtered mic echo: '\(text.prefix(50))...' (similarity: \(String(format: "%.2f", similarity)), delay: \(String(format: "%.2f", timeDiff))s)")
                    return true
                }
            }
        }
        
        // Not echo - add to buffer for future comparisons
        addMicSegment(text: text, normalized: normalized, timestamp: timestamp)
        return false
    }
    
    /// Check if a system audio segment is likely room echo of the user's voice.
    ///
    /// Call this before adding a system transcript to check if it's actually
    /// the user's voice echoing through the room.
    ///
    /// - Parameters:
    ///   - text: The transcribed text from system audio
    ///   - timestamp: When the segment was transcribed
    /// - Returns: True if this appears to be echo and should be filtered
    func isSystemEcho(text: String, timestamp: Date) -> Bool {
        guard isEnabled else { return false }
        
        let normalized = normalizeText(text)
        guard wordCount(normalized) >= minWordCount else { return false }
        
        lock.lock()
        defer { lock.unlock() }
        
        // Clean old segments
        pruneOldSegments(before: timestamp.addingTimeInterval(-timeWindowSeconds))
        
        // Check against recent mic segments
        for micSegment in recentMicSegments {
            let timeDiff = abs(timestamp.timeIntervalSince(micSegment.timestamp))
            
            // Must be within time window
            guard timeDiff <= timeWindowSeconds else { continue }
            
            let similarity = wordSimilarity(normalized, micSegment.normalizedText)
            
            if similarity >= similarityThreshold {
                // This system transcript matches recent mic audio
                // If mic came first, system is likely room echo
                if micSegment.timestamp < timestamp {
                    systemEchoesFiltered += 1
                    logDebug("Filtered system echo: '\(text.prefix(50))...' (similarity: \(String(format: "%.2f", similarity)), delay: \(String(format: "%.2f", timeDiff))s)")
                    return true
                }
            }
        }
        
        // Not echo - add to buffer for future comparisons
        addSystemSegment(text: text, normalized: normalized, timestamp: timestamp)
        return false
    }
    
    /// Record a mic segment without checking (for when segment is already accepted)
    func recordMicSegment(text: String, timestamp: Date) {
        guard isEnabled else { return }
        let normalized = normalizeText(text)
        guard wordCount(normalized) >= minWordCount else { return }
        
        lock.lock()
        addMicSegment(text: text, normalized: normalized, timestamp: timestamp)
        lock.unlock()
    }
    
    /// Record a system segment without checking (for when segment is already accepted)
    func recordSystemSegment(text: String, timestamp: Date) {
        guard isEnabled else { return }
        let normalized = normalizeText(text)
        guard wordCount(normalized) >= minWordCount else { return }
        
        lock.lock()
        addSystemSegment(text: text, normalized: normalized, timestamp: timestamp)
        lock.unlock()
    }
    
    /// Reset all state for a new session
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        recentMicSegments.removeAll()
        recentSystemSegments.removeAll()
        micEchoesFiltered = 0
        systemEchoesFiltered = 0
        
        logDebug("Deduplicator reset")
    }
    
    /// Get statistics for debugging
    var stats: (micFiltered: Int, systemFiltered: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (micEchoesFiltered, systemEchoesFiltered)
    }
    
    // MARK: - Private Methods
    
    /// Buffered segment for comparison
    private struct BufferedSegment {
        let originalText: String
        let normalizedText: String
        let timestamp: Date
    }
    
    private func addMicSegment(text: String, normalized: String, timestamp: Date) {
        recentMicSegments.append(BufferedSegment(
            originalText: text,
            normalizedText: normalized,
            timestamp: timestamp
        ))
        
        // Limit buffer size
        if recentMicSegments.count > maxBufferSize {
            recentMicSegments.removeFirst()
        }
    }
    
    private func addSystemSegment(text: String, normalized: String, timestamp: Date) {
        recentSystemSegments.append(BufferedSegment(
            originalText: text,
            normalizedText: normalized,
            timestamp: timestamp
        ))
        
        // Limit buffer size
        if recentSystemSegments.count > maxBufferSize {
            recentSystemSegments.removeFirst()
        }
    }
    
    private func pruneOldSegments(before cutoff: Date) {
        recentMicSegments.removeAll { $0.timestamp < cutoff }
        recentSystemSegments.removeAll { $0.timestamp < cutoff }
    }
    
    // MARK: - Text Processing
    
    /// Normalize text for comparison by lowercasing and removing punctuation
    private func normalizeText(_ text: String) -> String {
        let lowercased = text.lowercased()
        
        // Remove common punctuation but keep spaces
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let filtered = lowercased.unicodeScalars.filter { allowed.contains($0) }
        
        return String(String.UnicodeScalarView(filtered))
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
    
    /// Count words in normalized text
    private func wordCount(_ normalizedText: String) -> Int {
        normalizedText.split(separator: " ").count
    }
    
    /// Calculate word-level Jaccard similarity between two texts
    ///
    /// Jaccard similarity = |intersection| / |union|
    /// Returns 0.0 to 1.0 where 1.0 is identical
    private func wordSimilarity(_ text1: String, _ text2: String) -> Double {
        let words1 = Set(text1.split(separator: " ").map { String($0) })
        let words2 = Set(text2.split(separator: " ").map { String($0) })
        
        guard !words1.isEmpty || !words2.isEmpty else { return 0.0 }
        
        let intersection = words1.intersection(words2).count
        let union = words1.union(words2).count
        
        return Double(intersection) / Double(max(union, 1))
    }
    
    // MARK: - Debug Logging
    
    private func logDebug(_ message: String) {
        #if DEBUG
        print("[TranscriptDedup] \(message)")
        #endif
    }
}

// MARK: - Convenience Extensions

extension TranscriptDeduplicator {
    /// Configure from VoiceSignatureStore settings
    func configure(enabled: Bool, threshold: Double, timeWindow: Double) {
        isEnabled = enabled
        similarityThreshold = max(0.3, min(0.95, threshold))
        timeWindowSeconds = max(0.5, min(5.0, timeWindow))
        
        logDebug("Configured: enabled=\(enabled), threshold=\(threshold), window=\(timeWindow)s")
    }
}

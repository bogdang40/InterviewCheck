import Combine
import Foundation

// MARK: - Conflict Telemetry

enum TranscriptSourceKind {
    case microphone
    case systemAudio

    var label: String {
        switch self {
        case .microphone:
            return "mic"
        case .systemAudio:
            return "system"
        }
    }
}

enum TranscriptConflictDecision {
    case keepMic
    case keepSystem

    var label: String {
        switch self {
        case .keepMic:
            return "keep_mic"
        case .keepSystem:
            return "keep_system"
        }
    }
}

struct TranscriptConflictStatsSnapshot {
    let micDuplicatesSuppressed: Int
    let systemDuplicatesSuppressed: Int
    let retroactiveCorrections: Int
    let lastDecision: String
}

struct RecentFinalSegment {
    let entryId: UUID
    let source: TranscriptSourceKind
    let normalizedText: String
    let receivedAt: Date
    let confidence: Double?
}


extension TranscriptMerger {
    func findBestConflictLocked(
        incomingSource: TranscriptSourceKind,
        incomingText: String,
        receivedAt: Date
    ) -> (segment: RecentFinalSegment, similarity: Double)? {
        var bestMatch: RecentFinalSegment?
        var bestSimilarity: Double = 0

        for segment in recentFinalSegments where segment.source != incomingSource {
            let timeDelta = abs(receivedAt.timeIntervalSince(segment.receivedAt))
            guard timeDelta <= conflictTimeWindowSeconds else { continue }

            let similarity = wordSimilarity(incomingText, segment.normalizedText)
            if similarity > bestSimilarity {
                bestSimilarity = similarity
                bestMatch = segment
            }
        }

        guard let bestMatch, bestSimilarity >= conflictSimilarityThreshold else {
            return nil
        }

        return (bestMatch, bestSimilarity)
    }

    func addRecentFinalLocked(_ segment: RecentFinalSegment) {
        recentFinalSegments.append(segment)
        if recentFinalSegments.count > maxRecentFinalSegments {
            recentFinalSegments.removeFirst(recentFinalSegments.count - maxRecentFinalSegments)
        }
    }

    func pruneRecentFinalSegmentsLocked(before cutoff: Date) {
        recentFinalSegments.removeAll { $0.receivedAt < cutoff }
    }

    func removeRecentFinalLocked(id: UUID) {
        recentFinalSegments.removeAll { $0.entryId == id }
    }

    func removeEntryLocked(id: UUID, expectedNormalizedText: String) -> Bool {
        guard let index = backingEntries.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let normalizedEntry = normalizeText(backingEntries[index].text)
        guard normalizedEntry == expectedNormalizedText else {
            return false
        }
        backingEntries.remove(at: index)
        return true
    }

    func normalizeText(_ text: String) -> String {
        let lowercased = text.lowercased()
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let filtered = lowercased.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(filtered))
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func wordCount(_ normalizedText: String) -> Int {
        normalizedText.split(separator: " ").count
    }

    func wordSimilarity(_ text1: String, _ text2: String) -> Double {
        let words1 = Set(text1.split(separator: " ").map(String.init))
        let words2 = Set(text2.split(separator: " ").map(String.init))

        guard !words1.isEmpty || !words2.isEmpty else {
            return 0
        }

        let intersection = words1.intersection(words2).count
        let union = words1.union(words2).count
        return Double(intersection) / Double(max(union, 1))
    }

    func emitConflictTelemetry(events: [(String, [String: Any])]) {
        for event in events {
            onConflictTelemetry?(event.0, event.1)
        }
    }

    func emitConflictTelemetry(event: String, data: [String: Any]) {
        onConflictTelemetry?(event, data)
    }
}

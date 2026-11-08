import Foundation

/// Decides when an incoming transcript update should trigger a background
/// screenshot prewarm, so a Quick Assist request fired moments later finds a
/// warm capture cache instead of blocking the main thread on capture and
/// JPEG encoding.
///
/// Pure and stateless: the caller tracks which entry was last acted on.
struct QuickAssistScreenshotPrewarmPolicy {
    /// Question cues that mark an interviewer utterance worth prewarming for.
    private static let questionOpeners: Set<String> = [
        "what", "why", "how", "when", "where", "which", "who",
        "can", "could", "would", "should", "do", "does", "did",
        "is", "are", "tell", "walk", "describe", "explain", "design"
    ]

    /// Returns true when the newest entry is a plausible question from the
    /// other party (not "me"), which predicts an imminent Quick Assist ask.
    static func shouldPrewarm(for entry: TranscriptEntry) -> Bool {
        guard !entry.speaker.isMe else { return false }
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return false }

        if trimmed.hasSuffix("?") { return true }

        let firstWord = trimmed
            .lowercased()
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return questionOpeners.contains(firstWord)
    }
}

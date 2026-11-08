import Foundation

/// The most recent thing the other party said, with a flag for whether it
/// reads as a question. Feeds the live strip under the command bar.
struct LiveQuestion: Equatable {
    let speaker: TranscriptSpeaker
    let text: String
    let isQuestion: Bool
    let isPartial: Bool
}

/// Pure resolver over transcript entries and the in flight partial. It
/// prefers the newest finished utterance from someone other than the user,
/// and falls back to the partial so the strip updates while they speak.
struct LiveQuestionResolver {
    static let questionOpeners: Set<String> = [
        "what", "why", "how", "when", "where", "who", "which", "can", "could",
        "would", "should", "do", "does", "did", "is", "are", "tell", "walk",
        "describe", "explain", "give"
    ]

    static func resolve(
        entries: [TranscriptEntry],
        partialOther: String,
        partialOtherSpeaker: TranscriptSpeaker
    ) -> LiveQuestion? {
        let trimmedPartial = partialOther.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPartial.count >= 12 {
            return LiveQuestion(
                speaker: partialOtherSpeaker,
                text: trimmedPartial,
                isQuestion: looksLikeQuestion(trimmedPartial),
                isPartial: true
            )
        }

        guard let latest = entries.last(where: { !$0.speaker.isMe && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }
        let text = latest.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return LiveQuestion(
            speaker: latest.speaker,
            text: text,
            isQuestion: looksLikeQuestion(text),
            isPartial: false
        )
    }

    /// Spoken questions often start with a connective before the real
    /// opener ("So, how would you..."); these are skipped before matching.
    static let leadingFillers: Set<String> = ["and", "so", "okay", "ok", "now", "well", "then", "also", "but", "alright"]

    static func looksLikeQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        let words = trimmed
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map { String($0).lowercased().trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        let opener = words.first { !leadingFillers.contains($0) } ?? ""
        return questionOpeners.contains(opener)
    }
}

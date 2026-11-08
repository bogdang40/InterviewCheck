import Foundation

/// Word lists used to tell a real start from stalling.
///
/// Fillers are the hesitation sounds Deepgram keeps when `filler_words` is
/// on. Stall phrases are what people say while waiting for a tool to
/// produce text ("that's a great question, so..."). Neither counts as the
/// start of a substantive answer.
enum FillerLexicon {
    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "eh", "hmm", "hm", "mm", "mmm",
    ]

    /// Single words that open an answer without content.
    static let stallWords: Set<String> = [
        "so", "well", "okay", "ok", "yeah", "yes", "sure", "right", "alright", "absolutely",
        "definitely", "basically", "actually", "and", "um", "uh",
    ]

    /// Multi-word stalls, normalized and space separated. Longest first so
    /// the longest match wins.
    static let stallPhrases: [[String]] = [
        "thats a really great question",
        "thats a really good question",
        "thats a great question",
        "thats a good question",
        "thats an interesting question",
        "thats a fair question",
        "great question",
        "good question",
        "interesting question",
        "let me think about that",
        "let me think about it",
        "let me think",
        "let me see",
        "give me a second",
        "give me a sec",
        "one second",
        "how do i put this",
        "how should i put it",
        "thank you for asking",
        "thanks for asking",
        "i mean",
        "you know",
    ].map { $0.split(separator: " ").map(String.init) }
        .sorted { $0.count > $1.count }

    /// Common English words that carry no topic of their own. Used to keep
    /// phrase matching about content, not grammar.
    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "so", "of", "to", "in", "on", "at", "by",
        "for", "with", "from", "as", "is", "are", "was", "were", "be", "been", "being", "it", "its",
        "this", "that", "these", "those", "i", "im", "ive", "id", "we", "you", "they", "he", "she",
        "my", "our", "your", "their", "me", "us", "them", "do", "does", "did", "have", "has", "had",
        "would", "could", "should", "will", "can", "just", "really", "very", "also", "about", "like",
        "what", "which", "who", "when", "where", "how", "why", "there", "here", "some", "any", "all",
        "not", "no", "yes", "um", "uh", "think", "kind", "sort", "thing", "things", "get", "got",
        "going", "want", "make", "lot", "more", "most", "into", "out", "up", "than", "too", "well",
    ]

    static func normalize(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let kept = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(kept))
    }

    static func isFiller(_ word: String) -> Bool {
        fillers.contains(normalize(word))
    }

    /// Splits free text into normalized words, dropping fillers.
    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "/" })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty && !fillers.contains($0) }
    }

    /// Length of the stall phrase starting at `index`, or 0.
    static func stallPhraseLength(in words: [String], at index: Int) -> Int {
        for phrase in stallPhrases where index + phrase.count <= words.count {
            if Array(words[index..<(index + phrase.count)]) == phrase { return phrase.count }
        }
        return 0
    }
}

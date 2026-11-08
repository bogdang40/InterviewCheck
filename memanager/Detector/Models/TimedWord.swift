import Foundation

/// Who said a word. The interviewer's own microphone is the question side;
/// the computer's audio (the call) is the candidate side.
enum InterviewSide: String, Codable, Equatable {
    case interviewer
    case candidate
}

/// One final transcribed word with its place on the shared host clock
/// (`ProcessInfo.systemUptime` seconds). Both audio streams map their
/// Deepgram offsets onto this clock, so gaps between the interviewer's last
/// word and the candidate's first word are real silences.
struct TimedWord: Equatable, Codable, Identifiable {
    var id = UUID()
    let side: InterviewSide
    /// Diarized remote speaker for candidate-side words (a panel call can
    /// carry more than one remote voice); nil for the interviewer's mic.
    let speakerIndex: Int?
    /// Display text, punctuated when Deepgram supplied it.
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Double?
    let isFiller: Bool

    /// Lowercased word without punctuation, for matching.
    var normalized: String { FillerLexicon.normalize(text) }
}

/// A batch of final words from one stream, already mapped to host time.
struct TimedWordBatch: Equatable {
    let side: InterviewSide
    let words: [TimedWord]
    /// True when the stream's clock saw dropped or late audio, so the
    /// mapped times may be off by the size of that gap.
    let hasTimingGap: Bool
}

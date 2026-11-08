import Foundation

/// Who said a word. The interviewer's own microphone is the question side;
/// the computer's audio (the call) is the candidate side.
public enum InterviewSide: String, Codable, Equatable {
    case interviewer
    case candidate
}

/// One final transcribed word with its place on the shared host clock
/// (`ProcessInfo.systemUptime` seconds). Both audio streams map their
/// Deepgram offsets onto this clock, so gaps between the interviewer's last
/// word and the candidate's first word are real silences.
public struct TimedWord: Equatable, Codable, Identifiable {
    public var id = UUID()
    public let side: InterviewSide
    /// Diarized remote speaker for candidate-side words (a panel call can
    /// carry more than one remote voice); nil for the interviewer's mic.
    public let speakerIndex: Int?
    /// Display text, punctuated when Deepgram supplied it.
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let confidence: Double?
    public let isFiller: Bool

    public init(id: UUID = UUID(), side: InterviewSide, speakerIndex: Int?, text: String,
                start: TimeInterval, end: TimeInterval, confidence: Double?, isFiller: Bool) {
        self.id = id
        self.side = side
        self.speakerIndex = speakerIndex
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.isFiller = isFiller
    }

    /// Lowercased word without punctuation, for matching.
    public var normalized: String { FillerLexicon.normalize(text) }
}

/// A batch of final words from one stream, already mapped to host time.
public struct TimedWordBatch: Equatable {
    public let side: InterviewSide
    public let words: [TimedWord]
    /// True when the stream's clock saw dropped or late audio, so the
    /// mapped times may be off by the size of that gap.
    public let hasTimingGap: Bool
}

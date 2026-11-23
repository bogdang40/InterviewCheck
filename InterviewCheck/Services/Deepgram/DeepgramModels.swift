import Foundation

// MARK: - Deepgram Response Models

/// Deepgram streaming response structure
struct DeepgramResponse: Codable {
    let type: String?
    let channel: DeepgramChannel?
    let utterances: [DeepgramUtterance]?
    let isFinal: Bool?
    let speechFinal: Bool?
    let start: Double?
    let duration: Double?
    /// The answer to a Finalize message.
    var fromFinalize: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case channel
        case utterances
        case isFinal = "is_final"
        case speechFinal = "speech_final"
        case start
        case duration
        case fromFinalize = "from_finalize"
    }
}

struct DeepgramChannel: Codable {
    let alternatives: [DeepgramAlternative]
}

struct DeepgramAlternative: Codable {
    let transcript: String
    let confidence: Double?
    let words: [DeepgramWord]?
}

struct DeepgramWord: Codable {
    let word: String
    let start: Double
    let end: Double
    let confidence: Double?
    let speaker: Int?
    let punctuatedWord: String?

    enum CodingKeys: String, CodingKey {
        case word
        case start
        case end
        case confidence
        case speaker
        case punctuatedWord = "punctuated_word"
    }
}

struct DeepgramUtterance: Codable {
    let start: Double
    let end: Double
    let confidence: Double?
    let channel: Int?
    let transcript: String
    let words: [DeepgramWord]?
    let id: String?
    let speaker: Int?
}

// MARK: - Deepgram Transcript Entry

/// A transcript segment from Deepgram with speaker diarization
struct DeepgramTranscriptSegment {
    let text: String
    let speaker: Int?
    let startTime: Double
    let endTime: Double
    let isFinal: Bool
    let confidence: Double?
    let words: [DeepgramWord]
}

// MARK: - Connection State

enum DeepgramConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

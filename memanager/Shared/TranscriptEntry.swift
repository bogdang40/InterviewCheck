import Foundation

// MARK: - Speaker Identification

/// Represents a speaker in the transcript.
///
/// With unified audio stream architecture, speakers are identified purely by
/// Deepgram's acoustic diarization. Users can manually tap to identify "me".
///
/// - `me`: The user (manually identified via tap-to-select)
/// - `speaker(Int)`: Numbered speaker (Speaker 1, 2, 3... from diarization)
/// - `unknown`: Speaker not yet determined
enum TranscriptSpeaker: Codable, Equatable, Hashable {
    case me
    case speaker(Int)  // 0-indexed internally, displays as "Speaker N+1"
    case unknown

    // MARK: - Display Properties

    var displayName: String {
        switch self {
        case .me:
            return "Me"
        case .speaker(let id):
            return "Speaker \(id + 1)"
        case .unknown:
            return "Unknown"
        }
    }

    var isMe: Bool {
        if case .me = self { return true }
        return false
    }

    /// Get speaker number if this is a numbered speaker
    var speakerNumber: Int? {
        if case .speaker(let id) = self { return id }
        return nil
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type
        case speakerId
    }

    private enum SpeakerType: String, Codable {
        case me
        case speaker
        case unknown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(SpeakerType.self, forKey: .type)

        switch type {
        case .me:
            self = .me
        case .speaker:
            let id = try container.decode(Int.self, forKey: .speakerId)
            self = .speaker(id)
        case .unknown:
            self = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .me:
            try container.encode(SpeakerType.me, forKey: .type)
        case .speaker(let id):
            try container.encode(SpeakerType.speaker, forKey: .type)
            try container.encode(id, forKey: .speakerId)
        case .unknown:
            try container.encode(SpeakerType.unknown, forKey: .type)
        }
    }
}

// MARK: - Transcript Entry

/// A single transcript entry with speaker attribution.
///
/// With the unified audio stream, all entries come from a single mixed stream
/// where Deepgram performs acoustic speaker diarization.
struct TranscriptEntry: Identifiable, Codable {
    let id: UUID
    let speaker: TranscriptSpeaker
    let text: String
    let timestamp: Date
    let deepgramSpeakerId: Int?  // Raw Deepgram speaker ID for tap-to-identify

    init(
        id: UUID = UUID(),
        speaker: TranscriptSpeaker,
        text: String,
        timestamp: Date = Date(),
        deepgramSpeakerId: Int? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
        self.deepgramSpeakerId = deepgramSpeakerId
    }
}

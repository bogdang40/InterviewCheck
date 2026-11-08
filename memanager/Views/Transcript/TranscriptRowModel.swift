import Foundation

/// One line of the transcript as the views render it. Finished entries and
/// the two in flight partials share this shape.
struct TranscriptRowModel: Identifiable, Equatable {
    let id: UUID
    let speaker: TranscriptSpeaker
    let text: String
    let isPartial: Bool
    let timestamp: Date?
    let deepgramSpeakerId: Int?

    var isQuestion: Bool {
        !speaker.isMe && LiveQuestionResolver.looksLikeQuestion(text)
    }

    var speakerLabel: String {
        switch speaker {
        case .me: return "You"
        case .speaker, .unknown: return speaker.displayName
        }
    }
}

/// Builds rows from the audio service's entries and partials, newest last.
/// `limit` keeps the drawer light by showing only the tail.
enum TranscriptRowsBuilder {
    private static let partialMeID = UUID()
    private static let partialOtherID = UUID()

    static func rows(
        entries: [TranscriptEntry],
        partialMe: String,
        partialOther: String,
        partialOtherSpeaker: TranscriptSpeaker,
        limit: Int?
    ) -> [TranscriptRowModel] {
        var rows = entries.map {
            TranscriptRowModel(
                id: $0.id,
                speaker: $0.speaker,
                text: $0.text,
                isPartial: false,
                timestamp: $0.timestamp,
                deepgramSpeakerId: $0.deepgramSpeakerId
            )
        }

        let trimmedMe = partialMe.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMe.isEmpty {
            rows.append(TranscriptRowModel(id: partialMeID, speaker: .me, text: trimmedMe, isPartial: true, timestamp: nil, deepgramSpeakerId: nil))
        }

        let trimmedOther = partialOther.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedOther.isEmpty {
            rows.append(
                TranscriptRowModel(
                    id: partialOtherID,
                    speaker: partialOtherSpeaker,
                    text: trimmedOther,
                    isPartial: true,
                    timestamp: nil,
                    deepgramSpeakerId: nil
                )
            )
        }

        if let limit, rows.count > limit {
            return Array(rows.suffix(limit))
        }
        return rows
    }
}

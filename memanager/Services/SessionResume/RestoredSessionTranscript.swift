import Foundation

/// Saved text can be more complete than legacy speaker rows. Retain both
/// without assigning invented speakers or timestamps to missing rows.
struct RestoredSessionTranscript {
    let text: String
    let entries: [TranscriptEntry]
}

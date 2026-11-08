import Foundation

/// Transcript text and entries shown before capture resumes.
struct RestoredSessionTranscript {
    let text: String
    let entries: [TranscriptEntry]
}

import Foundation

struct Session {
    var id = UUID()
    var startedAt: Date?
    var transcript: String = ""
    var transcriptEntries: [TranscriptEntry] = []
    var screenshots: [Screenshot] = []
    var response: MentorResponse?
    var state: SessionState = .idle
    var activeModeSnapshotID: UUID?

    enum SessionState {
        case idle
        case listening
        case paused
    }

    mutating func reset() {
        id = UUID()
        startedAt = nil
        transcript = ""
        transcriptEntries = []
        screenshots = []
        response = nil
        state = .idle
        activeModeSnapshotID = nil
    }
}

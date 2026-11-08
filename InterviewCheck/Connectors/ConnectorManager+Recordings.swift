import Foundation
import InterviewCheckConnectors

extension ConnectorManager {
    /// The scheduled interview a meeting recording belongs to: same meeting
    /// link, or started within 20 minutes of it.
    func interview(for recording: ExternalRecording) -> ExternalInterview? {
        let candidates = database.loadExternalInterviews(startingAfter: recording.startedAt.addingTimeInterval(-86_400))
        let key = { (url: URL) in "\(url.host ?? "")\(url.path)".lowercased() }
        if let link = recording.meetingURL,
           let match = candidates.first(where: { $0.meetingURL.map(key) == key(link) }) {
            return match
        }
        return candidates
            .filter { abs($0.startsAt.timeIntervalSince(recording.startedAt)) < 20 * 60 }
            .min { abs($0.startsAt.timeIntervalSince(recording.startedAt)) < abs($1.startsAt.timeIntervalSince(recording.startedAt)) }
    }

    /// Downloads a meeting's audio (or video, or transcript) and starts the
    /// analysis. Downloads go to a temporary folder deleted afterwards.
    func analyze(_ recording: ExternalRecording, with analyzer: RecordingAnalyzer, candidateName: String,
                 role: RoleProfile?) async throws {
        guard let source = try makeConnector(recording.source) as? RecordingSource else {
            throw ConnectorError.unsupported("\(recording.source.descriptor.name) has no recordings.")
        }
        guard let file = recording.bestMediaFile ?? recording.files.first(where: { $0.kind == .transcript }) else {
            throw ConnectorError.unsupported("This meeting has no audio, video or transcript yet.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("interviewcheck-meeting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let local = try await source.download(file, into: folder)
            analyzer.meetingStart = recording.startedAt
            if file.kind == .transcript {
                analyzer.startTranscript(file: local, candidateName: candidateName, role: role,
                                         recordingID: recording.id, cleanup: folder)
            } else {
                analyzer.start(file: local, candidateName: candidateName, role: role, recordingID: recording.id, cleanup: folder)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

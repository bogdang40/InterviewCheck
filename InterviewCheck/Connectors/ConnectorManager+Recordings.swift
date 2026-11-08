import Foundation
import InterviewCheckConnectors

extension ConnectorManager {
    /// The scheduled interview a meeting recording belongs to: one of the
    /// interviewer's own, with the same meeting link and a start within an
    /// hour, or else the only candidate starting within 20 minutes. Never a
    /// guess between two different candidates.
    func interview(for recording: ExternalRecording) -> ExternalInterview? {
        let nearby = database.loadExternalInterviews(startingAfter: recording.startedAt.addingTimeInterval(-3 * 3600))
            .filter { isMine($0) && $0.startsAt < recording.startedAt.addingTimeInterval(3600) }
        let gap = { (interview: ExternalInterview) in abs(interview.startsAt.timeIntervalSince(recording.startedAt)) }
        if let link = recording.meetingURL.map(Self.meetingKey) {
            let sameLink = nearby.filter { $0.meetingURL.map(Self.meetingKey) == link && gap($0) <= 3600 }
            if let match = sameLink.min(by: { gap($0) < gap($1) }) { return match }
        }
        let close = InterviewMerger.merge(nearby.filter { gap($0) < 20 * 60 && $0.candidate != nil })
        let names = Set(close.compactMap { $0.candidate?.name.lowercased() })
        return names.count == 1 ? close.min(by: { gap($0) < gap($1) }) : nil
    }

    /// Zoom links differ by host and query (us02web.zoom.us/j/123?pwd=…):
    /// the meeting number identifies them. Others: host and path.
    static func meetingKey(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix("zoom.us") || host.hasSuffix("zoomgov.us"),
           let number = url.path.range(of: #"\d{9,12}"#, options: .regularExpression) {
            return "zoom:\(url.path[number])"
        }
        return "\(host)\(url.path.lowercased())"
    }

    /// Downloads a meeting's audio (or video, or transcript) and starts the
    /// analysis. Downloads go to a temporary folder deleted afterwards.
    func analyze(_ recording: ExternalRecording, with analyzer: RecordingAnalyzer, candidateName: String,
                 role: RoleProfile?) async throws {
        guard let source = try makeConnector(recording.source) as? RecordingSource else {
            throw ConnectorError.unsupported("\(recording.source.descriptor.name) has no recordings.")
        }
        // The audio or video first; if it cannot be downloaded (the host turned
        // downloads off, say), the transcript.
        let transcript = recording.files.first(where: { $0.kind == .transcript })
        let choices = [recording.bestMediaFile, transcript].compactMap { $0 }.reduce(into: [ExternalFile]()) { list, file in
            if !list.contains(file) { list.append(file) }
        }
        guard !choices.isEmpty else {
            throw ConnectorError.unsupported("This meeting has no audio, video or transcript yet.")
        }
        var failure: Error?
        for file in choices {
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
                return
            } catch {
                try? FileManager.default.removeItem(at: folder)
                failure = error
            }
        }
        throw failure ?? ConnectorError.unsupported("This meeting could not be downloaded.")
    }
}

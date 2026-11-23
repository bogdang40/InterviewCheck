import XCTest
import InterviewCheckConnectors
@testable import InterviewCheck

/// A meeting whose audio cannot be downloaded (the host turned downloads off)
/// but whose transcript can.
private struct NoAudioMeeting: RecordingSource {
    let kind = ConnectorKind.webex
    func verify() async throws -> String { "lee@acme.com" }
    func recordings(since: Date) async throws -> [ExternalRecording] { [] }
    func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        guard file.kind == .transcript else { throw ConnectorError.unsupported("Webex has no downloadable file for this recording yet.") }
        let url = folder.appendingPathComponent("meeting.vtt")
        try "WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nSam Lead: How would you design rate limiting?\n\n00:00:09.000 --> 00:00:20.000\nAna Diaz: I would use a token bucket per key in Redis.\n"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

@MainActor
final class RecordingFallbackTests: XCTestCase {
    func testTheTranscriptIsUsedWhenTheAudioCannotBeDownloaded() async throws {
        let path = NSTemporaryDirectory() + "fallback-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let manager = ConnectorManager(store: MemoryCredentialStore(), database: SessionDatabase(databasePath: path),
                                       defaults: UserDefaults(suiteName: "fallback.\(UUID().uuidString)")!)
        manager.factory = { _, _, _, _ in NoAudioMeeting() }
        try await manager.connect(.webex, fields: [:])
        let recording = ExternalRecording(
            source: .webex, externalID: "I1", title: "Technical interview - Ana Diaz", startedAt: Date(timeIntervalSince1970: 1_794_000_000),
            files: [ExternalFile(kind: .audio, filename: "x.mp3", url: URL(string: "https://webexapis.com/v1/recordings/R1")!, needsAuth: true),
                    ExternalFile(kind: .transcript, filename: "x.vtt", url: URL(string: "https://webexapis.com/v1/meetingTranscripts/T1/download")!, needsAuth: true)])
        let analyzer = RecordingAnalyzer()
        try await manager.analyze(recording, with: analyzer, candidateName: "Ana Diaz", role: nil, consentConfirmedAt: nil)
        XCTAssertEqual(analyzer.step, .chooseSpeaker, "scored from the transcript instead")
        XCTAssertEqual(analyzer.speakers.map(\.name), ["Sam Lead", "Ana Diaz"])
    }
}

import XCTest
import InterviewCheckConnectors
@testable import InterviewCheck

/// A Zoom stand-in: one scheduled interview and its transcript recording.
private struct FakeZoom: InterviewSource, RecordingSource {
    let kind = ConnectorKind.zoom
    let start: Date

    func verify() async throws -> String { "me@acme.com" }

    func upcomingInterviews(from: Date, to: Date) async throws -> [ExternalInterview] {
        [ExternalInterview(source: .zoom, externalID: "m1", title: "Interview: Ana Diaz", startsAt: start,
                           meetingURL: URL(string: "https://zoom.us/j/1"), candidate: ExternalCandidate(name: "Ana Diaz"))]
    }

    func recordings(since: Date) async throws -> [ExternalRecording] {
        [ExternalRecording(source: .zoom, externalID: "rec1", title: "Interview: Ana Diaz", startedAt: start.addingTimeInterval(60),
                           meetingURL: URL(string: "https://zoom.us/j/1"),
                           files: [ExternalFile(kind: .transcript, filename: "t.vtt", url: URL(string: "https://zoom.us/t")!, needsAuth: true)])]
    }

    func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        let url = folder.appendingPathComponent("t.vtt")
        try """
        WEBVTT

        00:00:01.000 --> 00:00:04.000
        Sam Lead: Tell me about a hard bug you fixed recently.

        00:00:09.000 --> 00:00:16.000
        Ana Diaz: We had a race condition in billing where two workers charged one invoice twice.

        00:00:18.000 --> 00:00:20.000
        Sam Lead: How did you find it?

        00:00:21.000 --> 00:00:27.000
        Ana Diaz: I added tracing on the charge path and saw two workers take the same message.
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

@MainActor
final class AutoScorerTests: XCTestCase {
    func testNewRecordingIsScoredOnceAndLinkedToItsInterview() async throws {
        let path = NSTemporaryDirectory() + "auto-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = SessionDatabase(databasePath: path)
        let defaults = UserDefaults(suiteName: "auto.\(UUID().uuidString)")!
        let settings = DetectorSettings(defaults: defaults)
        settings.judgeEnabled = false
        settings.useEmbeddings = false
        let manager = ConnectorManager(store: MemoryCredentialStore(), database: database, defaults: defaults)
        let start = Date().addingTimeInterval(-3 * 3600)
        manager.factory = { _, _, _, _ in FakeZoom(start: start) }
        try await manager.connect(.zoom, fields: ["clientID": "z"])
        XCTAssertEqual(manager.recordings.count, 1)

        let scorer = AutoScorer()
        scorer.manager = manager
        scorer.roles = RoleStore(database: database, defaults: defaults)
        scorer.defaults = defaults
        scorer.makeAnalyzer = {
            let analyzer = RecordingAnalyzer()
            analyzer.database = database
            analyzer.settings = settings
            return analyzer
        }
        var reports: [InterviewReportData] = []
        scorer.onReport = { reports.append($0) }

        await scorer.run()
        XCTAssertTrue(reports.isEmpty, "nothing happens while it is off")

        scorer.isEnabled = true
        XCTAssertEqual(scorer.pending().count, 1)
        await scorer.run()
        XCTAssertEqual(reports.count, 1)
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.interview.candidateName, "Ana Diaz")
        XCTAssertEqual(report.interview.scoredFrom, .transcript)
        XCTAssertEqual(report.interview.externalRef, "zoom:m1")
        XCTAssertEqual(report.questions.count, 2)

        manager.reloadCache()
        XCTAssertEqual(manager.recordings.first?.interviewID, report.interview.id)
        await scorer.run()
        XCTAssertEqual(reports.count, 1, "each recording is scored once")
    }
}

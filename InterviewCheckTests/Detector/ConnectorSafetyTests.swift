import XCTest
import InterviewCheckConnectors
@testable import InterviewCheck

/// An ATS and a meeting tool whose behaviour each test sets.
private struct Scripted: InterviewSource, RecordingSource, CandidateSource {
    let kind: ConnectorKind
    var interviews: [ExternalInterview] = []
    var recordingList: [ExternalRecording] = []
    var interviewDelay: UInt64 = 0
    var downloadDelay: UInt64 = 0
    var interviewsFail = false

    func verify() async throws -> String { "ok" }

    func upcomingInterviews(from: Date, to: Date) async throws -> [ExternalInterview] {
        if interviewDelay > 0 { try await Task.sleep(nanoseconds: interviewDelay) }
        if interviewsFail { throw ConnectorError.forbidden("meeting:read:list_meetings") }
        return interviews
    }

    func recordings(since: Date) async throws -> [ExternalRecording] { recordingList }
    func candidate(id: String) async throws -> ExternalCandidate { ExternalCandidate(name: id) }

    func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        if downloadDelay > 0 { try await Task.sleep(nanoseconds: downloadDelay) }
        let url = folder.appendingPathComponent(file.filename)
        try "Résumé of \(file.filename)".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

@MainActor
final class ConnectorSafetyTests: XCTestCase {
    private var path = ""
    private var database: SessionDatabase!
    private var defaults: UserDefaults!
    private var manager: ConnectorManager!

    override func setUp() async throws {
        path = NSTemporaryDirectory() + "safety-\(UUID().uuidString).sqlite"
        database = SessionDatabase(databasePath: path)
        defaults = UserDefaults(suiteName: "safety.\(UUID().uuidString)")!
        manager = ConnectorManager(store: MemoryCredentialStore(), database: database, defaults: defaults)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func interview(_ id: String, _ name: String, at start: Date, source: ConnectorKind = .greenhouse,
                           interviewers: [String] = [], link: String? = nil) -> ExternalInterview {
        ExternalInterview(source: source, externalID: id, title: "Interview", startsAt: start, meetingURL: link.flatMap(URL.init(string:)),
                          candidate: ExternalCandidate(externalID: id, name: name,
                                                       resume: ExternalFile(kind: .resume, filename: "\(name).txt",
                                                                            url: URL(string: "https://x/\(id)")!, needsAuth: true)),
                          interviewers: interviewers.map { ExternalPerson(name: $0, email: $0) })
    }

    func testOnlyMyATSInterviewsAreShown() async throws {
        let soon = Date().addingTimeInterval(3600)
        let ats = Scripted(kind: .greenhouse, interviews: [
            interview("1", "Mine", at: soon, interviewers: ["me@acme.com", "lee@acme.com"]),
            interview("2", "Someone Else's", at: soon, interviewers: ["lee@acme.com"]),
            interview("3", "No Interviewers Listed", at: soon),
        ])
        manager.factory = { _, _, _, _ in ats }
        try await manager.connect(.greenhouse, fields: ["clientID": "c", "clientSecret": "s"])
        XCTAssertEqual(manager.upcoming.count, 3, "with no email known, nothing is hidden")
        manager.typedEmails = "Me@Acme.com"
        XCTAssertEqual(Set(manager.upcoming.compactMap(\.candidate?.name)), ["Mine", "No Interviewers Listed"])
        XCTAssertEqual(manager.hiddenForOthers, 1)
        manager.showsAllInterviews = true
        XCTAssertEqual(manager.upcoming.count, 3)
        XCTAssertEqual(manager.hiddenForOthers, 0)
    }

    func testRecordingsNeverGuessBetweenCandidates() throws {
        let start = Date().addingTimeInterval(-3 * 3600)
        database.replaceExternalInterviews([
            interview("a", "Jane Doe", at: start, source: .appleCalendar, link: "https://us02web.zoom.us/j/81234567890?pwd=x"),
            interview("b", "Ana Silva", at: start.addingTimeInterval(5 * 60), source: .appleCalendar),
            interview("old", "Yesterday Person", at: start.addingTimeInterval(-86_400), source: .appleCalendar,
                      link: "https://zoom.us/j/99999999999"),
        ], source: .appleCalendar)
        let byLink = ExternalRecording(source: .zoom, externalID: "r1", title: "x", startedAt: start.addingTimeInterval(120),
                                       meetingURL: URL(string: "https://zoom.us/j/81234567890"), files: [])
        XCTAssertEqual(manager.interview(for: byLink)?.candidate?.name, "Jane Doe", "Zoom links match by meeting number")
        let byTime = ExternalRecording(source: .zoom, externalID: "r2", title: "x", startedAt: start.addingTimeInterval(60), files: [])
        XCTAssertNil(manager.interview(for: byTime), "two candidates start within 20 minutes: no guess")
        let recurring = ExternalRecording(source: .zoom, externalID: "r3", title: "x", startedAt: start,
                                          meetingURL: URL(string: "https://zoom.us/j/99999999999"), files: [])
        XCTAssertNil(manager.interview(for: recurring), "the same link a day earlier is a different interview")
    }

    func testRecordingsStillSyncWhenInterviewsFail() async throws {
        let recording = ExternalRecording(source: .zoom, externalID: "r1", title: "Interview: Jane", startedAt: Date().addingTimeInterval(-3600),
                                          files: [ExternalFile(kind: .audio, filename: "a.m4a", url: URL(string: "https://z/a")!, needsAuth: true)])
        manager.factory = { _, _, _, _ in Scripted(kind: .zoom, recordingList: [recording], interviewsFail: true) }
        try await manager.connect(.zoom, fields: ["clientID": "z"])
        XCTAssertEqual(manager.recordings.map(\.recording.id), ["zoom:r1"])
        XCTAssertNotNil(manager.account(.zoom)?.lastError)
        XCTAssertNotNil(manager.account(.zoom)?.recordingsCheckedAt)
    }

    func testDisconnectDuringSyncKeepsNothing() async throws {
        let slow = Scripted(kind: .greenhouse, interviews: [interview("1", "Late Arrival", at: Date().addingTimeInterval(3600))],
                            interviewDelay: 300_000_000)
        var calls = 0
        manager.factory = { _, _, _, _ in
            calls += 1
            return calls == 1 ? Scripted(kind: .greenhouse) : slow
        }
        try await manager.connect(.greenhouse, fields: ["clientID": "c", "clientSecret": "s"])
        let sync = Task { await manager.sync(.greenhouse) }
        try await Task.sleep(nanoseconds: 50_000_000)
        manager.disconnect(.greenhouse)
        await sync.value
        XCTAssertTrue(manager.upcoming.isEmpty)
        XCTAssertTrue(database.loadExternalInterviews(startingAfter: .distantPast).isEmpty)
    }

    func testANewerPrepareWinsOverASlowerOne() async throws {
        let soon = Date().addingTimeInterval(3600)
        let first = interview("1", "First Person", at: soon)
        let second = interview("2", "Second Person", at: soon.addingTimeInterval(3600))
        manager.factory = { _, _, _, _ in Scripted(kind: .greenhouse, downloadDelay: 300_000_000) }
        try await manager.connect(.greenhouse, fields: ["clientID": "c", "clientSecret": "s"])
        let controller = InterviewController(timeline: InterviewTimeline(), database: database, settings: DetectorSettings(defaults: defaults))
        let roles = RoleStore(database: database, defaults: defaults)
        let slow = Task { await manager.prepare(first, controller: controller, roles: roles) }
        try await Task.sleep(nanoseconds: 50_000_000)
        manager.factory = { _, _, _, _ in Scripted(kind: .greenhouse) }
        _ = await manager.prepare(second, controller: controller, roles: roles)
        let stale = await slow.value
        XCTAssertEqual(controller.candidateName, "Second Person")
        XCTAssertTrue(controller.resumeText.contains("Second Person"), "the slow download did not overwrite the newer prepare")
        XCTAssertTrue(stale.first?.hasPrefix("Preparation stopped") ?? false)
        XCTAssertEqual(controller.preparedFrom, "greenhouse:2")
    }
}

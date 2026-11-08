import XCTest
import InterviewCheckConnectors
@testable import InterviewCheck

/// An ATS stand-in: one interview, its job and a résumé file.
final class NoteLog: @unchecked Sendable { var notes: [String] = [] }

private struct FakeCalendar: InterviewSource {
    let kind = ConnectorKind.appleCalendar
    let start: Date
    func verify() async throws -> String { "2 calendars" }
    func upcomingInterviews(from: Date, to: Date) async throws -> [ExternalInterview] {
        [ExternalInterview(source: .appleCalendar, externalID: "evt1", title: "Interview: Jane Doe", startsAt: start,
                           meetingURL: URL(string: "https://zoom.us/j/1"),
                           candidate: ExternalCandidate(name: "Jane Doe", email: "jane@example.com"))]
    }
}

private struct FakeATS: InterviewSource, JobSource, CandidateSource, NoteDestination, CandidateLookup {
    let kind = ConnectorKind.greenhouse
    let start: Date
    var log = NoteLog()

    func addNote(_ text: String, to interview: ExternalInterview) async throws { log.notes.append(text) }

    func findCandidate(email: String) async throws -> CandidateMatch? {
        email == "jane@example.com" ? CandidateMatch(candidate: ExternalCandidate(externalID: "c7", name: "Jane Doe", email: email),
                                                     job: ExternalJob(externalID: "j4", title: "Job"), applicationID: "a3") : nil
    }

    func verify() async throws -> String { "acme.greenhouse.io" }

    func upcomingInterviews(from: Date, to: Date) async throws -> [ExternalInterview] {
        [ExternalInterview(source: .greenhouse, externalID: "901", title: "Technical interview", startsAt: start,
                           candidate: ExternalCandidate(externalID: "c7", name: "Jane Doe", email: "jane@example.com",
                                                        resume: ExternalFile(kind: .resume, filename: "jane.txt",
                                                                             url: URL(string: "https://x/r")!, needsAuth: true)),
                           job: ExternalJob(externalID: "j4", title: "Backend Engineer", company: "Acme"),
                           applicationID: "a3")]
    }

    func job(id: String) async throws -> ExternalJob {
        ExternalJob(externalID: id, title: "Backend Engineer", description: "Own the payments API in Go and Postgres.")
    }

    func candidate(id: String) async throws -> ExternalCandidate {
        ExternalCandidate(externalID: id, name: "Jane Doe",
                          resume: ExternalFile(kind: .resume, filename: "jane.txt", url: URL(string: "https://x/r")!, needsAuth: true),
                          profileURL: URL(string: "https://app.greenhouse.io/people/\(id)"))
    }

    func download(_ file: ExternalFile, into folder: URL) async throws -> URL {
        let url = folder.appendingPathComponent(file.filename)
        try "Jane Doe\nSix years building payment systems.".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// A source that reads only part of what is there, the first time.
private final class PartialSource: InterviewSource, @unchecked Sendable {
    let kind = ConnectorKind.calendly
    var cut = true
    func verify() async throws -> String { "lee@acme.com" }
    func upcomingInterviews(from: Date, to: Date) async throws -> [ExternalInterview] {
        if cut { SyncNotes.note("Stopped after 1,000 bookings; some may be missing.") }
        return []
    }
}

@MainActor
final class ConnectorManagerTests: XCTestCase {
    func testAListCutShortIsNotedOnTheAccountUntilTheNextFullSync() async throws {
        let path = NSTemporaryDirectory() + "connectors-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let manager = ConnectorManager(store: MemoryCredentialStore(), database: SessionDatabase(databasePath: path),
                                       defaults: UserDefaults(suiteName: "connectors.\(UUID().uuidString)")!)
        let source = PartialSource()
        manager.factory = { _, _, _, _ in source }
        try await manager.connect(.calendly, fields: ["apiKey": "k"])
        XCTAssertEqual(manager.account(.calendly)?.notes, ["Stopped after 1,000 bookings; some may be missing."])
        XCTAssertNil(manager.account(.calendly)?.lastError, "a note is not a failure")
        source.cut = false
        await manager.sync(.calendly)
        XCTAssertNil(manager.account(.calendly)?.notes)
    }

    func testConnectSyncPrepareAndDisconnect() async throws {
        let path = NSTemporaryDirectory() + "connectors-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = SessionDatabase(databasePath: path)
        let defaults = UserDefaults(suiteName: "connectors.\(UUID().uuidString)")!
        let store = MemoryCredentialStore()
        let manager = ConnectorManager(store: store, database: database, defaults: defaults)
        let start = Date().addingTimeInterval(3600)
        manager.factory = { kind, _, _, _ in
            guard kind == .greenhouse else { throw ConnectorError.notConnected }
            return FakeATS(start: start)
        }

        try await manager.connect(.greenhouse, fields: ["apiKey": "secret"])
        XCTAssertEqual(manager.account(.greenhouse)?.label, "acme.greenhouse.io")
        XCTAssertNil(manager.account(.greenhouse)?.lastError)
        XCTAssertEqual(store.load("greenhouse")?["apiKey"], "secret")
        XCTAssertEqual(manager.upcoming.map(\.candidate?.name), ["Jane Doe"])

        // A second manager reads the same accounts and cached interviews.
        let reopened = ConnectorManager(store: store, database: database, defaults: defaults)
        XCTAssertEqual(reopened.accounts.map(\.kind), [.greenhouse])
        XCTAssertEqual(reopened.upcoming.count, 1)

        let roles = RoleStore(database: database, defaults: defaults)
        let controller = InterviewController(timeline: InterviewTimeline(), database: database,
                                             settings: DetectorSettings(defaults: defaults))
        let missing = await manager.prepare(manager.upcoming[0], controller: controller, roles: roles)
        XCTAssertEqual(missing, [])
        XCTAssertEqual(controller.candidateName, "Jane Doe")
        XCTAssertEqual(controller.externalRef, "greenhouse:901")
        XCTAssertEqual(controller.resumeFileName, "jane.txt")
        XCTAssertTrue(controller.resumeText.contains("payment systems"))
        let role = try XCTUnwrap(roles.selectedRole)
        XCTAssertEqual(role.name, "Backend Engineer")
        XCTAssertEqual(role.externalJobKey, "greenhouse:j4")
        XCTAssertEqual(role.jobDescription, "Own the payments API in Go and Postgres.")
        XCTAssertEqual(database.loadExternalLink("greenhouse:901")?.candidate?.profileURL?.absoluteString,
                       "https://app.greenhouse.io/people/c7", "the report can link to the candidate's page")

        // Preparing again reuses the role.
        await manager.prepare(manager.upcoming[0], controller: controller, roles: roles)
        XCTAssertEqual(roles.roles.count, 1)

        manager.disconnect(.greenhouse)
        XCTAssertNil(store.load("greenhouse"))
        XCTAssertTrue(manager.upcoming.isEmpty)
        XCTAssertTrue(manager.accounts.isEmpty)
    }

    func testFailedSyncIsShownOnTheAccount() async throws {
        let path = NSTemporaryDirectory() + "connectors-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let manager = ConnectorManager(store: MemoryCredentialStore(), database: SessionDatabase(databasePath: path),
                                       defaults: UserDefaults(suiteName: "connectors.\(UUID().uuidString)")!)
        var calls = 0
        manager.factory = { _, _, _, _ in
            calls += 1
            if calls == 1 { return FakeATS(start: Date().addingTimeInterval(60)) }
            throw ConnectorError.unauthorized
        }
        try await manager.connect(.greenhouse, fields: ["apiKey": "k"])
        XCTAssertEqual(manager.account(.greenhouse)?.lastError, ConnectorError.unauthorized.localizedDescription)
    }

    func testSummaryNoteGoesBackToTheATSOnlyWhenSent() async throws {
        let path = NSTemporaryDirectory() + "summary-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = SessionDatabase(databasePath: path)
        let defaults = UserDefaults(suiteName: "summary.\(UUID().uuidString)")!
        let manager = ConnectorManager(store: MemoryCredentialStore(), database: database, defaults: defaults)
        let log = NoteLog()
        let ats = FakeATS(start: Date().addingTimeInterval(3600), log: log)
        manager.factory = { _, _, _, _ in ats }
        try await manager.connect(.greenhouse, fields: ["clientID": "c", "clientSecret": "s"])

        let controller = InterviewController(timeline: InterviewTimeline(), database: database,
                                             settings: DetectorSettings(defaults: defaults))
        await manager.prepare(manager.upcoming[0], controller: controller,
                              roles: RoleStore(database: database, defaults: defaults))
        // The interview ran; its record keeps the link to the ATS.
        database.saveInterview(InterviewRecord(id: "i1", workspaceID: nil, roleTitle: "Backend Engineer", candidateName: "Jane Doe",
                                               consentConfirmedAt: Date(), startedAt: Date(), overallPercent: 81, flaggedCount: 1,
                                               questionCount: 1, externalRef: controller.externalRef))
        database.saveInterviewQuestion(InterviewQuestionRecord(id: "q1", interviewID: "i1", ordinal: 1, text: "Design a rate limiter",
                                                               source: .live, markedAt: 0))
        database.saveAnswerLabel(.aiAssisted, questionID: "q1")
        // Later syncs drop the interview from the window; the saved link remains.
        database.replaceExternalInterviews([], source: .greenhouse)

        let report = try XCTUnwrap(database.loadInterviewReport(id: "i1"))
        let (interview, kind) = try XCTUnwrap(manager.noteDestination(for: report))
        XCTAssertEqual(kind, .greenhouse)
        XCTAssertEqual(interview.candidate?.externalID, "c7")
        let text = SummaryNote.make(report)
        XCTAssertTrue(text.contains("81% overall"))
        XCTAssertTrue(text.contains("Interviewer: AI-assisted."))
        XCTAssertTrue(text.contains("not proof"))
        XCTAssertTrue(log.notes.isEmpty, "nothing is sent before the interviewer presses Send")
        try await manager.sendNote(text, to: interview)
        XCTAssertEqual(log.notes, [text])
    }

    func testRemindersOnlyForInterviewsStillAhead() {
        let now = Date()
        let soon = ExternalInterview(source: .appleCalendar, externalID: "a", title: "Interview", startsAt: now.addingTimeInterval(5 * 60),
                                     candidate: ExternalCandidate(name: "Jane Doe"))
        let later = ExternalInterview(source: .appleCalendar, externalID: "b", title: "Interview", startsAt: now.addingTimeInterval(3600),
                                      candidate: ExternalCandidate(name: "Ana Silva"), job: ExternalJob(externalID: "", title: "Designer"))
        let requests = InterviewReminders.requests(for: [soon, later], minutes: 10, now: now)
        XCTAssertEqual(requests.map(\.identifier), ["interview.appleCalendar:b"], "too late to remind about the first")
        XCTAssertEqual(requests.first?.content.body, "Ana Silva \u{00B7} Designer")
        XCTAssertEqual(requests.first?.content.userInfo["interviewID"] as? String, "appleCalendar:b")
    }

    func testCalendarInviteIsFilledFromTheATSByEmail() async throws {
        let path = NSTemporaryDirectory() + "enrich-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let database = SessionDatabase(databasePath: path)
        let defaults = UserDefaults(suiteName: "enrich.\(UUID().uuidString)")!
        let manager = ConnectorManager(store: MemoryCredentialStore(), database: database, defaults: defaults)
        let start = Date().addingTimeInterval(3600)
        let ats = FakeATS(start: start)
        manager.factory = { kind, _, _, _ in kind == .appleCalendar ? FakeCalendar(start: start) as Connector : ats }
        try await manager.connect(.appleCalendar, fields: [:])
        try await manager.connect(.greenhouse, fields: ["clientID": "c", "clientSecret": "s"])

        let invite = try XCTUnwrap(manager.database.loadExternalInterviews(startingAfter: .distantPast).first { $0.source == .appleCalendar })
        let roles = RoleStore(database: database, defaults: defaults)
        let controller = InterviewController(timeline: InterviewTimeline(), database: database,
                                             settings: DetectorSettings(defaults: defaults))
        let missing = await manager.prepare(invite, controller: controller, roles: roles)
        XCTAssertEqual(missing, [])
        XCTAssertEqual(controller.externalRef, "greenhouse:evt1", "the summary goes to the ATS, not the calendar")
        XCTAssertTrue(controller.resumeText.contains("payment systems"))
        let role = try XCTUnwrap(roles.selectedRole)
        XCTAssertEqual(role.name, "Backend Engineer", "the placeholder title is replaced by the ATS job's")
        XCTAssertEqual(role.jobDescription, "Own the payments API in Go and Postgres.")
        let link = try XCTUnwrap(database.loadExternalLink("greenhouse:evt1"))
        XCTAssertEqual(link.applicationID, "a3")
        XCTAssertEqual(link.meetingURL?.host, "zoom.us", "the meeting link from the invite is kept")
    }

    func testFixConnectionKeepsSavedSecretsAndShowsNoSecrets() async throws {
        let path = NSTemporaryDirectory() + "fix-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = MemoryCredentialStore()
        let manager = ConnectorManager(store: store, database: SessionDatabase(databasePath: path),
                                       defaults: UserDefaults(suiteName: "fix.\(UUID().uuidString)")!)
        try store.save(ConnectorCredentials(fields: ["subdomain": "acme", "apiKey": "old-secret", "memberID": "m1"]), for: "workable")
        XCTAssertEqual(manager.storedFields(.workable), ["subdomain": "acme", "memberID": "m1"], "secrets are never shown")
        let merged = manager.mergedWithSavedSecrets(.workable, ["subdomain": "acme2", "apiKey": "", "memberID": "m1"])
        XCTAssertEqual(merged["apiKey"], "old-secret", "an empty secret keeps the saved one")
        XCTAssertEqual(merged["subdomain"], "acme2")
    }
}

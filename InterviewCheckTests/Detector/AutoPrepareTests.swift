import XCTest
import InterviewCheckConnectors
@testable import InterviewCheck

/// Two interviews (the second `gap` after the first); candidate records
/// arrive after `delay`, so a test can act while Prepare is waiting.
private struct TwoInterviews: InterviewSource, CandidateSource {
    let kind = ConnectorKind.calendly
    let first: Date
    var gap: TimeInterval = 3 * 3600
    var delay: UInt64 = 0
    var withLink = false
    var withJob = false
    func verify() async throws -> String { "lee@acme.com" }
    func upcomingInterviews(from: Date, to: Date) async throws -> [ExternalInterview] {
        [ExternalInterview(source: .calendly, externalID: "a", title: "Phone Screen", startsAt: first,
                           meetingURL: withLink ? URL(string: "https://acme.zoom.us/j/81234567890") : nil,
                           candidate: ExternalCandidate(externalID: "ca", name: "Jane Doe", email: "jane@example.com"),
                           job: withJob ? ExternalJob(externalID: "j1", title: "Backend Engineer") : nil),
         ExternalInterview(source: .calendly, externalID: "b", title: "Phone Screen", startsAt: first.addingTimeInterval(gap),
                           candidate: ExternalCandidate(externalID: "cb", name: "Max Roe", email: "max@example.com"))]
    }
    func candidate(id: String) async throws -> ExternalCandidate {
        try await Task.sleep(nanoseconds: delay)
        return ExternalCandidate(externalID: id, name: id == "ca" ? "Jane Doe" : "Max Roe")
    }
    func download(_ file: ExternalFile, into folder: URL) async throws -> URL { throw ConnectorError.notFound }
}

@MainActor
final class AutoPrepareTests: XCTestCase {
    private var path: String!
    private var manager: ConnectorManager!
    private var controller: InterviewController!
    private var auto: AutoPrepare!
    private var clock = Date()
    private var editingRoles = false
    private var source: TwoInterviews!
    private var roles: RoleStore!

    override func setUp() async throws {
        path = NSTemporaryDirectory() + "autoprepare-\(UUID().uuidString).sqlite"
        let database = SessionDatabase(databasePath: path)
        let defaults = UserDefaults(suiteName: "autoprepare.\(UUID().uuidString)")!
        manager = ConnectorManager(store: MemoryCredentialStore(), database: database, defaults: defaults)
        source = TwoInterviews(first: clock.addingTimeInterval(8 * 60))
        manager.factory = { [unowned self] _, _, _, _ in self.source }
        try await manager.connect(.calendly, fields: ["apiKey": "k"])
        controller = InterviewController(timeline: InterviewTimeline(), database: database, settings: DetectorSettings(defaults: defaults))
        roles = RoleStore(database: database, defaults: defaults)
        auto = AutoPrepare(manager: manager, controller: controller, roles: roles,
                           defaults: defaults)
        auto.now = { [unowned self] in self.clock }
        auto.leadMinutes = { 10 }
        auto.isEditingRoles = { [unowned self] in self.editingRoles }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: path)
    }

    func testTheNextInterviewIsReadyWithoutStartingIt() async {
        let section = AppNavigation.shared.selection
        let prepared = await auto.tick()
        XCTAssertEqual(prepared?.externalID, "a")
        XCTAssertEqual(controller.candidateName, "Jane Doe")
        XCTAssertEqual(controller.phase, .setup, "never started")
        XCTAssertFalse(controller.consentConfirmed, "the interviewer still confirms the candidate was told")
        XCTAssertEqual(AppNavigation.shared.selection, section, "the window is not switched")
        let again = await auto.tick()
        XCTAssertNil(again, "each interview once")
    }

    func testTypedSetupIsNeverReplaced() async {
        controller.candidateName = "Someone Typed"
        let prepared = await auto.tick()
        XCTAssertNil(prepared)
        XCTAssertEqual(controller.candidateName, "Someone Typed")
    }

    func testAnUntouchedAutomaticSetupMovesOnToTheNextInterview() async {
        await auto.tick()
        clock = clock.addingTimeInterval(3 * 3600)
        let next = await auto.tick()
        XCTAssertEqual(next?.externalID, "b")
        XCTAssertEqual(controller.candidateName, "Max Roe")
    }

    func testAnEditedAutomaticSetupIsKept() async {
        await auto.tick()
        controller.resumeText = "Pasted by the interviewer"
        clock = clock.addingTimeInterval(3 * 3600)
        let next = await auto.tick()
        XCTAssertNil(next)
        XCTAssertEqual(controller.candidateName, "Jane Doe")
    }

    func testAnInterviewAboutToStartIsNotSwappedForTheNextOne() async throws {
        // Back to back with a 30-minute lead: at A's start, B is already "due".
        source.gap = 30 * 60
        await manager.sync(.calendly)
        auto.leadMinutes = { 30 }
        let first = await auto.tick()
        XCTAssertEqual(first?.externalID, "a")
        clock = clock.addingTimeInterval(9 * 60)    // A started a minute ago; the candidate is late
        let next = await auto.tick()
        XCTAssertNil(next)
        XCTAssertEqual(controller.candidateName, "Jane Doe", "A stays until it has ended")
    }

    func testTypingDuringTheDownloadWins() async throws {
        source.delay = 300_000_000
        let run = Task { await self.auto.tick() }
        try await Task.sleep(nanoseconds: 80_000_000)
        controller.resumeText = "Pasted by the interviewer"
        let prepared = await run.value
        XCTAssertNil(prepared)
        XCTAssertEqual(controller.resumeText, "Pasted by the interviewer")
        XCTAssertTrue(controller.candidateName.isEmpty, "nothing half-written")
    }

    func testAManualPrepareInProgressIsLeftAlone() async throws {
        source.delay = 300_000_000
        let b = manager.upcoming[1]
        let manual = Task { await self.manager.prepare(b, controller: self.controller, roles: self.roles, navigate: false) }
        try await Task.sleep(nanoseconds: 80_000_000)
        let automatic = await auto.tick()
        XCTAssertNil(automatic, "the setup is being prepared by hand")
        _ = await manual.value
        XCTAssertEqual(controller.candidateName, "Max Roe")
    }

    func testThePreparedMeetingOpensOnceAMinuteBeforeItStarts() async {
        source.withLink = true
        await manager.sync(.calendly)
        var opened: [URL] = []
        auto.openLink = { opened.append($0) }
        await auto.tick()                                   // prepared at T-8 min
        XCTAssertTrue(opened.isEmpty, "off by default")
        auto.joinsAutomatically = true
        await auto.tick()
        XCTAssertTrue(opened.isEmpty, "too early")
        clock = clock.addingTimeInterval(7 * 60)            // 60 s before the start
        await auto.tick()
        await auto.tick()
        XCTAssertEqual(opened.map(\.host), ["acme.zoom.us"], "once")
    }

    func testAManualJoinIsNotRepeated() async {
        source.withLink = true
        await manager.sync(.calendly)
        var opened = 0
        auto.openLink = { _ in opened += 1 }
        auto.joinsAutomatically = true
        await auto.tick()
        auto.markJoined("calendly:a")
        clock = clock.addingTimeInterval(7 * 60)
        await auto.tick()
        XCTAssertEqual(opened, 0)
    }

    func testARefusedRunDoesNotBlockLaterOnes() async throws {
        source.delay = 300_000_000
        let run = Task { await self.auto.tick() }
        try await Task.sleep(nanoseconds: 80_000_000)
        editingRoles = true                       // Roles opened mid-way: this run is refused
        let refused = await run.value
        XCTAssertNil(refused)
        XCTAssertNil(controller.preparedFrom, "no half-made setup is left marked as A's")
        editingRoles = false
        source.delay = 0
        clock = clock.addingTimeInterval(3 * 3600)
        let next = await auto.tick()
        XCTAssertEqual(next?.externalID, "b", "automation carries on")
    }

    func testTheFirstRoleIsMadeAndSelectedOnAFirstRun() async throws {
        source.withJob = true
        await manager.sync(.calendly)
        XCTAssertNil(roles.selectedRoleID)
        let prepared = await auto.tick()
        XCTAssertEqual(prepared?.externalID, "a", "the role Prepare made for itself is not a change by the interviewer")
        XCTAssertEqual(roles.selectedRole?.name, "Backend Engineer")
    }

    func testWithNoEndTimeTheNextInterviewWithinTheHourIsStillPrepared() async throws {
        source.gap = 30 * 60
        await manager.sync(.calendly)
        await auto.tick()                                    // A at T+8
        clock = clock.addingTimeInterval(34 * 60)            // B (T+38) starts in 4 min; A was never run
        let next = await auto.tick()
        XCTAssertEqual(next?.externalID, "b")
    }

    func testWhatIsTypedDuringAManualPrepareIsKept() async throws {
        source.delay = 300_000_000
        let a = manager.upcoming[0]
        let manual = Task { await self.manager.prepare(a, controller: self.controller, roles: self.roles, navigate: false) }
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(controller.candidateName, "Jane Doe", "a manual Prepare shows the candidate at once")
        controller.candidateName = "Jane Q. Doe"
        _ = await manual.value
        XCTAssertEqual(controller.candidateName, "Jane Q. Doe", "the interviewer's correction stays")
    }

    func testARefusalIsSaidOnItsOwn() async {
        controller.pendingScoring = ["q1"]
        let said = await InterviewAutomation.prepare(manager.upcoming[0], manager: manager, controller: controller)
        XCTAssertEqual(said, ConnectorManager.waitForScores, "not \"Prepared …\"")
        XCTAssertEqual(controller.errorMessage, ConnectorManager.waitForScores, "shown in the setup too")
        controller.pendingScoring = []
    }

    func testOffOrWhileEditingRolesNothingHappens() async {
        editingRoles = true
        let whileEditing = await auto.tick()
        XCTAssertNil(whileEditing)
        editingRoles = false
        auto.isEnabled = false
        let whileOff = await auto.tick()
        XCTAssertNil(whileOff)
        XCTAssertTrue(controller.candidateName.isEmpty)
    }

    func testDueWindow() {
        let now = Date()
        let soon = ExternalInterview(source: .calendly, externalID: "s", title: "Interview", startsAt: now.addingTimeInterval(9 * 60))
        let later = ExternalInterview(source: .calendly, externalID: "l", title: "Interview", startsAt: now.addingTimeInterval(40 * 60))
        let late = ExternalInterview(source: .calendly, externalID: "x", title: "Interview", startsAt: now.addingTimeInterval(-3 * 60))
        XCTAssertEqual(AutoPrepare.due([late, soon, later], now: now, leadMinutes: 10, prepared: [])?.externalID, "x",
                       "a few minutes late still counts")
        XCTAssertEqual(AutoPrepare.due([late, soon, later], now: now, leadMinutes: 10, prepared: [late.id])?.externalID, "s")
        XCTAssertNil(AutoPrepare.due([later], now: now, leadMinutes: 10, prepared: []))
    }
}

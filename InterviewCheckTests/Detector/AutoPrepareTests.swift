import XCTest
import InterviewCheckConnectors
@testable import InterviewCheck

private struct TwoInterviews: InterviewSource {
    let kind = ConnectorKind.calendly
    let first: Date
    func verify() async throws -> String { "lee@acme.com" }
    func upcomingInterviews(from: Date, to: Date) async throws -> [ExternalInterview] {
        [ExternalInterview(source: .calendly, externalID: "a", title: "Phone Screen", startsAt: first,
                           candidate: ExternalCandidate(name: "Jane Doe", email: "jane@example.com")),
         ExternalInterview(source: .calendly, externalID: "b", title: "Phone Screen", startsAt: first.addingTimeInterval(3600),
                           candidate: ExternalCandidate(name: "Max Roe", email: "max@example.com"))]
    }
}

@MainActor
final class AutoPrepareTests: XCTestCase {
    private var path: String!
    private var manager: ConnectorManager!
    private var controller: InterviewController!
    private var auto: AutoPrepare!
    private var clock = Date()
    private var editingRoles = false

    override func setUp() async throws {
        path = NSTemporaryDirectory() + "autoprepare-\(UUID().uuidString).sqlite"
        let database = SessionDatabase(databasePath: path)
        let defaults = UserDefaults(suiteName: "autoprepare.\(UUID().uuidString)")!
        manager = ConnectorManager(store: MemoryCredentialStore(), database: database, defaults: defaults)
        let first = clock.addingTimeInterval(8 * 60)
        manager.factory = { _, _, _, _ in TwoInterviews(first: first) }
        try await manager.connect(.calendly, fields: ["apiKey": "k"])
        controller = InterviewController(timeline: InterviewTimeline(), database: database, settings: DetectorSettings(defaults: defaults))
        auto = AutoPrepare(manager: manager, controller: controller, roles: RoleStore(database: database, defaults: defaults),
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
        clock = clock.addingTimeInterval(3600)
        let next = await auto.tick()
        XCTAssertEqual(next?.externalID, "b")
        XCTAssertEqual(controller.candidateName, "Max Roe")
    }

    func testAnEditedAutomaticSetupIsKept() async {
        await auto.tick()
        controller.resumeText = "Pasted by the interviewer"
        clock = clock.addingTimeInterval(3600)
        let next = await auto.tick()
        XCTAssertNil(next)
        XCTAssertEqual(controller.candidateName, "Jane Doe")
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

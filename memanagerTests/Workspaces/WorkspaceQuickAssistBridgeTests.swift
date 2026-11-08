import XCTest
@testable import memanager

@MainActor
final class WorkspaceQuickAssistBridgeTests: XCTestCase {
    private var database: SessionDatabase!
    private var databasePath: String!
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: WorkspaceStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databasePath = NSTemporaryDirectory() + "bridge-\(UUID().uuidString).sqlite"
        database = SessionDatabase(databasePath: databasePath)
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bridge-root-\(UUID().uuidString)", isDirectory: true)
        suiteName = "bridge-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = WorkspaceStore(database: database, provisioner: WorkspaceFolderProvisioner(rootDirectory: root), defaults: defaults)
    }

    override func tearDown() {
        defer { super.tearDown() }
        defaults.removePersistentDomain(forName: suiteName)
        weak var remainingDatabase = database
        store = nil
        database = nil
        guard remainingDatabase == nil else {
            XCTFail("A workspace operation still retains the database; keeping its temporary files")
            return
        }
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: databasePath + suffix) }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeBridge() -> WorkspaceQuickAssistBridge {
        WorkspaceQuickAssistBridge(
            store: store,
            composer: WorkspaceContextComposer(database: database),
            recorder: WorkspaceJournalRecorder(database: database),
            settings: .shared
        )
    }

    func testJournalEntryLandsInTheWorkspaceTheTurnRanWithNotTheCurrentOne() throws {
        let first = try store.createWorkspace(name: "First", company: "A", role: "SWE")
        let second = try store.createWorkspace(name: "Second", company: "B", role: "SWE")
        store.setActive(second.id)
        let bridge = makeBridge()
        let response = String(repeating: "Use a heap. ", count: 20)

        bridge.recordProblemSolved(workspaceID: first.id, question: "Top k?", response: response, sessionID: nil, threadID: "t", turnID: "u")

        XCTAssertEqual(database.countWorkspaceJournalEntries(workspaceID: first.id), 1)
        XCTAssertEqual(database.countWorkspaceJournalEntries(workspaceID: second.id), 0)
        XCTAssertEqual(store.journal[first.id]?.count, 1, "the store cache is refreshed for the right workspace")
    }

    func testNilWorkspaceAndShortResponsesAreIgnored() throws {
        let workspace = try store.createWorkspace(name: "Only", company: "A", role: "SWE")
        let bridge = makeBridge()
        bridge.recordProblemSolved(workspaceID: nil, question: "q", response: String(repeating: "x", count: 200), sessionID: nil, threadID: nil, turnID: nil)
        bridge.recordProblemSolved(workspaceID: workspace.id, question: "q", response: "too short", sessionID: nil, threadID: nil, turnID: nil)
        XCTAssertEqual(database.countWorkspaceJournalEntries(workspaceID: workspace.id), 0)
    }

    func testContextBlockIsEmptyWithoutAnActiveWorkspaceAndDescribesTheActiveOne() throws {
        let bridge = makeBridge()
        XCTAssertEqual(bridge.contextBlock(question: "anything"), "")
        let workspace = try store.createWorkspace(name: "", company: "Stripe", role: "Staff Engineer")
        store.setActive(workspace.id)
        let block = bridge.contextBlock(question: "payments")
        XCTAssertTrue(block.hasPrefix("JOB WORKSPACE CONTEXT:"))
        XCTAssertTrue(block.contains("Company: Stripe"))
    }

    func testSetActiveRecordsLastOpenedInMemoryAndOnDisk() throws {
        let workspace = try store.createWorkspace(name: "Acme", company: "Acme", role: "SWE")
        XCTAssertNotNil(store.workspace(id: workspace.id)?.lastOpenedAt)
        let stored = try XCTUnwrap(database.loadJobWorkspace(id: workspace.id))
        XCTAssertNotNil(stored.lastOpenedAt)
        // A metadata edit must not clear it.
        var edited = try XCTUnwrap(store.workspace(id: workspace.id))
        edited.lastOpenedAt = nil
        edited.notes = "edited"
        store.update(edited)
        XCTAssertNotNil(database.loadJobWorkspace(id: workspace.id)?.lastOpenedAt)
    }
}

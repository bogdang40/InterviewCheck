import Combine
import XCTest
@testable import memanager

/// Store transitions that used to desync the list, the active selection,
/// or the database: edits arriving after a delete, imports of archived
/// folders, and activation of archived ids.
@MainActor
final class WorkspaceStoreLifecycleTests: XCTestCase {
    private var database: SessionDatabase!
    private var databasePath: String!
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: WorkspaceStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databasePath = NSTemporaryDirectory() + "store-lifecycle-\(UUID().uuidString).sqlite"
        database = SessionDatabase(databasePath: databasePath)
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("store-root-\(UUID().uuidString)", isDirectory: true)
        suiteName = "store-lifecycle-\(UUID().uuidString)"
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

    func testEditArrivingAfterDeleteIsDroppedInsteadOfResurrectingTheRow() throws {
        var workspace = try store.createWorkspace(name: "Gone", company: "Acme", role: "SWE")
        store.delete(workspace.id, moveFolderToTrash: false)
        XCTAssertNil(store.workspace(id: workspace.id))

        workspace.notes = "typed just before delete"
        store.update(workspace)

        XCTAssertNil(store.workspace(id: workspace.id), "a debounced commit must not append the workspace back")
        XCTAssertNil(database.loadJobWorkspace(id: workspace.id), "and must not re-insert the row")
    }

    func testImportingAnArchivedWorkspaceFolderUnarchivesItAndKeepsIdentity() async throws {
        let active = try store.createWorkspace(name: "Active", company: "A", role: "SWE")
        let archived = try store.createWorkspace(name: "Archived", company: "B", role: "SWE")
        store.setArchived(archived.id, archived: true)
        store.setActive(active.id)

        let indexingFinished = expectation(description: "Imported workspace finishes indexing")
        let observation = store.$indexReports.first { $0[archived.id] != nil }.sink { _ in
            indexingFinished.fulfill()
        }
        defer { observation.cancel() }

        let imported = try store.importFolder(archived.folderURL)

        XCTAssertEqual(imported.id, archived.id, "the manifest identity is kept")
        XCTAssertFalse(imported.isArchived)
        XCTAssertEqual(store.activeWorkspaceID, imported.id, "an import activates what was imported")
        XCTAssertEqual(database.loadJobWorkspace(id: archived.id)?.isArchived, false)
        await fulfillment(of: [indexingFinished], timeout: 2)
    }

    func testActivatingAnArchivedOrUnknownIdLeavesTheActiveWorkspaceAlone() throws {
        let active = try store.createWorkspace(name: "Active", company: "A", role: "SWE")
        let archived = try store.createWorkspace(name: "Archived", company: "B", role: "SWE")
        store.setArchived(archived.id, archived: true)
        store.setActive(active.id)

        store.setActive(archived.id)
        XCTAssertEqual(store.activeWorkspaceID, active.id)
        store.setActive(UUID())
        XCTAssertEqual(store.activeWorkspaceID, active.id)
        XCTAssertEqual(defaults.string(forKey: WorkspaceStore.activeWorkspaceKey), active.id.uuidString)

        store.setActive(nil)
        XCTAssertNil(store.activeWorkspaceID)
        XCTAssertNil(defaults.string(forKey: WorkspaceStore.activeWorkspaceKey))
    }

    func testArchivingTheActiveWorkspaceClearsTheSelection() throws {
        let workspace = try store.createWorkspace(name: "Only", company: "A", role: "SWE")
        XCTAssertEqual(store.activeWorkspaceID, workspace.id)
        store.setArchived(workspace.id, archived: true)
        XCTAssertNil(store.activeWorkspaceID)
    }

    func testFailedMetadataSaveRetainsDraftAndDoesNotArchiveActiveWorkspace() throws {
        var workspace = try store.createWorkspace(name: "Draft", company: "A", role: "SWE")
        workspace.notes = "Unsaved notes"
        database.executeSQL("PRAGMA query_only = ON")
        XCTAssertFalse(store.update(workspace))
        XCTAssertEqual(store.metadataDrafts[workspace.id]?.notes, "Unsaved notes")
        XCTAssertNotNil(store.lastError)
        store.setArchived(workspace.id, archived: true)
        XCTAssertEqual(store.activeWorkspaceID, workspace.id)
        XCTAssertEqual(store.workspace(id: workspace.id)?.isArchived, false)
    }

    func testManualJournalSaveReportsFailureToItsEditor() throws {
        let workspace = try store.createWorkspace(name: "Journal", company: "A", role: "SWE")
        database.executeSQL("PRAGMA query_only = ON")
        XCTAssertThrowsError(try store.addJournalEntry(kind: .note, title: "Retained", body: "Keep the typed body", to: workspace.id))
        XCTAssertTrue(database.loadWorkspaceJournal(workspaceID: workspace.id).isEmpty)
    }
}

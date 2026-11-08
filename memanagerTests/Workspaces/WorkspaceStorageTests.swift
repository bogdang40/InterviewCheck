import XCTest
@testable import memanager

final class WorkspaceStorageTests: XCTestCase {
    private var database: SessionDatabase!
    private var databasePath: String!

    override func setUp() {
        super.setUp()
        databasePath = NSTemporaryDirectory() + "workspace-storage-\(UUID().uuidString).sqlite"
        database = SessionDatabase(databasePath: databasePath)
    }

    override func tearDown() {
        database = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databasePath + suffix)
        }
        super.tearDown()
    }

    func testWorkspaceRoundTripsEveryField() throws {
        let workspace = JobWorkspace(
            name: "Stripe Staff",
            company: "Stripe",
            role: "Staff Engineer",
            status: .interviewing,
            folderPath: "/tmp/stripe",
            folderBookmark: Data([1, 2, 3]),
            jobDescriptionSummary: "Payments infra",
            notes: "Recruiter: Sam",
            tags: ["payments", "go"],
            lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try database.upsertJobWorkspace(workspace)

        let loaded = try XCTUnwrap(database.loadJobWorkspace(id: workspace.id))
        XCTAssertEqual(loaded.name, "Stripe Staff")
        XCTAssertEqual(loaded.status, .interviewing)
        XCTAssertEqual(loaded.folderBookmark, Data([1, 2, 3]))
        XCTAssertEqual(loaded.tags, ["payments", "go"])
        XCTAssertEqual(loaded.jobDescriptionSummary, "Payments infra")
        XCTAssertEqual(loaded.lastOpenedAt?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.001)
        XCTAssertFalse(loaded.isArchived)
    }

    func testArchivedWorkspacesAreHiddenUnlessRequested() throws {
        var archived = JobWorkspace(name: "Old", folderPath: "/tmp/old")
        archived.isArchived = true
        try database.upsertJobWorkspace(archived)
        try database.upsertJobWorkspace(JobWorkspace(name: "Live", folderPath: "/tmp/live"))

        XCTAssertEqual(database.loadJobWorkspaces().map(\.name), ["Live"])
        XCTAssertEqual(Set(database.loadJobWorkspaces(includeArchived: true).map(\.name)), ["Old", "Live"])
    }

    func testDocumentsUpsertByPathAndRemoveVanished() throws {
        let workspace = JobWorkspace(name: "Acme", folderPath: "/tmp/acme")
        try database.upsertJobWorkspace(workspace)
        let first = WorkspaceDocument(workspaceID: workspace.id, relativePath: "Job Description/jd.md", kind: .markdown, category: .jobDescription, byteSize: 10, sha256: "a", extractedText: "Build payments")
        try database.upsertWorkspaceDocument(first)
        var changed = first
        changed.sha256 = "b"
        changed.extractedText = "Build payments at scale"
        try database.upsertWorkspaceDocument(changed)
        try database.upsertWorkspaceDocument(WorkspaceDocument(workspaceID: workspace.id, relativePath: "Notes/x.txt", kind: .text, category: .notes, byteSize: 1, sha256: "c"))

        var documents = database.loadWorkspaceDocuments(workspaceID: workspace.id)
        XCTAssertEqual(documents.count, 2)
        XCTAssertEqual(documents.first(where: { $0.relativePath == "Job Description/jd.md" })?.extractedText, "Build payments at scale")

        try database.deleteWorkspaceDocuments(workspaceID: workspace.id, relativePaths: ["Notes/x.txt"])
        documents = database.loadWorkspaceDocuments(workspaceID: workspace.id)
        XCTAssertEqual(documents.map(\.relativePath), ["Job Description/jd.md"])
    }

    func testJournalOrdersNewestFirstAndDeleteCascades() throws {
        let workspace = JobWorkspace(name: "Acme", folderPath: "/tmp/acme")
        try database.upsertJobWorkspace(workspace)
        let older = WorkspaceJournalEntry(workspaceID: workspace.id, kind: .note, title: "older", body: "b", createdAt: Date(timeIntervalSince1970: 10))
        let newer = WorkspaceJournalEntry(workspaceID: workspace.id, kind: .problemSolved, title: "newer", body: "b", threadID: "t", turnID: "u", createdAt: Date(timeIntervalSince1970: 20))
        try database.insertWorkspaceJournalEntry(older)
        try database.insertWorkspaceJournalEntry(newer)

        XCTAssertEqual(database.loadWorkspaceJournal(workspaceID: workspace.id).map(\.title), ["newer", "older"])
        XCTAssertEqual(database.countWorkspaceJournalEntries(workspaceID: workspace.id), 2)

        try database.deleteJobWorkspace(id: workspace.id)
        XCTAssertNil(database.loadJobWorkspace(id: workspace.id))
        XCTAssertEqual(database.countWorkspaceJournalEntries(workspaceID: workspace.id), 0)
        XCTAssertEqual(database.countWorkspaceDocuments(workspaceID: workspace.id), 0)
    }
}

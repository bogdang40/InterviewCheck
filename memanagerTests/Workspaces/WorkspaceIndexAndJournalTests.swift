import XCTest
@testable import memanager

final class WorkspaceIndexAndJournalTests: XCTestCase {
    private var database: SessionDatabase!
    private var databasePath: String!
    private var folder: URL!
    private var workspace: JobWorkspace!

    override func setUpWithError() throws {
        try super.setUpWithError()
        databasePath = NSTemporaryDirectory() + "workspace-index-\(UUID().uuidString).sqlite"
        database = SessionDatabase(databasePath: databasePath)
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ws-index-\(UUID().uuidString)", isDirectory: true)
        workspace = JobWorkspace(name: "Acme", company: "Acme", role: "SWE", folderPath: folder.path)
        try WorkspaceFolderProvisioner(rootDirectory: folder.deletingLastPathComponent()).adopt(existingFolder: {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }(), for: workspace)
        try database.upsertJobWorkspace(workspace)
    }

    override func tearDown() {
        database = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: databasePath + suffix) }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func write(_ text: String, to relativePath: String) throws {
        let url = folder.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testIndexerExtractsTextSkipsUnchangedAndRemovesVanished() throws {
        try write("# Senior Payments Engineer\nOwn the ledger service.", to: "Job Description/jd.md")
        try write("Notes about the recruiter call", to: "Notes/call.txt")
        let indexer = WorkspaceDocumentIndexer(database: database)

        let first = indexer.index(workspace)
        XCTAssertEqual(first.scanned, 2)
        XCTAssertEqual(first.updated, 2)
        XCTAssertTrue(first.failures.isEmpty)
        let documents = database.loadWorkspaceDocuments(workspaceID: workspace.id)
        let jd = try XCTUnwrap(documents.first(where: { $0.relativePath == "Job Description/jd.md" }))
        XCTAssertEqual(jd.category, .jobDescription)
        XCTAssertEqual(jd.kind, .markdown)
        XCTAssertTrue(jd.extractedText?.contains("ledger service") ?? false)

        let second = indexer.index(workspace)
        XCTAssertEqual(second.updated, 0, "unchanged files must not be re-extracted")
        XCTAssertEqual(second.skipped, 2)

        try FileManager.default.removeItem(at: folder.appendingPathComponent("Notes/call.txt"))
        let third = indexer.index(workspace)
        XCTAssertEqual(third.removed, 1)
        XCTAssertEqual(database.loadWorkspaceDocuments(workspaceID: workspace.id).map(\.relativePath), ["Job Description/jd.md"])
    }

    func testIndexerIgnoresManifestAndReadme() throws {
        let report = WorkspaceDocumentIndexer(database: database).index(workspace)
        XCTAssertEqual(report.scanned, 0)
    }

    func testIndexerSkipsDependencyTreesButKeepsNestedReadmes() throws {
        try write("# My project\nBuilt a ledger.", to: "Projects/ledger/README.md")
        try write("{}", to: "Projects/ledger/node_modules/pkg/package.json")
        try write("bin", to: "Projects/ledger/build/out.txt")
        try write("{\\rtf1 hidden}", to: "Notes/legacy.rtf")

        let report = WorkspaceDocumentIndexer(database: database).index(workspace)
        let paths = database.loadWorkspaceDocuments(workspaceID: workspace.id).map(\.relativePath)
        XCTAssertTrue(paths.contains("Projects/ledger/README.md"), "a project README is real content")
        XCTAssertFalse(paths.contains { $0.contains("node_modules") || $0.contains("/build/") })
        XCTAssertEqual(report.scanned, 2)
        let rtf = try XCTUnwrap(database.loadWorkspaceDocuments(workspaceID: workspace.id).first { $0.relativePath.hasSuffix(".rtf") })
        XCTAssertEqual(rtf.kind, .other)
        XCTAssertFalse(rtf.hasText, "raw RTF control words must never reach the prompt")
    }

    func testJournalRecorderWritesRowAndMarkdown() throws {
        let recorder = WorkspaceJournalRecorder(database: database)
        let response = String(repeating: "Use a sliding window over the stream and keep a heap of the top k. ", count: 40)
        let entry = try XCTUnwrap(recorder.recordProblemSolved(
            workspace: workspace,
            question: "How would you find the top k events in a stream?",
            response: response,
            sessionID: "s", threadID: "t", turnID: "u",
            now: Date(timeIntervalSince1970: 1_756_800_000)
        ))
        XCTAssertEqual(entry.kind, .problemSolved)
        XCTAssertEqual(entry.title, "How would you find the top k events in a stream?")
        XCTAssertLessThanOrEqual(entry.body.count, WorkspaceJournalRecorder.maxBodyCharacters + 20)
        XCTAssertTrue(entry.body.hasSuffix("(condensed)"))

        let stored = database.loadWorkspaceJournal(workspaceID: workspace.id)
        XCTAssertEqual(stored.map(\.id), [entry.id])

        let journalFolder = folder.appendingPathComponent("Journal")
        let files = try FileManager.default.contentsOfDirectory(atPath: journalFolder.path)
        XCTAssertEqual(files.count, 1)
        let contents = try String(contentsOf: journalFolder.appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertTrue(contents.contains("Problem Solved: How would you find the top k"))
    }

    func testJournalRecorderAppendsToTheSameDayFileWithoutClobbering() throws {
        let recorder = WorkspaceJournalRecorder(database: database)
        let day = Date(timeIntervalSince1970: 1_756_800_000)
        let long = String(repeating: "Answer text. ", count: 20)
        recorder.recordProblemSolved(workspace: workspace, question: "First question here", response: long, sessionID: nil, threadID: nil, turnID: nil, now: day)
        recorder.recordProblemSolved(workspace: workspace, question: "Second question here", response: long, sessionID: nil, threadID: nil, turnID: nil, now: day.addingTimeInterval(60))

        let journalFolder = folder.appendingPathComponent("Journal")
        let files = try FileManager.default.contentsOfDirectory(atPath: journalFolder.path)
        XCTAssertEqual(files.count, 1)
        let contents = try String(contentsOf: journalFolder.appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertTrue(contents.contains("First question here"))
        XCTAssertTrue(contents.contains("Second question here"))
        XCTAssertEqual(contents.components(separatedBy: "# Journal ").count, 2, "the header is written once")
    }

    func testJournalRecorderSkipsEmptyResponses() {
        let recorder = WorkspaceJournalRecorder(database: database)
        XCTAssertNil(recorder.recordProblemSolved(workspace: workspace, question: "q", response: "   ", sessionID: nil, threadID: nil, turnID: nil))
    }
}

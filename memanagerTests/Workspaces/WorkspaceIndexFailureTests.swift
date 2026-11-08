import XCTest
@testable import memanager

final class WorkspaceIndexFailureTests: XCTestCase {
    private var directory: URL!
    private var database: SessionDatabase!
    private var workspace: JobWorkspace!
    private var file: URL!
    private var extractor: RetryingWorkspaceExtractor!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        database = SessionDatabase(databasePath: directory.appendingPathComponent("index.sqlite").path)
        workspace = JobWorkspace(name: "Test", folderPath: folder.path)
        try database.upsertJobWorkspace(workspace)
        file = folder.appendingPathComponent("notes.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        extractor = RetryingWorkspaceExtractor()
    }

    override func tearDownWithError() throws {
        database = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testFailedExtractionPreservesPreviousTextAndRetriesUnchangedFile() throws {
        let indexer = WorkspaceDocumentIndexer(database: database, extractor: extractor)
        XCTAssertEqual(indexer.index(workspace).updated, 1)
        try "updated file contents".write(to: file, atomically: true, encoding: .utf8)
        extractor.shouldFail = true
        let failed = indexer.index(workspace)
        XCTAssertEqual(failed.updated, 0)
        XCTAssertTrue(failed.failures.contains { $0.contains("temporary extraction failure") })
        XCTAssertEqual(try document().extractedText, "original")

        extractor.shouldFail = false
        XCTAssertEqual(indexer.index(workspace).updated, 1)
        XCTAssertEqual(try document().extractedText, "updated file contents")
    }

    func testLegacyMissingTextRetriesDespiteUnchangedMetadata() throws {
        let indexer = WorkspaceDocumentIndexer(database: database, extractor: extractor)
        _ = indexer.index(workspace)
        try execute("UPDATE workspace_documents SET extracted_text = NULL")
        let report = indexer.index(workspace)
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(extractor.calls, 2)
        XCTAssertEqual(try document().extractedText, "original")
    }

    func testSuccessfulEmptyExtractionDoesNotRetryForever() throws {
        try "".write(to: file, atomically: true, encoding: .utf8)
        let indexer = WorkspaceDocumentIndexer(database: database, extractor: extractor)
        XCTAssertEqual(indexer.index(workspace).updated, 1)
        XCTAssertEqual(indexer.index(workspace).skipped, 1)
        XCTAssertEqual(extractor.calls, 1)
    }

    func testEnumerationFailureKeepsPreviouslyIndexedRows() throws {
        _ = WorkspaceDocumentIndexer(database: database, extractor: extractor).index(workspace)
        // A regular file is an existing but unreadable directory root. This
        // exercises Foundation's real enumeration error callback safely.
        workspace.folderPath = file.path
        let indexer = WorkspaceDocumentIndexer(database: database, extractor: extractor)
        let report = indexer.index(workspace)
        XCTAssertEqual(report.removed, 0)
        XCTAssertFalse(report.failures.isEmpty)
        XCTAssertEqual(try document().extractedText, "original")
    }

    func testFailedDatabaseCleanupIsReportedWithoutClaimingRemoval() throws {
        let indexer = WorkspaceDocumentIndexer(database: database, extractor: extractor)
        _ = indexer.index(workspace)
        try FileManager.default.removeItem(at: file)
        try execute("""
            CREATE TRIGGER prevent_document_delete BEFORE DELETE ON workspace_documents
            BEGIN SELECT RAISE(ABORT, 'index locked'); END
            """)
        let report = indexer.index(workspace)
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(report.failures.contains { $0.contains("index locked") })
        XCTAssertEqual(try document().extractedText, "original")
    }

    private func document() throws -> WorkspaceDocument {
        try XCTUnwrap(database.loadWorkspaceDocuments(workspaceID: workspace.id).first)
    }

    private func execute(_ sql: String) throws {
        try database.performSyncThrowing { db in
            let statement = try SQLiteStatement(db: db, sql: sql)
            try statement.executeStep()
        }
    }
}

private final class RetryingWorkspaceExtractor: ModeTextExtracting {
    var shouldFail = false
    var calls = 0

    func extract(from url: URL, kind: ModeAttachmentKind) throws -> ExtractedText {
        calls += 1
        if shouldFail { throw ModeTextExtractorError.unreadable(reason: "temporary extraction failure") }
        return ExtractedText(raw: try String(contentsOf: url, encoding: .utf8), truncated: false, pageCount: nil)
    }
}

import Combine
import XCTest
@testable import memanager

@MainActor
final class WorkspaceReindexFreshnessTests: XCTestCase {
    func testFolderMovedBeforeScanVerifiesContentsAndRetriesFailedVerification() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original")
        let replacement = directory.appendingPathComponent("replacement")
        try write("original", in: original)
        try write("changed!", in: replacement)
        let database = SessionDatabase(databasePath: directory.appendingPathComponent("reindex.sqlite").path)
        var workspace = JobWorkspace(name: "Test", folderPath: original.path)
        try database.upsertJobWorkspace(workspace)
        let extractor = FailableWorkspaceExtractor()
        let store = try makeStore(database: database, directory: directory, extractor: extractor)
        await store.reindex(workspace.id)
        await store.reindex(workspace.id)
        XCTAssertEqual(store.indexReports[workspace.id]?.skipped, 1, "An unchanged verified folder keeps its metadata fast path")

        workspace.folderPath = replacement.path
        XCTAssertTrue(store.update(workspace))
        extractor.shouldFail = true
        await store.reindex(workspace.id)
        XCTAssertFalse(try XCTUnwrap(store.indexReports[workspace.id]).failures.isEmpty)
        XCTAssertEqual(store.documents[workspace.id]?.first?.extractedText, "original")

        extractor.shouldFail = false
        await store.reindex(workspace.id)
        XCTAssertEqual(store.documents[workspace.id]?.first?.extractedText, "changed!")
        XCTAssertTrue(try XCTUnwrap(store.indexReports[workspace.id]).failures.isEmpty)
    }

    func testNewStoreVerifiesPersistedRowsAfterFolderMoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original")
        let replacement = directory.appendingPathComponent("replacement")
        try write("original", in: original)
        try write("changed!", in: replacement)
        let database = SessionDatabase(databasePath: directory.appendingPathComponent("reindex.sqlite").path)
        var workspace = JobWorkspace(name: "Test", folderPath: original.path)
        try database.upsertJobWorkspace(workspace)
        let extractor = FailableWorkspaceExtractor()
        _ = WorkspaceDocumentIndexer(database: database, extractor: extractor).index(workspace)
        workspace.folderPath = replacement.path
        try database.upsertJobWorkspace(workspace)

        let store = try makeStore(database: database, directory: directory, extractor: extractor)
        await store.reindex(workspace.id)
        XCTAssertEqual(store.documents[workspace.id]?.first?.extractedText, "changed!")
    }

    func testMovingBackToPreviousFolderDuringScanStillVerifiesItsContents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original")
        let replacement = directory.appendingPathComponent("replacement")
        try write("original", in: original)
        try write("changed!", in: replacement)
        let database = SessionDatabase(databasePath: directory.appendingPathComponent("reindex.sqlite").path)
        var workspace = JobWorkspace(name: "Test", folderPath: original.path)
        try database.upsertJobWorkspace(workspace)
        _ = WorkspaceDocumentIndexer(database: database, extractor: FailableWorkspaceExtractor()).index(workspace)
        let started = expectation(description: "replacement extraction started")
        let extractor = BlockingWorkspaceExtractor(started: started)
        defer { extractor.finish.signal() }
        let store = try makeStore(database: database, directory: directory, extractor: extractor)
        await store.reindex(workspace.id)
        workspace.folderPath = replacement.path
        XCTAssertTrue(store.update(workspace))
        let scan = Task { await store.reindex(workspace.id) }
        await fulfillment(of: [started], timeout: 2)

        workspace.folderPath = original.path
        XCTAssertTrue(store.update(workspace))
        await store.reindex(workspace.id)
        extractor.finish.signal()
        await scan.value
        XCTAssertEqual(store.documents[workspace.id]?.first?.extractedText, "original")
        XCTAssertEqual(extractor.callCount, 2)
    }

    func testMovingFolderDuringIndexingPublishesOnlyCurrentContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original")
        let replacement = directory.appendingPathComponent("replacement")
        try write("original", in: original)
        try write("changed!", in: replacement)
        let database = SessionDatabase(databasePath: directory.appendingPathComponent("reindex.sqlite").path)
        var workspace = JobWorkspace(name: "Test", folderPath: original.path)
        try database.upsertJobWorkspace(workspace)
        let started = expectation(description: "original extraction started")
        let extractor = BlockingWorkspaceExtractor(started: started)
        defer { extractor.finish.signal() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkspaceReindexFreshnessTests.\(UUID().uuidString)"))
        let store = WorkspaceStore(
            database: database,
            provisioner: WorkspaceFolderProvisioner(rootDirectory: directory),
            indexer: WorkspaceDocumentIndexer(database: database, extractor: extractor),
            defaults: defaults
        )
        var publishedTexts: [String] = []
        let observation = store.$documents.sink { documents in
            publishedTexts += documents[workspace.id, default: []].compactMap(\.extractedText)
        }
        defer { observation.cancel() }
        let scan = Task { await store.reindex(workspace.id) }
        await fulfillment(of: [started], timeout: 2)

        workspace.folderPath = replacement.path
        XCTAssertTrue(store.update(workspace))
        await store.reindex(workspace.id)
        await store.reindex(workspace.id)
        extractor.finish.signal()
        await scan.value

        XCTAssertEqual(store.documents[workspace.id]?.first?.extractedText, "changed!")
        XCTAssertFalse(publishedTexts.contains("original"))
        XCTAssertEqual(extractor.callCount, 2, "Requests during the old scan should coalesce into one replacement scan")
        XCTAssertFalse(store.indexingIDs.contains(workspace.id))
        XCTAssertTrue(store.pendingReindexIDs.isEmpty)
    }

    private func makeStore(database: SessionDatabase, directory: URL, extractor: ModeTextExtracting) throws -> WorkspaceStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkspaceReindexFreshnessTests.\(UUID().uuidString)"))
        return WorkspaceStore(
            database: database,
            provisioner: WorkspaceFolderProvisioner(rootDirectory: directory),
            indexer: WorkspaceDocumentIndexer(database: database, extractor: extractor),
            defaults: defaults
        )
    }

    private func write(_ text: String, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("notes.txt")
        try text.write(to: file, atomically: true, encoding: .utf8)
        // Equal size and mtime exercise root changes that metadata cannot detect.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: file.path)
    }
}

private final class FailableWorkspaceExtractor: ModeTextExtracting {
    var shouldFail = false

    func extract(from url: URL, kind: ModeAttachmentKind) throws -> ExtractedText {
        if shouldFail { throw ModeTextExtractorError.unreadable(reason: "temporary extraction failure") }
        return ExtractedText(raw: try String(contentsOf: url, encoding: .utf8), truncated: false, pageCount: nil)
    }
}

private final class BlockingWorkspaceExtractor: ModeTextExtracting {
    let finish = DispatchSemaphore(value: 0)
    private let started: XCTestExpectation
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    init(started: XCTestExpectation) {
        self.started = started
    }

    func extract(from url: URL, kind: ModeAttachmentKind) throws -> ExtractedText {
        let first = lock.withLock {
            calls += 1
            return calls == 1
        }
        if first {
            started.fulfill()
            guard finish.wait(timeout: .now() + 3) == .success else {
                throw ModeTextExtractorError.unreadable(reason: "test release timed out")
            }
        }
        return ExtractedText(raw: try String(contentsOf: url, encoding: .utf8), truncated: false, pageCount: nil)
    }
}

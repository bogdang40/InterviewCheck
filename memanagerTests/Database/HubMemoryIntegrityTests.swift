import XCTest
import SQLite3
@testable import memanager

final class HubMemoryIntegrityTests: XCTestCase {
    private var database: SessionDatabase!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = SessionDatabase(databasePath: directory.appendingPathComponent("memory.sqlite").path)
    }

    override func tearDownWithError() throws {
        database = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testFTSSearchPreservesSourceMetadata() throws {
        try requireFTS()
        database.upsertMemoryNode(makeNode())
        try assertSearchMetadata()
    }

    func testFallbackSearchPreservesSourceMetadata() throws {
        database.performSync { _ in database.memoryFTSSupported = false }
        database.upsertMemoryNode(makeNode())
        try assertSearchMetadata()
    }

    func testMissingFTSMirrorRollsBackNodeWrite() throws {
        try requireFTS()
        try execute("DROP TABLE memory_nodes_fts")
        database.upsertMemoryNode(makeNode())
        XCTAssertEqual(try countRows(in: "memory_nodes"), 0)
    }

    func testFTSDeleteFailureRollsBackNodeUpdate() throws {
        try requireFTS()
        database.upsertMemoryNode(makeNode())
        try execute("DROP TABLE memory_nodes_fts")
        try execute("CREATE TABLE memory_nodes_fts (node_id TEXT, content TEXT, summary TEXT, tags TEXT)")
        try execute("INSERT INTO memory_nodes_fts (node_id, content) VALUES ('node', 'original')")
        try execute("""
            CREATE TRIGGER prevent_mirror_delete BEFORE DELETE ON memory_nodes_fts
            BEGIN SELECT RAISE(ABORT, 'mirror locked'); END
            """)

        database.upsertMemoryNode(makeNode(content: "replacement"))

        let storedContent = try database.performSyncThrowing { db in
            let statement = try SQLiteStatement(db: db, sql: "SELECT content FROM memory_nodes WHERE id = 'node'")
            _ = try statement.stepRow()
            return statement.columnText(0)
        }
        XCTAssertEqual(storedContent, "original searchable memory")
        XCTAssertEqual(try countRows(in: "memory_nodes_fts"), 1)
    }

    private func assertSearchMetadata() throws {
        let node = try XCTUnwrap(database.searchMemoryNodes(query: "searchable").first?.node)
        XCTAssertEqual(node.threadId, "thread")
        XCTAssertEqual(node.turnId, "turn")
        XCTAssertEqual(node.questionSource, .manual)
        XCTAssertEqual(node.intent, "debug")
        XCTAssertEqual(node.contextMode, "conversation")
    }

    private func requireFTS() throws {
        let supported = database.performSync { _ in database.memoryFTSSupported }
        try XCTSkipUnless(supported, "SQLite runtime does not support FTS5")
    }

    private func execute(_ sql: String) throws {
        try database.performSyncThrowing { db in
            let statement = try SQLiteStatement(db: db, sql: sql)
            try statement.executeStep()
        }
    }

    private func countRows(in table: String) throws -> Int {
        // Table names are fixed fixture identifiers, never external input.
        try database.performSyncThrowing { db in
            let statement = try SQLiteStatement(db: db, sql: "SELECT COUNT(*) FROM \(table)")
            _ = try statement.stepRow()
            return statement.columnInt(0)
        }
    }

    private func makeNode(content: String = "original searchable memory") -> MemoryNodeRecord {
        MemoryNodeRecord(
            id: "node", sessionId: "session", sourceType: .quickAssist, sourceRef: "source",
            threadId: "thread", turnId: "turn", questionSource: .manual,
            intent: "debug", contextMode: "conversation", content: content,
            summary: nil, tags: ["tag"], importance: 1,
            createdAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 200)
        )
    }
}

import XCTest
@testable import memanager

/// Symbol skills (C#, C++) must be found by their exact label rather than
/// as the prefix "c", and a label known under one kind must not be
/// duplicated under another when the model changes its mind.
final class KnowledgeSymbolSearchTests: XCTestCase {
    private var database: SessionDatabase!
    private var databasePath: String!

    override func setUp() {
        super.setUp()
        databasePath = NSTemporaryDirectory() + "kg-symbol-\(UUID().uuidString).sqlite"
        database = SessionDatabase(databasePath: databasePath)
    }

    override func tearDown() {
        database = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: databasePath + suffix) }
        super.tearDown()
    }

    func testTokenSplitRoutesSymbolTokensAwayFromFTS() {
        let split = KnowledgeQueryTokenizer.splitForFTS(["know", "c#", "c++", "kafka"])
        XCTAssertEqual(split.fts, ["know", "kafka"])
        XCTAssertEqual(split.symbolic, ["c#", "c++"])
    }

    func testCSharpQuestionSeedsOnCSharpNotOnEveryCWord() throws {
        for (kind, label) in [(KnowledgeNodeKind.skill, "C#"), (.skill, "C++"), (.skill, "Cassandra"), (.skill, "Kafka"), (.company, "Coinbase")] {
            try database.upsertKnowledgeNode(KnowledgeNode(kind: kind, label: label))
        }

        let hits = database.searchKnowledgeNodes(text: "Do you know C#?", limit: 8)

        XCTAssertEqual(hits.first?.node.label, "C#", hits.map(\.node.label).joined(separator: ", "))
        XCTAssertFalse(hits.contains { $0.node.label == "Cassandra" }, "the prefix c must not pull in unrelated skills")
        XCTAssertFalse(hits.contains { $0.node.label == "Coinbase" })
    }

    func testMixedQuestionMergesSymbolAndWordHits() throws {
        try database.upsertKnowledgeNode(KnowledgeNode(kind: .skill, label: "C++"))
        try database.upsertKnowledgeNode(KnowledgeNode(kind: .project, label: "Kafka migration", summary: "Moved the ledger to Kafka"))
        try database.upsertKnowledgeNode(KnowledgeNode(kind: .topic, label: "Unrelated"))

        let labels = database.searchKnowledgeNodes(text: "C++ and Kafka experience", limit: 8).map(\.node.label)

        XCTAssertTrue(labels.contains("C++"), labels.joined(separator: ", "))
        XCTAssertTrue(labels.contains("Kafka migration"), labels.joined(separator: ", "))
        XCTAssertFalse(labels.contains("Unrelated"))
    }

    func testMergeKeepsTheHigherScorePerNodeAndOrdersBestFirst() {
        let a = KnowledgeNode(kind: .skill, label: "A")
        let b = KnowledgeNode(kind: .skill, label: "B")
        let merged = KnowledgeSeedScoring.merge(
            [KnowledgeSearchHit(node: a, score: 0.5), KnowledgeSearchHit(node: b, score: 0.9)],
            [KnowledgeSearchHit(node: a, score: 1.0)],
            limit: 5
        )
        XCTAssertEqual(merged.map(\.node.label), ["A", "B"])
        XCTAssertEqual(merged.first?.score, 1.0)
    }

    func testMergerFoldsALabelKnownUnderAnotherKindIntoTheStoredNode() throws {
        let stored = KnowledgeNode(kind: .company, label: "Stripe", summary: "Payments company")
        try database.upsertKnowledgeNode(stored)
        let merger = KnowledgeGraphMerger(database: database)
        let extracted = ExtractedKnowledge(
            nodes: [.init(kind: .topic, label: "Stripe", summary: nil), .init(kind: .person, label: "Me", summary: nil)],
            edges: [.init(from: "Me", to: "Stripe", relation: .workedAt, evidence: nil)]
        )

        let outcome = merger.merge(extracted, sourceKind: .session, sourceRef: "t1", workspaceID: nil)

        XCTAssertEqual(outcome.nodesCreated, 1, "only Me is new")
        XCTAssertEqual(outcome.nodesUpdated, 1)
        XCTAssertEqual(database.countKnowledgeNodes(), 2, "no shadow Stripe under topic")
        XCTAssertEqual(database.loadKnowledgeNode(id: stored.id)?.kind, .company, "the stored kind wins")
        XCTAssertEqual(database.loadKnowledgeNode(id: stored.id)?.mentionCount, 2)
        let edges = database.loadKnowledgeEdges(touching: [stored.id])
        XCTAssertEqual(edges.count, 1, "the relation lands on the real node")
    }

    func testFindByLabelIgnoresKind() throws {
        let node = KnowledgeNode(kind: .skill, label: "Go")
        try database.upsertKnowledgeNode(node)
        XCTAssertEqual(database.findKnowledgeNode(label: " go ")?.id, node.id)
        XCTAssertNil(database.findKnowledgeNode(label: "rust"))
    }
}

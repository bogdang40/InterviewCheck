import XCTest
@testable import memanager

final class KnowledgeStorageTests: XCTestCase {
    private var database: SessionDatabase!
    private var databasePath: String!

    override func setUp() {
        super.setUp()
        databasePath = NSTemporaryDirectory() + "kg-storage-\(UUID().uuidString).sqlite"
        database = SessionDatabase(databasePath: databasePath)
    }

    override func tearDown() {
        database = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: databasePath + suffix) }
        super.tearDown()
    }

    @MainActor
    func testEditorRejectsDuplicateWithoutReplacingTheSavedFact() throws {
        let saved = KnowledgeNode(kind: .skill, label: "C++", summary: "Original")
        try database.upsertKnowledgeNode(saved)
        let store = KnowledgeGraphStore(database: database)
        XCTAssertThrowsError(try store.saveForEditing(KnowledgeNode(kind: .skill, label: "c++", summary: "Duplicate draft")))
        XCTAssertEqual(database.countKnowledgeNodes(), 1)
        XCTAssertEqual(database.loadKnowledgeNode(id: saved.id)?.summary, "Original")
        XCTAssertEqual(store.selectedNodeID, saved.id)
    }

    @MainActor
    func testEditorSurfacesStorageFailureWithoutPublishingUnsavedFact() {
        let store = KnowledgeGraphStore(database: database)
        database.executeSQL("PRAGMA query_only = ON")
        let draft = KnowledgeNode(kind: .story, label: "Keep this draft")
        XCTAssertThrowsError(try store.saveForEditing(draft))
        XCTAssertNil(database.loadKnowledgeNode(id: draft.id))
        XCTAssertNil(store.selectedNodeID)
    }

    func testNodeRoundTripAndLookupByNormalizedLabel() throws {
        let node = KnowledgeNode(kind: .company, label: "Stripe, Inc.", summary: "Payments", properties: ["hq": "SF"], sourceKind: .workspace, sourceRef: "ws", confidence: 0.8, mentionCount: 3)
        try database.upsertKnowledgeNode(node)

        let loaded = try XCTUnwrap(database.loadKnowledgeNode(id: node.id))
        XCTAssertEqual(loaded.label, "Stripe, Inc.")
        XCTAssertEqual(loaded.properties, ["hq": "SF"])
        XCTAssertEqual(loaded.sourceKind, .workspace)
        XCTAssertEqual(loaded.mentionCount, 3)
        XCTAssertEqual(loaded.confidence, 0.8, accuracy: 0.0001)

        XCTAssertEqual(database.findKnowledgeNode(kind: .company, label: "  stripe inc ")?.id, node.id)
        XCTAssertNil(database.findKnowledgeNode(kind: .person, label: "Stripe Inc"))
        XCTAssertEqual(database.countKnowledgeNodes(), 1)
    }

    func testEdgeMergeGrowsWeightAndDeleteNodeCascades() throws {
        let me = KnowledgeNode(kind: .person, label: "Me")
        let kafka = KnowledgeNode(kind: .skill, label: "Kafka")
        try database.upsertKnowledgeNode(me)
        try database.upsertKnowledgeNode(kafka)
        try database.upsertKnowledgeEdge(KnowledgeEdge(fromNodeID: me.id, toNodeID: kafka.id, relation: .usedSkill, weight: 1.0, evidence: "first"))
        try database.upsertKnowledgeEdge(KnowledgeEdge(fromNodeID: me.id, toNodeID: kafka.id, relation: .usedSkill, weight: 1.0, evidence: nil))

        let edges = database.loadKnowledgeEdges(touching: [me.id])
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].weight, 1.5, accuracy: 0.0001)
        XCTAssertEqual(edges[0].evidence, "first", "nil evidence must not erase stored evidence")
        XCTAssertEqual(database.countKnowledgeEdges(), 1)

        try database.deleteKnowledgeNode(id: kafka.id)
        XCTAssertEqual(database.countKnowledgeEdges(), 0)
        XCTAssertNil(database.loadKnowledgeNode(id: kafka.id))
        XCTAssertNotNil(database.loadKnowledgeNode(id: me.id))
    }

    func testSearchFindsByLabelAndSummary() throws {
        try database.upsertKnowledgeNode(KnowledgeNode(kind: .project, label: "Ledger migration", summary: "Moved the ledger to Kafka with idempotent consumers"))
        try database.upsertKnowledgeNode(KnowledgeNode(kind: .story, label: "Outage postmortem", summary: "Led the incident review after a cache stampede"))
        try database.upsertKnowledgeNode(KnowledgeNode(kind: .topic, label: "Unrelated"))

        let kafkaHits = database.searchKnowledgeNodes(text: "How did you use Kafka?", limit: 5)
        XCTAssertEqual(kafkaHits.first?.node.label, "Ledger migration")
        XCTAssertFalse(kafkaHits.contains { $0.node.label == "Unrelated" })

        let incidentHits = database.searchKnowledgeNodes(text: "tell me about an incident you led", limit: 5)
        XCTAssertEqual(incidentHits.first?.node.label, "Outage postmortem")
        XCTAssertTrue(database.searchKnowledgeNodes(text: "the and for", limit: 5).isEmpty, "stop words only yields nothing")
    }

    func testClearGraphRemovesEverything() throws {
        let a = KnowledgeNode(kind: .person, label: "A")
        let b = KnowledgeNode(kind: .person, label: "B")
        try database.upsertKnowledgeNode(a)
        try database.upsertKnowledgeNode(b)
        try database.upsertKnowledgeEdge(KnowledgeEdge(fromNodeID: a.id, toNodeID: b.id, relation: .workedWith))
        try database.clearKnowledgeGraph()
        XCTAssertEqual(database.countKnowledgeNodes(), 0)
        XCTAssertEqual(database.countKnowledgeEdges(), 0)
        XCTAssertTrue(database.searchKnowledgeNodes(text: "person", limit: 5).isEmpty)
    }
}

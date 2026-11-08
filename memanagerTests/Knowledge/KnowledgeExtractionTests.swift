import XCTest
@testable import memanager

final class KnowledgeExtractionTests: XCTestCase {
    func testParserAcceptsFencedJSONAndDropsInvalidEntries() {
        let raw = """
        Here you go:
        ```json
        {"nodes":[
          {"kind":"person","label":"Me"},
          {"kind":"company","label":"Stripe","summary":"Payments company"},
          {"kind":"dragon","label":"Nope"},
          {"kind":"skill","label":"   "},
          {"kind":"company","label":"stripe"}
        ],"edges":[
          {"from":"Me","to":"Stripe","relation":"worked_at","evidence":"2019 to 2023"},
          {"from":"Me","to":"Nope","relation":"worked_at"},
          {"from":"Me","to":"Stripe","relation":"flew_over"},
          {"from":"Stripe","to":"Stripe","relation":"related_to"}
        ]}
        ```
        """
        let extracted = KnowledgeExtractionParser.parse(raw)
        XCTAssertEqual(extracted.nodes.map(\.label), ["Me", "Stripe"], "unknown kind, blank label, and case duplicates are dropped")
        XCTAssertEqual(extracted.edges.count, 1)
        XCTAssertEqual(extracted.edges.first?.relation, .workedAt)
        XCTAssertEqual(extracted.edges.first?.evidence, "2019 to 2023")
    }

    func testParserKeepsOneNodePerLabelAcrossKinds() {
        let raw = """
        {"nodes":[{"kind":"company","label":"Stripe"},{"kind":"topic","label":"Stripe"},{"kind":"person","label":"Me"}],
         "edges":[{"from":"Me","to":"Stripe","relation":"worked_at"}]}
        """
        let extracted = KnowledgeExtractionParser.parse(raw)
        XCTAssertEqual(extracted.nodes.map(\.kind), [.company, .person], "first kind wins, edges cannot land on a shadow node")
        XCTAssertEqual(extracted.edges.count, 1)
    }

    func testNormalizationKeepsSymbolSkillsApartAndIgnoresLocale() {
        XCTAssertNotEqual(KnowledgeNode.normalize("C"), KnowledgeNode.normalize("C++"))
        XCTAssertNotEqual(KnowledgeNode.normalize("C++"), KnowledgeNode.normalize("C#"))
        XCTAssertEqual(KnowledgeNode.normalize("  Stripe, Inc. "), "stripe inc")
        XCTAssertEqual(KnowledgeNode.normalize("Istanbul"), "istanbul")
        XCTAssertEqual(KnowledgeQueryTokenizer.tokens(from: "Do you know Go or C#?"), ["know", "go", "c#"])
    }

    func testParserReturnsEmptyOnGarbage() {
        XCTAssertTrue(KnowledgeExtractionParser.parse("no json here").isEmpty)
        XCTAssertTrue(KnowledgeExtractionParser.parse("{\"nodes\": 5}").isEmpty)
    }

    func testPromptListsEveryKindAndRelation() {
        let prompt = KnowledgeExtractionPrompt.systemPrompt
        for kind in KnowledgeNodeKind.allCases { XCTAssertTrue(prompt.contains(kind.rawValue)) }
        for relation in KnowledgeRelation.allCases { XCTAssertTrue(prompt.contains(relation.rawValue)) }
        XCTAssertTrue(KnowledgeExtractionPrompt.userPrompt(text: "abc", workspaceTitle: "Stripe Staff").contains("Stripe Staff"))
    }

    func testMergerDedupesAgainstStoredNodesAndLinksEdges() throws {
        let path = NSTemporaryDirectory() + "kg-merge-\(UUID().uuidString).sqlite"
        var database: SessionDatabase! = SessionDatabase(databasePath: path)
        defer {
            database = nil
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        try database.upsertKnowledgeNode(KnowledgeNode(kind: .company, label: "Stripe"))

        let extracted = ExtractedKnowledge(
            nodes: [.init(kind: .person, label: "Me", summary: nil), .init(kind: .company, label: "stripe", summary: "Payments"), .init(kind: .skill, label: "Go", summary: nil)],
            edges: [.init(from: "Me", to: "Stripe", relation: .workedAt, evidence: nil), .init(from: "Me", to: "Go", relation: .usedSkill, evidence: "daily")]
        )
        let outcome = KnowledgeGraphMerger(database: database).merge(extracted, sourceKind: .session, sourceRef: "t:1", workspaceID: nil)

        XCTAssertEqual(outcome.nodesCreated, 2)
        XCTAssertEqual(outcome.nodesUpdated, 1)
        XCTAssertEqual(outcome.edgesUpserted, 2)
        XCTAssertEqual(database.countKnowledgeNodes(), 3)
        let stripe = try XCTUnwrap(database.findKnowledgeNode(kind: .company, label: "Stripe"))
        XCTAssertEqual(stripe.mentionCount, 2)
        XCTAssertEqual(stripe.summary, "Payments", "an empty summary is filled by extraction")
    }

    func testRetrieverWalksFromSeedsAndComposerRendersFacts() throws {
        let path = NSTemporaryDirectory() + "kg-retrieve-\(UUID().uuidString).sqlite"
        var database: SessionDatabase! = SessionDatabase(databasePath: path)
        defer {
            database = nil
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }
        let me = KnowledgeNode(kind: .person, label: "Me")
        let ledger = KnowledgeNode(kind: .project, label: "Ledger migration", summary: "Moved the ledger to Kafka")
        let kafka = KnowledgeNode(kind: .skill, label: "Kafka")
        let alice = KnowledgeNode(kind: .person, label: "Alice", summary: "Tech lead on the ledger team")
        for node in [me, ledger, kafka, alice] { try database.upsertKnowledgeNode(node) }
        try database.upsertKnowledgeEdge(KnowledgeEdge(fromNodeID: me.id, toNodeID: ledger.id, relation: .built))
        try database.upsertKnowledgeEdge(KnowledgeEdge(fromNodeID: ledger.id, toNodeID: kafka.id, relation: .usedSkill))
        try database.upsertKnowledgeEdge(KnowledgeEdge(fromNodeID: alice.id, toNodeID: ledger.id, relation: .workedWith, evidence: "2022"))

        let result = KnowledgeRetriever(database: database).retrieve(KnowledgeRetrievalQuery(text: "Tell me about the ledger project"))
        XCTAssertEqual(result.hits.first?.node.label, "Ledger migration")
        XCTAssertTrue(result.hits.contains { $0.node.label == "Kafka" }, "one hop neighbors are pulled in")
        XCTAssertTrue(result.hits.contains { $0.node.label == "Alice" })
        XCTAssertFalse(result.edges.isEmpty)

        let brief = try XCTUnwrap(KnowledgeContextComposer().compose(result))
        XCTAssertTrue(brief.text.hasPrefix("PERSONAL KNOWLEDGE GRAPH"))
        XCTAssertTrue(brief.text.contains("[Project] Ledger migration: Moved the ledger to Kafka"))
        XCTAssertTrue(brief.text.contains("Alice worked with Ledger migration (2022)"))
        XCTAssertGreaterThanOrEqual(brief.factCount, 3)
        XCTAssertNil(KnowledgeContextComposer().compose(.empty))
    }
}

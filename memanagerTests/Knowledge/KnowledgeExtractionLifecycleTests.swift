import XCTest
@testable import memanager

@MainActor
final class KnowledgeExtractionLifecycleTests: XCTestCase {
    private var database: SessionDatabase!
    private var databasePath: String!
    private let sourceText = "I built a Kafka event pipeline for the payments project."

    override func setUp() {
        super.setUp()
        databasePath = TestRuntime.temporaryDirectory
            .appendingPathComponent("knowledge-lifecycle-\(UUID().uuidString).sqlite").path
        database = SessionDatabase(databasePath: databasePath)
    }

    override func tearDown() {
        database?.flush()
        database = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databasePath + suffix)
        }
        super.tearDown()
    }

    func testClearRejectsInFlightExtractionFromAnotherMerger() async throws {
        let started = expectation(description: "Extraction suspended at provider")
        let client = DeferredKnowledgeClient(started: started)
        let extractor = KnowledgeExtractor(client: client, merger: KnowledgeGraphMerger(database: database))
        let task = Task {
            try await extractor.extractAndMerge(
                text: sourceText, sourceKind: .session, sourceRef: "turn", workspaceID: nil, workspaceTitle: nil
            )
        }
        await fulfillment(of: [started], timeout: 1)
        let store = KnowledgeGraphStore(database: database)
        store.clearGraph()
        await client.complete()

        do {
            _ = try await task.value
            XCTFail("An extraction started before Clear must be discarded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(database.countKnowledgeNodes(), 0)
        XCTAssertEqual(store.lastMessage, "Knowledge graph cleared.")

        let merger = KnowledgeGraphMerger(database: database)
        let outcome = try merger.merge(
            KnowledgeExtractionParser.parse(DeferredKnowledgeClient.response), generation: merger.generation,
            sourceKind: .manual, sourceRef: nil, workspaceID: nil
        )
        XCTAssertEqual(outcome.nodesCreated, 1, "New work after Clear remains available")
    }

    func testClearingManualExtractionKeepsClearedStatusWhenProviderSettles() async {
        let started = expectation(description: "Manual extraction suspended")
        let client = DeferredKnowledgeClient(started: started)
        let merger = KnowledgeGraphMerger(database: database)
        let store = KnowledgeGraphStore(database: database, merger: merger) {
            KnowledgeExtractor(client: client, merger: merger)
        }
        let task = Task { await store.extract(from: sourceText, workspace: nil) }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(store.isExtracting)
        store.clearGraph()
        XCTAssertFalse(store.isExtracting)
        await client.complete()
        let succeeded = await task.value
        XCTAssertFalse(succeeded)
        XCTAssertEqual(database.countKnowledgeNodes(), 0)
        XCTAssertEqual(store.lastMessage, "Knowledge graph cleared.")
    }

    func testCancelledExtractionDoesNotMergeEvenWhenClientIgnoresCancellation() async {
        let started = expectation(description: "Extraction suspended")
        let client = DeferredKnowledgeClient(started: started)
        let extractor = KnowledgeExtractor(client: client, merger: KnowledgeGraphMerger(database: database))
        let task = Task {
            try await extractor.extractAndMerge(
                text: sourceText, sourceKind: .manual, sourceRef: nil, workspaceID: nil, workspaceTitle: nil
            )
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await client.complete()
        do {
            _ = try await task.value
            XCTFail("Cancelled extraction must not commit")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(database.countKnowledgeNodes(), 0)
    }

    func testFailedClearPreservesCurrentExtractionGeneration() async throws {
        let started = expectation(description: "Extraction suspended")
        let client = DeferredKnowledgeClient(started: started)
        let extractor = KnowledgeExtractor(client: client, merger: KnowledgeGraphMerger(database: database))
        let task = Task {
            try await extractor.extractAndMerge(
                text: sourceText, sourceKind: .manual, sourceRef: nil, workspaceID: nil, workspaceTitle: nil
            )
        }
        await fulfillment(of: [started], timeout: 1)
        database.executeSQL("PRAGMA query_only = ON")
        XCTAssertThrowsError(try database.clearKnowledgeGraph())
        database.executeSQL("PRAGMA query_only = OFF")
        await client.complete()
        let outcome = try await task.value
        XCTAssertEqual(outcome.nodesCreated, 1)
        XCTAssertEqual(database.countKnowledgeNodes(), 1)
    }
}

private actor DeferredKnowledgeClient: SessionSummaryLLMCalling {
    static let response = #"{"nodes":[{"kind":"skill","label":"Kafka"}],"edges":[]}"#
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<String, Never>?

    init(started: XCTestExpectation) { self.started = started }

    func send(systemPrompt: String, userPrompt: String, settings: SettingsManager) async throws -> String {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func complete() {
        continuation?.resume(returning: Self.response)
        continuation = nil
    }
}

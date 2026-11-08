import XCTest
@testable import memanager

final class SessionLoggerStateTests: XCTestCase {
    func testConcurrentReadsAndWritesDoNotCorruptState() {
        let state = SessionLoggerState()
        let iterations = 2000

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            switch index % 4 {
            case 0:
                state.update(sessionId: "session-\(index)", provider: "provider", model: "model")
            case 1:
                state.sessionId = "session-\(index)"
            case 2:
                _ = state.sessionId
                _ = state.provider
            default:
                _ = state.model
            }
        }

        // Reaching here without a crash or TSAN report is the assertion; do
        // one final coherent round trip.
        state.update(sessionId: "final", provider: "p", model: "m")
        XCTAssertEqual(state.sessionId, "final")
        XCTAssertEqual(state.provider, "p")
        XCTAssertEqual(state.model, "m")
    }
}

final class SingleTurnFetchTests: XCTestCase {
    private var database: SessionDatabase!
    private var databasePath: String!

    override func setUp() {
        super.setUp()
        databasePath = NSTemporaryDirectory() + "single-turn-tests-\(UUID().uuidString).sqlite"
        database = SessionDatabase(databasePath: databasePath)
    }

    override func tearDown() {
        database = nil
        if let databasePath {
            try? FileManager.default.removeItem(atPath: databasePath)
            try? FileManager.default.removeItem(atPath: databasePath + "-wal")
            try? FileManager.default.removeItem(atPath: databasePath + "-shm")
        }
        super.tearDown()
    }

    func testFetchesExactTurnAndMissesCleanly() {
        let call = QuickAssistCallRecord(
            sessionId: "s1",
            threadId: "thread-1",
            turnId: "turn-1",
            provider: "openai",
            model: "gpt-test",
            startedAt: Date(),
            completedAt: Date(),
            durationMs: 100,
            isFollowUp: false,
            transcriptLength: 5,
            hasScreenshot: false,
            hasPreviousResponse: false,
            responseLength: 10,
            status: "success",
            question: "Q",
            responseText: "A",
            contextMode: .conversation,
            modelTier: .fast,
            questionSource: .manual
        )
        database.insertQuickAssistCall(call)
        database.flush()

        let fetched = database.getQuickAssistCall(threadId: "thread-1", turnId: "turn-1")
        XCTAssertEqual(fetched?.turnId, "turn-1")
        XCTAssertEqual(fetched?.question, "Q")

        XCTAssertNil(database.getQuickAssistCall(threadId: "thread-1", turnId: "missing"))
        XCTAssertNil(database.getQuickAssistCall(threadId: "missing", turnId: "turn-1"))
    }
}

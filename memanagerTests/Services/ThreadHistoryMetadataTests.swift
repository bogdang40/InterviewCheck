import XCTest
@testable import memanager

@MainActor
final class ThreadHistoryMetadataTests: SessionControllerDatabaseTestCase {
    func testOlderRefreshCannotReplaceCurrentThreadMetadata() async throws {
        let old = try seedThread(verification: .failed)
        let current = try seedThread(verification: .verified)
        let oldQueue = DispatchQueue(label: "test.thread-metadata.old")
        let currentQueue = DispatchQueue(label: "test.thread-metadata.current")
        oldQueue.suspend()
        controller.quickAssistThreadSummaries = [old]
        controller.refreshThreadCardMetadata(queue: oldQueue)
        XCTAssertEqual(controller.threadCardMetadataMap[old.id]?.pendingCount, 1)

        controller.quickAssistThreadSummaries = [current]
        controller.refreshThreadCardMetadata(queue: currentQueue)
        XCTAssertEqual(Set(controller.threadCardMetadataMap.keys), [current.id])
        await drain(currentQueue)
        XCTAssertEqual(controller.threadCardMetadataMap[current.id]?.dominantVerificationStatus, .verified)

        oldQueue.resume()
        await drain(oldQueue)
        XCTAssertEqual(Set(controller.threadCardMetadataMap.keys), [current.id])
        XCTAssertEqual(controller.threadCardMetadataMap[current.id]?.verifiedCount, 1)
    }

    func testResetClearsSkeletonAndRejectsPendingRefresh() async throws {
        let thread = try seedThread(verification: .verified)
        let queue = DispatchQueue(label: "test.thread-metadata.reset")
        queue.suspend()
        controller.quickAssistThreadSummaries = [thread]
        controller.refreshThreadCardMetadata(queue: queue)
        XCTAssertFalse(controller.threadCardMetadataMap.isEmpty)

        controller.resetQuickAssistSessionState()
        XCTAssertTrue(controller.threadCardMetadataMap.isEmpty)
        queue.resume()
        await drain(queue)
        XCTAssertTrue(controller.threadCardMetadataMap.isEmpty)
        XCTAssertEqual(logger.getQuickAssistThreads().map(\.id), [thread.id])
    }

    func testDeletionPrunesMetadataBeforePendingRefreshCanRepopulateIt() async throws {
        let deleted = try seedThread(verification: .failed)
        let retained = try seedThread(verification: .verified)
        let queue = DispatchQueue(label: "test.thread-metadata.delete")
        controller.quickAssistThreadSummaries = [deleted, retained]
        controller.refreshThreadCardMetadata(queue: queue)
        await drain(queue)
        XCTAssertEqual(controller.threadCardMetadataMap.count, 2)

        queue.suspend()
        controller.refreshThreadCardMetadata(queue: queue)
        XCTAssertNoThrow(try controller.deleteQuickAssistThreads(ids: [deleted.id]))
        XCTAssertEqual(Set(controller.threadCardMetadataMap.keys), [retained.id])
        queue.resume()
        await drain(queue)

        XCTAssertEqual(Set(controller.threadCardMetadataMap.keys), [retained.id])
        XCTAssertEqual(controller.threadCardMetadataMap[retained.id]?.verifiedCount, 1)
        XCTAssertEqual(logger.getQuickAssistThreads().map(\.id), [retained.id])
    }

    func testMetadataReadsVerificationTierAndCoachingFromInjectedDatabase() async throws {
        let thread = try seedThread(verification: .verified, tier: .deep)
        database.upsertCoachFinding(CoachFindingRecord(
            sessionId: thread.originSessionId, threadId: thread.id,
            issueType: .quickAssistHighLatency, severity: .warning,
            title: "Fixture coaching", message: "Explain the tradeoff",
            suggestedQuestion: "What is the tradeoff?", suggestedContext: "",
            evidence: [], dedupeKey: UUID().uuidString
        ))
        let queue = DispatchQueue(label: "test.thread-metadata.injected-store")
        controller.quickAssistThreadSummaries = [thread]
        controller.refreshThreadCardMetadata(queue: queue)
        await drain(queue)

        let metadata = try XCTUnwrap(controller.threadCardMetadataMap[thread.id])
        XCTAssertEqual(metadata.verifiedCount, 1)
        XCTAssertEqual(metadata.pendingCount, 0)
        XCTAssertEqual(metadata.dominantModelTier, .deep)
        XCTAssertEqual(metadata.coachFindingCount, 1)
    }

    private func seedThread(
        verification: QuickAssistVerificationStatus,
        tier: QuickAssistModelTier = .fast
    ) throws -> QuickAssistThreadSummary {
        let sessionID = UUID().uuidString
        let threadID = UUID().uuidString
        database.insertSession(SessionRecord(id: sessionID, startedAt: Date(), state: "idle"))
        logger.createQuickAssistThread(threadId: threadID, title: "Fixture thread", originSessionId: sessionID)
        database.insertQuickAssistCall(QuickAssistCallRecord(
            sessionId: sessionID, threadId: threadID, turnId: UUID().uuidString,
            provider: "Fixture provider", model: "Fixture model", status: "success",
            question: "Explain the decision", responseText: "A saved fixture response",
            modelTier: tier, verificationStatus: verification
        ))
        return try XCTUnwrap(logger.getQuickAssistThreads().first { $0.id == threadID })
    }

    private func drain(_ queue: DispatchQueue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

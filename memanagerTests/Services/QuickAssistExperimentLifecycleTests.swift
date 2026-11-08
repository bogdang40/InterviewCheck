import XCTest
@testable import memanager

@MainActor
final class QuickAssistExperimentLifecycleTests: SessionControllerDatabaseTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        controller = SessionController(
            workstreamTimelineRepository: WorkstreamTimelineRepository(logger: logger),
            relatedMemoryService: RelatedMemoryService(logger: logger),
            experimentRunner: FixedExperimentRunner(), logger: logger
        )
    }

    func testValidExperimentPersistsCandidatesAndPublishesWinner() async throws {
        let source = seedSource()
        let provider = ExperimentLifecycleProvider()

        await controller.runQuickAssistExperiment(providerResolver: { _ in provider })

        let contexts = await provider.contexts
        XCTAssertEqual(contexts.count, 2)
        XCTAssertTrue(contexts.allSatisfy { $0.question == "Explain the tradeoff" })
        let experiment = try XCTUnwrap(controller.activeQuickAssistExperiment)
        XCTAssertEqual(experiment.status, .completed)
        XCTAssertEqual(experiment.candidates.count, 3)
        XCTAssertEqual(experiment.sessionId, controller.session.id.uuidString)
        XCTAssertEqual(experiment.sourceThreadId, source.threadID)
        XCTAssertEqual(controller.quickAssistExperimentThreadID, experiment.candidates.first?.threadId)
        XCTAssertNotNil(controller.quickAssistExperimentComparison)
        let calls = database.getRecentQuickAssistCalls()
        XCTAssertEqual(calls.filter { $0.responseText == "The retained provider answer" }.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.sessionId == controller.session.id.uuidString })
    }

    func testResetDuringProviderWaitCannotCreateMoreBranchesOrPublish() async throws {
        _ = seedSource()
        let oldSessionID = controller.session.id.uuidString
        let (provider, task) = await startPausedExperiment()
        let before = try database.getQuickAssistThreadIDs()

        controller.resetSessionStateForTesting()
        let replacementSessionID = controller.session.id.uuidString
        await provider.finishFirst()
        await task.value

        XCTAssertNotEqual(oldSessionID, replacementSessionID)
        XCTAssertNil(logger.getSessionRecord(id: replacementSessionID))
        XCTAssertEqual(try database.getQuickAssistThreadIDs(), before)
        XCTAssertNil(controller.activeQuickAssistExperiment)
        XCTAssertNil(controller.quickAssistExperimentThreadID)
        XCTAssertNil(controller.quickAssistExperimentComparison)
        let contexts = await provider.contexts
        XCTAssertEqual(contexts.count, 1)
        let cancelled = database.getRecentQuickAssistCalls().filter { $0.status == "cancelled" }
        XCTAssertEqual(cancelled.count, 1)
        XCTAssertEqual(cancelled.first?.sessionId, oldSessionID)
    }

    func testSourceDeletionStopsRemainingCandidates() async throws {
        let source = seedSource()
        let (provider, task) = await startPausedExperiment()

        try database.deleteQuickAssistThreads(ids: [source.threadID])
        let afterDeletion = try database.getQuickAssistThreadIDs()
        await provider.finishFirst()
        await task.value

        XCTAssertEqual(try database.getQuickAssistThreadIDs(), afterDeletion)
        XCTAssertNil(logger.getQuickAssistCall(threadId: source.threadID, turnId: source.turnID))
        XCTAssertNil(controller.quickAssistExperimentThreadID)
        XCTAssertNil(controller.quickAssistExperimentComparison)
        let contexts = await provider.contexts
        XCTAssertEqual(contexts.count, 1)
    }

    func testSessionDeletionCannotRestoreExperimentOrBranches() async throws {
        _ = seedSource()
        let sessionID = controller.session.id.uuidString
        let (provider, task) = await startPausedExperiment()
        let experimentID = try XCTUnwrap(controller.activeQuickAssistExperiment?.id)

        try database.deleteSession(id: sessionID)
        await provider.finishFirst()
        await task.value

        XCTAssertTrue(try database.getQuickAssistThreadIDs().isEmpty)
        XCTAssertTrue(database.getRecentQuickAssistCalls().isEmpty)
        XCTAssertNil(logger.getSessionRecord(id: sessionID))
        XCTAssertNil(logger.loadQuickAssistExperiment(id: experimentID))
        XCTAssertNil(controller.quickAssistExperimentThreadID)
        XCTAssertNil(controller.quickAssistExperimentComparison)
        let contexts = await provider.contexts
        XCTAssertEqual(contexts.count, 1)
    }

    func testDeletedPendingCandidateIsNotRestoredByItsResponse() async throws {
        _ = seedSource()
        let (provider, task) = await startPausedExperiment()
        let pendingBranch = try XCTUnwrap(database.getRecentQuickAssistCalls().first {
            $0.candidateRole == .sameProviderDeep
        }?.threadId)

        try database.deleteQuickAssistThreads(ids: [pendingBranch])
        await provider.finishFirst()
        await task.value

        XCTAssertFalse(try database.getQuickAssistThreadIDs().contains(pendingBranch))
        XCTAssertTrue(logger.getQuickAssistCallsForThread(threadId: pendingBranch).isEmpty)
        XCTAssertFalse(controller.activeQuickAssistExperiment?.candidates.contains { $0.threadId == pendingBranch } ?? true)
        XCTAssertNotEqual(controller.quickAssistExperimentThreadID, pendingBranch)
    }

    func testClearDuringFailedProviderWaitPreservesCancellationAuditWithoutPublication() async throws {
        _ = seedSource()
        let (provider, task) = await startPausedExperiment()
        let before = try database.getQuickAssistThreadIDs()

        controller.clearQuickAssistExperiment()
        await provider.finishFirst(failing: true)
        await task.value

        XCTAssertEqual(try database.getQuickAssistThreadIDs(), before)
        XCTAssertNil(controller.activeQuickAssistExperiment)
        XCTAssertNil(controller.quickAssistExperimentThreadID)
        XCTAssertNil(controller.quickAssistExperimentComparison)
        let calls = database.getRecentQuickAssistCalls()
        XCTAssertEqual(calls.filter { $0.status == "cancelled" }.count, 1)
        XCTAssertFalse(calls.contains { $0.status == "error" })
        let contexts = await provider.contexts
        XCTAssertEqual(contexts.count, 1)
    }

    func testNewerExperimentKeepsItsWinnerWhenOlderResponseArrives() async throws {
        _ = seedSource()
        let (olderProvider, olderTask) = await startPausedExperiment()
        let olderID = try XCTUnwrap(controller.activeQuickAssistExperiment?.id)
        let newerProvider = ExperimentLifecycleProvider()

        await controller.runQuickAssistExperiment(providerResolver: { _ in newerProvider })
        let newerID = try XCTUnwrap(controller.activeQuickAssistExperiment?.id)
        let newerWinner = controller.quickAssistExperimentThreadID
        let before = try database.getQuickAssistThreadIDs()
        await olderProvider.finishFirst()
        await olderTask.value

        XCTAssertNotEqual(olderID, newerID)
        XCTAssertEqual(controller.activeQuickAssistExperiment?.id, newerID)
        XCTAssertEqual(controller.quickAssistExperimentThreadID, newerWinner)
        XCTAssertEqual(try database.getQuickAssistThreadIDs(), before)
        let olderContexts = await olderProvider.contexts
        XCTAssertEqual(olderContexts.count, 1)
        let cancelled = database.getRecentQuickAssistCalls().filter { $0.status == "cancelled" }
        XCTAssertEqual(cancelled.count, 1)
        XCTAssertEqual(cancelled.first?.experimentGroupId, olderID)
    }

    func testRequestCancellationStopsExperimentContinuation() async throws {
        _ = seedSource()
        let (provider, task) = await startPausedExperiment()
        let before = try database.getQuickAssistThreadIDs()

        controller.cancelActiveTasks()
        await provider.finishFirst()
        await task.value

        XCTAssertEqual(try database.getQuickAssistThreadIDs(), before)
        XCTAssertNil(controller.quickAssistExperimentThreadID)
        XCTAssertNil(controller.quickAssistExperimentComparison)
        XCTAssertEqual(database.getRecentQuickAssistCalls().filter { $0.status == "cancelled" }.count, 1)
        let contexts = await provider.contexts
        XCTAssertEqual(contexts.count, 1)
    }

    func testExplicitBranchPersistsDraftParentWithCopiedEvidence() throws {
        let source = seedSource(sessionID: UUID().uuidString)
        let draftID = controller.session.id.uuidString
        XCTAssertNil(logger.getSessionRecord(id: draftID))

        let branch = try XCTUnwrap(controller.branchQuickAssistThread(fromThreadID: source.threadID, turnID: source.turnID))

        XCTAssertNotNil(logger.getSessionRecord(id: draftID))
        let calls = logger.getQuickAssistCallsForThread(threadId: branch)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.sessionId, draftID)
        XCTAssertEqual(calls.first?.responseText, "The original answer")
    }

    private func seedSource(sessionID: String? = nil) -> (threadID: String, turnID: String) {
        let sessionID = sessionID ?? controller.session.id.uuidString
        let threadID = UUID().uuidString
        let turnID = UUID().uuidString
        database.insertSession(SessionRecord(id: sessionID, startedAt: Date(), state: "idle"))
        logger.createQuickAssistThread(threadId: threadID, title: "Source", originSessionId: sessionID)
        database.insertQuickAssistCall(QuickAssistCallRecord(
            sessionId: sessionID, threadId: threadID, turnId: turnID,
            provider: "OpenAI", model: "fixture", status: "success",
            question: "Explain the tradeoff", responseText: "The original answer",
            modelTier: .fast, verificationStatus: .verified
        ))
        controller.openQuickAssistThread(threadID: threadID, showQuickAssistView: false)
        return (threadID, turnID)
    }

    private func startPausedExperiment() async -> (ExperimentLifecycleProvider, Task<Void, Never>) {
        let started = expectation(description: "First provider request started")
        let provider = ExperimentLifecycleProvider(firstRequestStarted: started)
        let controller = controller!
        let task = Task { await controller.runQuickAssistExperiment(providerResolver: { _ in provider }) }
        await fulfillment(of: [started], timeout: 3)
        return (provider, task)
    }
}

private struct FixedExperimentRunner: QuickAssistExperimentRunning {
    func candidatePlans(for context: QuickAssistExperimentContext) -> [QuickAssistExperimentCandidatePlan] {
        [
            .init(label: "Current", role: .currentRoute, providerType: .openai, modelTier: .fast),
            .init(label: "Deep", role: .sameProviderDeep, providerType: .openai, modelTier: .deep),
            .init(label: "Alternate", role: .alternateProvider, providerType: .claude, modelTier: .fast)
        ]
    }
}

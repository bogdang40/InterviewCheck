import XCTest
@testable import memanager

@MainActor
final class SessionControllerQuickAssistHistoryDeletionTests: SessionControllerDatabaseTestCase {

    override func setUp() {
        super.setUp()
        controller.resetSessionStateForTesting()
    }

    func testDeletingCapturedHistoryClearsStateAndLeavesNoThreads() throws {
        let sessionId = controller.session.id.uuidString
        let firstThreadID = UUID().uuidString
        let secondThreadID = UUID().uuidString

        seedSuccessfulQuickAssistCall(
            sessionId: sessionId,
            threadId: firstThreadID,
            question: "First question",
            response: "First response",
            startedAt: Date(timeIntervalSince1970: 100)
        )
        seedSuccessfulQuickAssistCall(
            sessionId: sessionId,
            threadId: secondThreadID,
            question: "Second question",
            response: "Second response",
            startedAt: Date(timeIntervalSince1970: 200)
        )

        controller.openQuickAssistThread(threadID: secondThreadID, showQuickAssistView: true)
        controller.quickAssistQuestion = "Pending question"
        controller.quickAssistExtraContext = "Pending extra context"
        controller.quickAssistStreamingDraft = "streaming draft"
        controller.quickAssistContextStatusMessage = "status"
        controller.isQuickAssistViewVisible = true
        controller.isTranscriptViewVisible = false

        XCTAssertFalse(controller.quickAssistTurns.isEmpty)
        XCTAssertNotNil(controller.selectedQuickAssistTurnIndex)
        XCTAssertNotNil(controller.quickAssistResponse)

        let capturedIDs = try database.getQuickAssistThreadIDs()
        try controller.deleteQuickAssistThreads(ids: capturedIDs)
        controller.refreshQuickAssistThreads()
        controller.ensureActiveQuickAssistThreadLoaded(selectNewest: false)

        let threads = logger.getQuickAssistThreads(limit: 1000)
        XCTAssertTrue(threads.isEmpty, "Reading deleted history must not recreate a placeholder thread")
        XCTAssertNil(controller.activeQuickAssistThreadID)
        XCTAssertNil(controller.quickAssistSelectedHistoryThreadID)
        XCTAssertTrue(controller.quickAssistThreadSummaries.isEmpty)

        let calls = logger.getRecentQuickAssistCalls(limit: 1000)
        XCTAssertTrue(calls.isEmpty)

        XCTAssertTrue(controller.quickAssistTurns.isEmpty)
        XCTAssertNil(controller.selectedQuickAssistTurnIndex)
        XCTAssertNil(controller.quickAssistResponse)
        XCTAssertEqual(controller.quickAssistQuestion, "")
        XCTAssertEqual(controller.quickAssistExtraContext, "")
        XCTAssertNil(controller.quickAssistStreamingDraft)
        XCTAssertNil(controller.quickAssistContextStatusMessage)
        XCTAssertTrue(controller.isQuickAssistViewVisible)
        XCTAssertFalse(controller.isTranscriptViewVisible)
    }

    func testDeletingCapturedHistoryRejectsGenerationWithoutChangingHistory() throws {
        let sessionId = controller.session.id.uuidString
        let threadID = UUID().uuidString

        seedSuccessfulQuickAssistCall(
            sessionId: sessionId,
            threadId: threadID,
            question: "Question",
            response: "Response",
            startedAt: Date(timeIntervalSince1970: 300)
        )

        controller.openQuickAssistThread(threadID: threadID, showQuickAssistView: false)
        let capturedIDs = try database.getQuickAssistThreadIDs()
        let recordedTurnIDs = Set(logger.getRecentQuickAssistCalls(limit: 1000).map(\.turnId))
        controller.isQuickAssistLoading = true
        controller.quickAssistStreamingDraft = "draft"
        defer { controller.isQuickAssistLoading = false }

        XCTAssertThrowsError(try controller.deleteQuickAssistThreads(ids: capturedIDs))

        XCTAssertTrue(controller.isQuickAssistLoading)
        XCTAssertEqual(controller.quickAssistStreamingDraft, "draft")
        XCTAssertEqual(controller.activeQuickAssistThreadID, threadID)
        XCTAssertEqual(controller.quickAssistResponse, "Response")
        XCTAssertEqual(try database.getQuickAssistThreadIDs(), capturedIDs)
        XCTAssertEqual(Set(logger.getRecentQuickAssistCalls(limit: 1000).map(\.turnId)), recordedTurnIDs)
    }

    func testQuickAssistHistoryPersistsRawAndGuardedResponses() {
        let sessionId = controller.session.id.uuidString
        let threadID = UUID().uuidString
        logger.createQuickAssistThread(
            threadId: threadID,
            title: "Question",
            originSessionId: sessionId
        )

        let call = QuickAssistCallRecord(
            sessionId: sessionId,
            threadId: threadID,
            turnId: UUID().uuidString,
            provider: "OpenAI",
            model: "gpt-5.2",
            startedAt: Date(timeIntervalSince1970: 400),
            completedAt: Date(timeIntervalSince1970: 401),
            durationMs: 1000,
            isFollowUp: false,
            transcriptLength: 12,
            hasScreenshot: false,
            hasPreviousResponse: false,
            responseLength: 20,
            status: "success",
            transcriptText: "Me: hi",
            question: "Question",
            extraContext: "",
            requestPayload: "{}",
            responseText: "applied response",
            rawResponseText: "raw response",
            guardedResponseText: "guarded response",
            previousResponse: nil,
            contextMode: .conversation,
            modelTier: .fast,
            questionSource: .manual
        )
        database.insertQuickAssistCall(call)

        let persisted = logger.getQuickAssistCallsForThread(threadId: threadID, limit: 10)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.responseText, "applied response")
        XCTAssertEqual(persisted.first?.rawResponseText, "raw response")
        XCTAssertEqual(persisted.first?.guardedResponseText, "guarded response")
    }

    private func seedSuccessfulQuickAssistCall(
        sessionId: String,
        threadId: String,
        question: String,
        response: String,
        startedAt: Date
    ) {
        logger.createQuickAssistThread(
            threadId: threadId,
            title: question,
            originSessionId: sessionId
        )

        let call = QuickAssistCallRecord(
            sessionId: sessionId,
            threadId: threadId,
            turnId: UUID().uuidString,
            provider: "openai",
            model: "gpt-test",
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(0.2),
            durationMs: 200,
            isFollowUp: false,
            transcriptLength: 24,
            hasScreenshot: false,
            hasPreviousResponse: false,
            responseLength: response.count,
            status: "success",
            transcriptText: "transcript for \(question)",
            question: question,
            extraContext: "extra",
            requestPayload: "{}",
            responseText: response,
            previousResponse: nil,
            contextMode: .conversation,
            modelTier: .fast,
            questionSource: .manual
        )
        database.insertQuickAssistCall(call)
    }
}

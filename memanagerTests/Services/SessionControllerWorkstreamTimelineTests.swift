import XCTest
@testable import memanager

@MainActor
final class SessionControllerWorkstreamTimelineTests: SessionControllerDatabaseTestCase {

    override func setUp() {
        super.setUp()
        controller.resetSessionStateForTesting()
    }

    func testRefreshWorkstreamTimelineIncludesQuickAssistTurn() {
        let sessionId = controller.session.id.uuidString
        let threadId = controller.activeQuickAssistThreadID ?? sessionId
        let turnId = UUID().uuidString

        let call = QuickAssistCallRecord(
            sessionId: sessionId,
            threadId: threadId,
            turnId: turnId,
            provider: "openai",
            model: "gpt-test",
            startedAt: Date(),
            completedAt: Date().addingTimeInterval(0.3),
            durationMs: 300,
            isFollowUp: false,
            transcriptLength: 12,
            hasScreenshot: false,
            hasPreviousResponse: false,
            responseLength: 20,
            status: "success",
            question: "How do I fix this?",
            responseText: "Use a dictionary for lookup.",
            contextMode: .conversation,
            modelTier: .fast,
            questionSource: .manual
        )
        database.insertQuickAssistCall(call)

        controller.workstreamTimelineFilter = WorkstreamTimelineFilter(
            sessionId: sessionId,
            threadId: threadId,
            searchQuery: "",
            includeDebugEvents: true,
            limit: 120
        )
        controller.refreshWorkstreamTimeline()

        // The refresh loads on a background task and publishes on the main
        // actor; spin the runloop until the events land.
        let deadline = Date().addingTimeInterval(3)
        var hasQuickAssistEvent = false
        while Date() < deadline {
            hasQuickAssistEvent = controller.workstreamTimelineEvents.contains {
                $0.type == .quickAssist && $0.turnId == turnId
            }
            if hasQuickAssistEvent { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(hasQuickAssistEvent)
    }

    func testBranchQuickAssistThreadCreatesChildThreadWithLineage() {
        let sessionId = controller.session.id.uuidString
        let parentThreadId = UUID().uuidString
        let turnId = UUID().uuidString

        logger.createQuickAssistThread(
            threadId: parentThreadId,
            title: "Parent",
            originSessionId: sessionId
        )

        let call = QuickAssistCallRecord(
            sessionId: sessionId,
            threadId: parentThreadId,
            turnId: turnId,
            provider: "openai",
            model: "gpt-test",
            startedAt: Date(),
            completedAt: Date().addingTimeInterval(0.5),
            durationMs: 500,
            isFollowUp: false,
            transcriptLength: 20,
            hasScreenshot: false,
            hasPreviousResponse: false,
            responseLength: 30,
            status: "success",
            question: "Parent question",
            responseText: "Parent response",
            contextMode: .conversation,
            modelTier: .fast,
            questionSource: .manual
        )
        database.insertQuickAssistCall(call)
        controller.refreshQuickAssistThreads(selectThreadID: parentThreadId)

        controller.branchQuickAssistThread(fromThreadID: parentThreadId, turnID: turnId)

        let threads = logger.getQuickAssistThreads(limit: 500)
        let branchedThread = threads.first(where: {
            $0.parentThreadId == parentThreadId && $0.branchedFromTurnId == turnId
        })
        XCTAssertNotNil(branchedThread)
        XCTAssertEqual(controller.workstreamCompareLeftThreadID, parentThreadId)
        XCTAssertEqual(controller.workstreamCompareRightThreadID, branchedThread?.id)
        if let branchedThread {
            let copiedCalls = logger.getQuickAssistCallsForThread(threadId: branchedThread.id)
            XCTAssertEqual(copiedCalls.count, 1, "Copied answers must use the injected branch database")
            XCTAssertEqual(copiedCalls.first?.responseText, "Parent response")
            XCTAssertNotEqual(copiedCalls.first?.turnId, turnId)
        }
    }

    func testApplyCoachSuggestionPrefillsQuickAssistInputs() {
        let sessionId = controller.session.id.uuidString
        let threadId = controller.activeQuickAssistThreadID ?? sessionId
        let finding = CoachFindingRecord(
            sessionId: sessionId,
            threadId: threadId,
            issueType: .quickAssistHighLatency,
            severity: .warning,
            title: "Latency",
            message: "Latency is high",
            suggestedQuestion: "How can I reduce latency?",
            suggestedContext: "Evidence:\\nmedian=21000",
            evidence: [CoachEvidenceItem(label: "median", value: "21000")],
            dedupeKey: "test-latency-\(UUID().uuidString)"
        )
        logger.upsertCoachFinding(finding)

        controller.refreshCoachFindings()
        controller.applyCoachSuggestion(finding.id)

        XCTAssertEqual(controller.quickAssistQuestion, "How can I reduce latency?")
        XCTAssertEqual(controller.quickAssistExtraContext, "Evidence:\\nmedian=21000")
        XCTAssertTrue(controller.quickAssistExtraContextExpanded)
    }

    func testApplyQuickAssistTurnFeedbackPersistsRejectedStatus() {
        let sessionId = controller.session.id.uuidString
        let threadId = controller.activeQuickAssistThreadID ?? sessionId
        let turnId = UUID().uuidString

        let call = QuickAssistCallRecord(
            sessionId: sessionId,
            threadId: threadId,
            turnId: turnId,
            provider: "openai",
            model: "gpt-test",
            startedAt: Date(),
            completedAt: Date().addingTimeInterval(0.4),
            durationMs: 400,
            isFollowUp: false,
            transcriptLength: 30,
            hasScreenshot: false,
            hasPreviousResponse: false,
            responseLength: 50,
            status: "success",
            question: "Why is this failing?",
            responseText: "Use a dictionary.",
            contextMode: .implementationContext,
            modelTier: .fast,
            questionSource: .manual,
            verificationStatus: .needsReview,
            verificationConfidence: 0.52,
            unsupportedClaimCount: 2,
            verificationMissingQuestions: ["Can we validate this assumption?"],
            verificationSuggestedFollowUp: "Which assumption should I validate first?"
        )
        database.insertQuickAssistCall(call)

        controller.openQuickAssistThread(threadID: threadId, showQuickAssistView: true)
        controller.applyQuickAssistTurnFeedback(
            QuickAssistTurnFeedback(turnID: turnId, accepted: false, note: "not grounded enough")
        )

        let refreshed = logger.getQuickAssistCallsForThread(threadId: threadId)
        XCTAssertEqual(refreshed.last?.userFeedbackStatus, .rejected)
        XCTAssertEqual(controller.quickAssistSelectedTurnFeedbackStatus, .rejected)
        XCTAssertEqual(controller.quickAssistRecoveryPlan?.actions.first?.kind, .retryDeep)
    }

    func testToggleQuickAssistMemoryPinPersistsToDatabase() {
        let sessionId = controller.session.id.uuidString
        let threadId = controller.activeQuickAssistThreadID ?? sessionId
        let memoryNodeId = "memory-node-\(UUID().uuidString)"

        controller.openQuickAssistThread(threadID: threadId, showQuickAssistView: true)
        controller.toggleQuickAssistMemoryPin(memoryNodeId)
        XCTAssertTrue(logger.getQuickAssistThreadPins(threadId: threadId).contains(memoryNodeId))

        controller.toggleQuickAssistMemoryPin(memoryNodeId)
        XCTAssertFalse(logger.getQuickAssistThreadPins(threadId: threadId).contains(memoryNodeId))
    }

    func testLatestQuickAssistThreadForSessionPrefersMostRecentSuccessfulTurn() {
        let originSessionId = "resume-session-\(UUID().uuidString)"
        let olderThreadId = UUID().uuidString
        let newerThreadId = UUID().uuidString

        logger.createQuickAssistThread(
            threadId: olderThreadId,
            title: "Older",
            originSessionId: originSessionId
        )
        logger.createQuickAssistThread(
            threadId: newerThreadId,
            title: "Newer",
            originSessionId: originSessionId
        )

        let olderStartedAt = Date(timeIntervalSince1970: 10)
        let newerStartedAt = Date(timeIntervalSince1970: 20)
        database.insertQuickAssistCall(
            QuickAssistCallRecord(
                sessionId: originSessionId,
                threadId: olderThreadId,
                turnId: UUID().uuidString,
                provider: "claude",
                model: "haiku",
                startedAt: olderStartedAt,
                completedAt: olderStartedAt.addingTimeInterval(0.2),
                durationMs: 200,
                isFollowUp: false,
                transcriptLength: 10,
                hasScreenshot: false,
                hasPreviousResponse: false,
                responseLength: 12,
                status: "success",
                question: "Older question",
                responseText: "Older response",
                contextMode: .conversation,
                modelTier: .fast,
                questionSource: .manual
            )
        )
        database.insertQuickAssistCall(
            QuickAssistCallRecord(
                sessionId: originSessionId,
                threadId: newerThreadId,
                turnId: UUID().uuidString,
                provider: "claude",
                model: "haiku",
                startedAt: newerStartedAt,
                completedAt: newerStartedAt.addingTimeInterval(0.2),
                durationMs: 200,
                isFollowUp: false,
                transcriptLength: 10,
                hasScreenshot: false,
                hasPreviousResponse: false,
                responseLength: 12,
                status: "success",
                question: "Newer question",
                responseText: "Newer response",
                contextMode: .conversation,
                modelTier: .fast,
                questionSource: .manual
            )
        )

        let latest = logger.getLatestQuickAssistThread(originSessionId: originSessionId)

        XCTAssertEqual(latest?.id, newerThreadId)
    }

    func testLatestQuickAssistThreadForSessionFallsBackToUpdatedAtWhenNoTurnsExist() {
        let originSessionId = "empty-session-\(UUID().uuidString)"
        let firstThreadId = UUID().uuidString
        let secondThreadId = UUID().uuidString

        logger.createQuickAssistThread(
            threadId: firstThreadId,
            title: "First",
            originSessionId: originSessionId
        )
        Thread.sleep(forTimeInterval: 0.02)
        logger.createQuickAssistThread(
            threadId: secondThreadId,
            title: "Second",
            originSessionId: originSessionId
        )

        let latest = logger.getLatestQuickAssistThread(originSessionId: originSessionId)

        XCTAssertEqual(latest?.id, secondThreadId)
    }
}

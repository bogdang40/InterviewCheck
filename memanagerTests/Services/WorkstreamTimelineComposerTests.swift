import XCTest
@testable import memanager

final class WorkstreamTimelineComposerTests: XCTestCase {
    func testBuildThreadMetricsUsesSuccessfulTurnsAndAveragesDuration() {
        let composer = WorkstreamTimelineComposer()
        let summary = QuickAssistThreadSummary(
            id: "thread-1",
            title: "Thread One",
            createdAt: Date(),
            updatedAt: Date(),
            originSessionId: "session-1",
            turnCount: 0,
            lastTurnAt: nil,
            previewText: nil
        )
        let calls = [
            QuickAssistCallRecord(
                sessionId: "session-1",
                threadId: "thread-1",
                turnId: UUID().uuidString,
                provider: "openai",
                model: "gpt-test",
                startedAt: Date(timeIntervalSince1970: 10),
                completedAt: Date(timeIntervalSince1970: 11),
                durationMs: 1000,
                isFollowUp: false,
                transcriptLength: 10,
                hasScreenshot: false,
                hasPreviousResponse: false,
                responseLength: 10,
                status: "success",
                responseText: "first",
                contextMode: .conversation,
                modelTier: .fast,
                questionSource: .manual
            ),
            QuickAssistCallRecord(
                sessionId: "session-1",
                threadId: "thread-1",
                turnId: UUID().uuidString,
                provider: "openai",
                model: "gpt-test",
                startedAt: Date(timeIntervalSince1970: 12),
                completedAt: Date(timeIntervalSince1970: 15),
                durationMs: 3000,
                isFollowUp: true,
                transcriptLength: 10,
                hasScreenshot: false,
                hasPreviousResponse: true,
                responseLength: 10,
                status: "success",
                responseText: "second",
                contextMode: .systemDesignContext,
                modelTier: .deep,
                questionSource: .manual
            ),
            QuickAssistCallRecord(
                sessionId: "session-1",
                threadId: "thread-1",
                turnId: UUID().uuidString,
                provider: "openai",
                model: "gpt-test",
                startedAt: Date(timeIntervalSince1970: 20),
                durationMs: 5000,
                status: "error",
                errorMessage: "network",
                contextMode: .conversation,
                modelTier: .fast,
                questionSource: .manual
            )
        ]

        let metrics = composer.buildThreadMetrics(summary: summary, calls: calls)

        XCTAssertEqual(metrics.threadId, "thread-1")
        XCTAssertEqual(metrics.turnCount, 2)
        XCTAssertEqual(metrics.successCount, 2)
        XCTAssertEqual(metrics.errorCount, 1)
        XCTAssertEqual(metrics.averageDurationMs, 2000)
        XCTAssertEqual(metrics.contextModeMix[.conversation], 1)
        XCTAssertEqual(metrics.contextModeMix[.systemDesignContext], 1)
        XCTAssertEqual(metrics.latestResponseSnippet, "second")
    }

    func testCompareThreadsProducesHighlights() {
        let composer = WorkstreamTimelineComposer()
        let left = WorkstreamThreadMetrics(
            threadId: "left",
            title: "Left",
            turnCount: 6,
            successCount: 6,
            errorCount: 1,
            averageDurationMs: 1800,
            latestResponseSnippet: "left",
            contextModeMix: [.conversation: 6]
        )
        let right = WorkstreamThreadMetrics(
            threadId: "right",
            title: "Right",
            turnCount: 3,
            successCount: 3,
            errorCount: 3,
            averageDurationMs: 3200,
            latestResponseSnippet: "right",
            contextModeMix: [.conversation: 3]
        )

        let comparison = composer.compareThreads(left: left, right: right)

        XCTAssertGreaterThanOrEqual(comparison.highlights.count, 2)
        XCTAssertTrue(comparison.highlights.contains { $0.contains("Left") })
    }
}

import XCTest
@testable import memanager

final class QuickAssistStageResolverTests: XCTestCase {

    // MARK: Route summary

    func testRouteSummaryFormatterDropsUnknownKeysAndPipes() {
        let formatted = QuickAssistRouteSummaryFormatter.format("Mode: Debug | Intent: Debug | Tier: DEEP | Context: full | Policy: v3 (0.81)")
        XCTAssertEqual(formatted, "Mode Debug, Intent Debug, Tier Deep")
    }

    func testRouteSummaryFormatterOmitsUnparseableSummaries() {
        XCTAssertNil(QuickAssistRouteSummaryFormatter.format("something | odd"))
        XCTAssertNil(QuickAssistRouteSummaryFormatter.format(""))
        XCTAssertNil(QuickAssistRouteSummaryFormatter.format(nil))
    }

    // MARK: Beats

    func testStarFrameworkEmphasisesActionBeat() {
        let plans = QuickAssistAnswerBeatResolver.plans(
            titles: ["Situation", "Task", "Action", "Result", "Lesson"],
            frameworkName: "STAR-L"
        )
        XCTAssertEqual(plans.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(plans.map(\.isEmphasized), [false, false, true, false, false])
        XCTAssertEqual(plans[2].caption, QuickAssistAnswerBeatResolver.emphasisCaption)
        XCTAssertNil(plans[0].caption)
    }

    func testNonStarFrameworkEmphasisesNothingAndDropsBlankTitles() {
        let plans = QuickAssistAnswerBeatResolver.plans(titles: ["Action", "  ", nil], frameworkName: "CAR")
        XCTAssertFalse(plans.contains(where: \.isEmphasized))
        XCTAssertEqual(plans[0].title, "Action")
        XCTAssertNil(plans[1].title)
        XCTAssertNil(plans[2].title)
    }

    func testActionBeatDetectionIgnoresPunctuationAndCase() {
        XCTAssertTrue(QuickAssistAnswerBeatResolver.isActionBeat("ACTION:"))
        XCTAssertTrue(QuickAssistAnswerBeatResolver.isActionBeat("Actions I took"))
        XCTAssertFalse(QuickAssistAnswerBeatResolver.isActionBeat("Reaction"))
        XCTAssertFalse(QuickAssistAnswerBeatResolver.isActionBeat(nil))
    }

    // MARK: Say first typography

    func testSayFirstStaysLargestAtAnyBodySize() {
        XCTAssertEqual(QuickAssistSayFirstTypography.pointSize(bodyFontSize: 14), 36)
        XCTAssertEqual(QuickAssistSayFirstTypography.pointSize(bodyFontSize: 36), 42)
        XCTAssertEqual(QuickAssistSayFirstTypography.pointSize(bodyFontSize: 14, availableWidth: 340), 26)
        XCTAssertEqual(QuickAssistSayFirstTypography.pointSize(bodyFontSize: 30, availableWidth: 340), 36)
    }

    // MARK: Verification strip

    func testVerificationStripModelReadsRecord() {
        let record = QuickAssistVerificationRecord(status: .needsReview, confidence: 0.876, unsupportedClaimCount: 3, missingQuestions: [], suggestedFollowUp: nil)
        let model = QuickAssistVerificationStripModel(record: record, isStreaming: false)
        XCTAssertEqual(model.statusLabel, "Needs review")
        XCTAssertEqual(model.tone, .warning)
        XCTAssertEqual(model.confidenceLabel, "88%")
        XCTAssertEqual(model.unsupportedLabel, "3 unsupported claims")
        XCTAssertEqual(model.dotState, .error)
    }

    func testVerificationStripModelDefaultsToPendingAndStreams() {
        let pending = QuickAssistVerificationStripModel(record: nil, isStreaming: false)
        XCTAssertEqual(pending.statusLabel, "Pending")
        XCTAssertNil(pending.confidenceLabel)
        XCTAssertNil(pending.unsupportedLabel)
        XCTAssertEqual(pending.dotState, .idle)

        let streaming = QuickAssistVerificationStripModel(record: nil, isStreaming: true)
        XCTAssertEqual(streaming.statusLabel, "Streaming")
        XCTAssertEqual(streaming.tone, .info)
        XCTAssertEqual(streaming.dotState, .streaming)
    }

    // MARK: Answer clock

    func testAnswerClockStartsOnSettleAndSurvivesEitherNotificationOrder() {
        let now = Date()
        let settled = QuickAssistAnswerClockState.idle
            .loadingChanged(wasLoading: true, isLoading: false, hasResponse: true, seed: "turn-2", now: now)
        XCTAssertEqual(settled.startedAt, now)

        XCTAssertEqual(settled.turnChanged(to: "turn-2"), settled, "The settle selects the same turn, so the clock keeps running")

        let reversed = QuickAssistAnswerClockState.idle
            .turnChanged(to: "turn-2")
            .loadingChanged(wasLoading: true, isLoading: false, hasResponse: true, seed: "turn-2", now: now)
        XCTAssertEqual(reversed.startedAt, now)
    }

    func testAnswerClockResetsOnNavigationAndIgnoresLoadingWithoutResponse() {
        let now = Date()
        let running = QuickAssistAnswerClockState(startedAt: now, seed: "turn-2")
        XCTAssertNil(running.turnChanged(to: "turn-1").startedAt)
        XCTAssertNil(QuickAssistAnswerClockState.idle
            .loadingChanged(wasLoading: true, isLoading: false, hasResponse: false, seed: nil, now: now).startedAt)
        XCTAssertEqual(running.loadingChanged(wasLoading: false, isLoading: true, hasResponse: true, seed: "turn-2", now: now), running)
    }

    // MARK: Context hints

    func testContextHintsUseCountsInLabels() {
        let hints = QuickAssistContextHintBuilder.hints(hasTranscript: true, screenshotCount: 3, pinnedMemoryCount: 2, hasPriorTurn: true)
        XCTAssertEqual(hints.map(\.label), ["Transcript", "3 screenshots", "2 pinned", "Prior turn"])

        let single = QuickAssistContextHintBuilder.hints(hasTranscript: false, screenshotCount: 1, pinnedMemoryCount: 0, hasPriorTurn: false)
        XCTAssertEqual(single.map(\.label), ["1 screenshot"])
    }

    func testContextHintsFallBackToFreshPrompt() {
        let hints = QuickAssistContextHintBuilder.hints(hasTranscript: false, screenshotCount: 0, pinnedMemoryCount: 0, hasPriorTurn: false)
        XCTAssertEqual(hints.map(\.label), ["Fresh prompt"])
        XCTAssertEqual(hints.first?.kind, .fresh)
    }

    // MARK: Relative time

    func testRelativeTimeWording() {
        let now = Date()
        XCTAssertEqual(QuickAssistRelativeTimeFormatter.string(from: now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertEqual(QuickAssistRelativeTimeFormatter.string(from: now.addingTimeInterval(-300), now: now), "5m ago")
        XCTAssertEqual(QuickAssistRelativeTimeFormatter.string(from: now.addingTimeInterval(-7_200), now: now), "2h ago")
        XCTAssertEqual(QuickAssistRelativeTimeFormatter.string(from: now.addingTimeInterval(-3 * 86_400), now: now), "3d ago")
    }
}

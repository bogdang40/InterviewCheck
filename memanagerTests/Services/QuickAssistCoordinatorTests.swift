import XCTest
@testable import memanager

final class QuickAssistCoordinatorTests: XCTestCase {
    func testFirstRequestUsesFullTranscriptAndNoPreviousResponse() {
        let coordinator = QuickAssistCoordinator()
        var session = Session()
        session.transcript = "Me: hello\nSpeaker 1: there"
        session.transcriptEntries = [
            TranscriptEntry(speaker: .me, text: "hello", timestamp: Date(timeIntervalSince1970: 1)),
            TranscriptEntry(speaker: .speaker(0), text: "there", timestamp: Date(timeIntervalSince1970: 2))
        ]

        let request = coordinator.buildRequest(
            session: session,
            question: "",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: nil, failureReason: nil),
            stackedScreenshotBase64: [],
            isFollowUp: false
        )

        XCTAssertEqual(request?.transcript, session.transcript)
        XCTAssertNil(request?.context.previousResponse)
    }

    func testBuildRequestIncludesContextMode() {
        let coordinator = QuickAssistCoordinator()
        var session = Session()
        session.transcript = "Me: hello"

        let request = coordinator.buildRequest(
            session: session,
            question: "q",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: nil, failureReason: nil),
            stackedScreenshotBase64: [],
            contextMode: .implementationContext,
            isFollowUp: false
        )

        XCTAssertEqual(request?.context.contextMode, .implementationContext)
    }

    func testBuildRequestNormalizesFallbackTranscriptIntoSpeakerLines() {
        let coordinator = QuickAssistCoordinator()
        var session = Session()
        session.transcript = "hello first\nspeaker two"

        let request = coordinator.buildRequest(
            session: session,
            question: "",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: nil, failureReason: nil),
            stackedScreenshotBase64: [],
            isFollowUp: false
        )

        XCTAssertEqual(request?.transcript, "Speaker 1: hello first\nSpeaker 2: speaker two")
    }

    func testBuildRequestDoesNotDoublePrefixExistingSpeakerLabels() {
        let coordinator = QuickAssistCoordinator()
        var session = Session()
        session.transcript = "Me: first line\nSpeaker 2: second line"

        let request = coordinator.buildRequest(
            session: session,
            question: "",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: nil, failureReason: nil),
            stackedScreenshotBase64: [],
            isFollowUp: false
        )

        XCTAssertEqual(request?.transcript, "Me: first line\nSpeaker 2: second line")
    }

    func testFollowUpUsesDeltaTranscriptAndPreviousResponse() {
        let coordinator = QuickAssistCoordinator()
        var session = Session()
        session.transcript = "Me: first"
        session.transcriptEntries = [
            TranscriptEntry(speaker: .me, text: "first", timestamp: Date(timeIntervalSince1970: 1))
        ]

        let first = coordinator.buildRequest(
            session: session,
            question: "q1",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: nil, failureReason: nil),
            stackedScreenshotBase64: [],
            isFollowUp: false
        )
        XCTAssertNotNil(first)
        coordinator.markSuccessfulResponse("prev answer", requestTimestamp: Date(timeIntervalSince1970: 2))

        session.transcriptEntries.append(
            TranscriptEntry(speaker: .speaker(1), text: "second", timestamp: Date(timeIntervalSince1970: 3))
        )
        session.transcript = "Me: first\nSpeaker 2: second"

        let followUp = coordinator.buildRequest(
            session: session,
            question: "q2",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: nil, failureReason: nil),
            stackedScreenshotBase64: [],
            isFollowUp: true
        )

        XCTAssertEqual(followUp?.transcript, "Speaker 2: second")
        XCTAssertEqual(followUp?.context.previousResponse, "prev answer")
    }

    func testRequestIncludesFreshThenAllStackScreenshotsInOrder() {
        let coordinator = QuickAssistCoordinator()
        var session = Session()
        session.transcript = "Me: hello"

        let request = coordinator.buildRequest(
            session: session,
            question: "",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: "fresh", failureReason: nil),
            stackedScreenshotBase64: ["stack-newest", "stack-older"],
            isFollowUp: false
        )

        XCTAssertEqual(request?.context.screenshots, ["fresh", "stack-newest", "stack-older"])
        XCTAssertEqual(request?.contextEnvelope.freshCaptureStatus, .success)
        XCTAssertEqual(request?.contextEnvelope.imageCount, 3)
    }

    func testRequestManifestReportsFreshCaptureFailure() {
        let coordinator = QuickAssistCoordinator()
        var session = Session()
        session.transcript = "Me: hello"

        let request = coordinator.buildRequest(
            session: session,
            question: "",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(
                base64: nil,
                failureReason: .permissionDenied
            ),
            stackedScreenshotBase64: ["stack-only"],
            isFollowUp: false
        )

        XCTAssertEqual(request?.contextEnvelope.freshCaptureStatus, .failed)
        XCTAssertEqual(request?.contextEnvelope.freshCaptureFailureReason, "permissionDenied")
        XCTAssertTrue(request?.contextEnvelope.manifest.contains("fresh_capture: failed (permissionDenied)") == true)
        XCTAssertEqual(request?.context.screenshots, ["stack-only"])
    }

    func testLargeImageSetIncludesAllImagesWithoutTruncation() {
        let coordinator = QuickAssistCoordinator()
        var session = Session()
        session.transcript = "Me: hello"

        let stackedImages = (0..<60).map { "stack-\($0)" }
        let request = coordinator.buildRequest(
            session: session,
            question: "q",
            extraContext: "",
            realtimePrompt: "prompt",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: "fresh", failureReason: nil),
            stackedScreenshotBase64: stackedImages,
            isFollowUp: false
        )

        XCTAssertEqual(request?.context.screenshots.count, 61)
        XCTAssertEqual(request?.context.screenshots.first, "fresh")
        XCTAssertEqual(request?.context.screenshots.dropFirst().map { $0 }, stackedImages)
        XCTAssertEqual(request?.contextEnvelope.imageCount, 61)
    }

    func testOutputContractDefaultsToConversationConcise() {
        let coordinator = QuickAssistCoordinator()
        var session = Session()
        session.transcript = "Me: How would you design a URL shortener?"

        let request = coordinator.buildRequest(
            session: session,
            question: "",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: nil, failureReason: nil),
            stackedScreenshotBase64: [],
            isFollowUp: false
        )

        XCTAssertEqual(request?.context.outputContract.detailLevel, .concise)
        XCTAssertTrue(request?.context.outputContract.enforceFirstPerson == true)
    }

    func testOutputContractScreenshotOnlyDefaultsToDetailedSolveContract() {
        let coordinator = QuickAssistCoordinator()
        var session = Session()
        session.transcript = ""

        let request = coordinator.buildRequest(
            session: session,
            question: "",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: "fresh", failureReason: nil),
            stackedScreenshotBase64: [],
            isFollowUp: false
        )

        XCTAssertEqual(request?.context.outputContract.detailLevel, .detailed)
        XCTAssertEqual(request?.context.outputContract.responseShape, .structured)
        XCTAssertTrue(request?.context.outputContract.requiredElements.contains("problem_restatement") == true)
        XCTAssertTrue(request?.context.outputContract.requiredElements.contains("concrete_solution") == true)
    }

    func testOutputContractTextWithoutScreenshotStaysConversationConcise() {
        let coordinator = QuickAssistCoordinator()
        var session = Session()
        session.transcript = "Me: hello there"

        let request = coordinator.buildRequest(
            session: session,
            question: "",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: nil, failureReason: nil),
            stackedScreenshotBase64: [],
            isFollowUp: false
        )

        XCTAssertEqual(request?.context.outputContract.detailLevel, .concise)
        XCTAssertEqual(request?.context.outputContract.responseShape, .conversational)
    }

    func testOutputContractQuickSignalSetsConcise() {
        let coordinator = QuickAssistCoordinator()
        var session = Session()
        session.transcript = "Me: quickly explain the sliding window approach"

        let request = coordinator.buildRequest(
            session: session,
            question: "",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: nil, failureReason: nil),
            stackedScreenshotBase64: [],
            isFollowUp: false
        )

        XCTAssertEqual(request?.context.outputContract.detailLevel, .concise)
    }

    func testOutputContractDetailedSignalSetsDetailed() {
        let coordinator = QuickAssistCoordinator()
        var session = Session()
        session.transcript = "Me: walk me through the caching layer step by step"

        let request = coordinator.buildRequest(
            session: session,
            question: "",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: nil, failureReason: nil),
            stackedScreenshotBase64: [],
            isFollowUp: false
        )

        XCTAssertEqual(request?.context.outputContract.detailLevel, .detailed)
    }

    func testOutputContractImplementationContextDefaultsToDetailed() {
        let coordinator = QuickAssistCoordinator()
        var session = Session()
        session.transcript = "Me: explain the approach"

        let request = coordinator.buildRequest(
            session: session,
            question: "",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: nil, failureReason: nil),
            stackedScreenshotBase64: [],
            contextMode: .implementationContext,
            isFollowUp: false
        )

        XCTAssertEqual(request?.context.outputContract.detailLevel, .detailed)
    }

    func testBuildRequestPassesComplexityAndModelTier() {
        let coordinator = QuickAssistCoordinator()
        var session = Session()
        session.transcript = "Me: hello"

        let request = coordinator.buildRequest(
            session: session,
            question: "q",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: nil, failureReason: nil),
            stackedScreenshotBase64: [],
            isFollowUp: false,
            complexity: .deep,
            modelTier: .deep,
            tokenBudget: 4096
        )

        XCTAssertEqual(request?.context.complexity, .deep)
        XCTAssertEqual(request?.context.modelTier, .deep)
        XCTAssertEqual(request?.context.tokenBudget, 4096)
    }

    func testFollowUpBuildsConversationHistory() {
        let coordinator = QuickAssistCoordinator()
        var session = Session()
        session.transcript = "Me: first"
        session.transcriptEntries = [
            TranscriptEntry(speaker: .me, text: "first", timestamp: Date(timeIntervalSince1970: 1))
        ]

        _ = coordinator.buildRequest(
            session: session,
            question: "q1",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: nil, failureReason: nil),
            stackedScreenshotBase64: [],
            isFollowUp: false
        )
        coordinator.markSuccessfulResponse(
            "first answer",
            requestTimestamp: Date(timeIntervalSince1970: 2),
            transcript: "first",
            question: "q1"
        )

        session.transcriptEntries.append(
            TranscriptEntry(speaker: .speaker(1), text: "second", timestamp: Date(timeIntervalSince1970: 3))
        )

        let followUp = coordinator.buildRequest(
            session: session,
            question: "q2",
            extraContext: "",
            realtimePrompt: "",
            freshCaptureResult: ScreenshotService.FreshCaptureResult(base64: nil, failureReason: nil),
            stackedScreenshotBase64: [],
            isFollowUp: true
        )

        XCTAssertEqual(followUp?.context.conversationHistory.count, 2)
        XCTAssertEqual(coordinator.thread.turnCount, 1)
    }
}

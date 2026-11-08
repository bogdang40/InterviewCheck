import XCTest
@testable import memanager

final class MermaidDiagramViewSanitizerTests: XCTestCase {
    func testSanitizerConvertsEscapedLineBreakTokens() {
        let view = MermaidDiagramView(
            diagram: "flowchart LR\nA[Edge Gateway\\n(WebSocket)] --> B[Agent]"
        )

        XCTAssertTrue(view.sanitizedDiagram.contains("<br/>"))
        XCTAssertFalse(view.sanitizedDiagram.contains("\\n"))
    }

    func testRetryRepairFlattensProblematicWrappedLabelPrefix() {
        let view = MermaidDiagramView(
            diagram: "flowchart LR\nA[Edge Gateway\\n(WebSocket)] --> B[Agent]"
        )

        XCTAssertTrue(view.retryDiagram.contains("<br/> "))
    }

    func testRetryRepairQuotesRiskyFlowchartLabelsWithLongWrappedText() {
        let view = MermaidDiagramView(
            diagram: """
            flowchart LR
            EG[Edge Gateway\\n(WebSocket/HTTP2 Long Polling)] --> API[Agent Runtime/Executor]
            """
        )

        XCTAssertTrue(view.retryDiagram.contains("EG[\""))
        XCTAssertTrue(view.retryDiagram.contains("API[\""))
        XCTAssertTrue(view.retryDiagram.contains("<br/>"))
        XCTAssertFalse(view.retryDiagram.contains("EG[Edge Gateway"))
    }

    func testRetryRepairDoesNotDoubleQuoteAlreadyQuotedLabels() {
        let view = MermaidDiagramView(
            diagram: """
            flowchart LR
            A["Edge Gateway (EG)"] --> B["Agent Executor (AE)"]
            """
        )

        XCTAssertTrue(view.retryDiagram.contains(#"A["Edge Gateway (EG)"]"#))
        XCTAssertTrue(view.retryDiagram.contains(#"B["Agent Executor (AE)"]"#))
        XCTAssertFalse(view.retryDiagram.contains(#"A["\"Edge Gateway"#))
    }

    func testRenderLifecycleReducerMarksPendingOnEnqueue() {
        let initial = MermaidRenderLifecycleState()
        let next = reduceMermaidRenderLifecycleState(
            initial,
            event: .enqueue(contextID: "ctx-1")
        )

        XCTAssertEqual(next.pendingRenderContextID, "ctx-1")
        XCTAssertFalse(next.needsReload)
        XCTAssertNil(next.lastSuccessfulRenderContextID)
    }

    func testRenderLifecycleReducerCommitsSuccessAndRetainsLastGoodAfterTimeout() {
        var state = MermaidRenderLifecycleState()
        state = reduceMermaidRenderLifecycleState(state, event: .enqueue(contextID: "ctx-good"))
        state = reduceMermaidRenderLifecycleState(state, event: .complete(contextID: "ctx-good", outcome: .success))
        state = reduceMermaidRenderLifecycleState(state, event: .enqueue(contextID: "ctx-new"))
        state = reduceMermaidRenderLifecycleState(state, event: .complete(contextID: "ctx-new", outcome: .timeout))

        XCTAssertEqual(state.lastSuccessfulRenderContextID, "ctx-good")
        XCTAssertNil(state.pendingRenderContextID)
        XCTAssertTrue(state.needsReload)
        XCTAssertTrue(state.hasSuccessfulPaint)
    }

    func testRenderLifecycleReducerClearsPendingWhenSuperseded() {
        let pending = reduceMermaidRenderLifecycleState(
            MermaidRenderLifecycleState(),
            event: .enqueue(contextID: "ctx-2")
        )
        let superseded = reduceMermaidRenderLifecycleState(
            pending,
            event: .superseded(contextID: "ctx-2")
        )

        XCTAssertNil(superseded.pendingRenderContextID)
        XCTAssertTrue(superseded.needsReload)
    }

    func testClassifyRenderEvalFailureTreatsUnsupportedTypeAsNonFatal() {
        let disposition = classifyMermaidRenderEvalFailure(
            message: "JavaScript execution returned a result of an unsupported type",
            bootstrapReloadAttempt: 1
        )

        XCTAssertEqual(disposition, .waitForLifecycleAcks)
    }

    func testClassifyRenderEvalFailureReloadsBootstrapOnFirstBridgeException() {
        let disposition = classifyMermaidRenderEvalFailure(
            message: "A JavaScript exception occurred",
            bootstrapReloadAttempt: 0
        )

        XCTAssertEqual(disposition, .reloadBootstrapAndRetry)
    }

    func testClassifyRenderEvalFailureFailsAfterBootstrapRetryExhausted() {
        let disposition = classifyMermaidRenderEvalFailure(
            message: "A JavaScript exception occurred",
            bootstrapReloadAttempt: 1
        )

        XCTAssertEqual(disposition, .fail)
    }

    func testCorruptionEventStatusMappingCoversBlankTerminalSignals() {
        XCTAssertEqual(
            MermaidCorruptionEvent.fromStatusEvent("render_placeholder_retained"),
            .placeholderRetained
        )
        XCTAssertEqual(
            MermaidCorruptionEvent.fromStatusEvent("render_height_missing_svg"),
            .heightMissingSVG
        )
        XCTAssertEqual(
            MermaidCorruptionEvent.fromStatusEvent("render_runtime_missing"),
            .runtimeMissing
        )
        XCTAssertEqual(
            MermaidCorruptionEvent.fromStatusEvent("render_runtime_error"),
            .runtimeError
        )
        XCTAssertNil(MermaidCorruptionEvent.fromStatusEvent("render_primary_success"))
    }

    func testRecoveryDecisionForPlaceholderRetainedDoesNotForceBootstrapReload() {
        let decision = recoveryDecisionForMermaidCorruptionEvent(
            .placeholderRetained
        )

        XCTAssertEqual(decision, .immediateRecovery(forceBootstrapReload: false))
    }

    func testRecoveryDecisionForRuntimeMissingForcesBootstrapReload() {
        let decision = recoveryDecisionForMermaidCorruptionEvent(
            .runtimeMissing
        )

        XCTAssertEqual(decision, .immediateRecovery(forceBootstrapReload: true))
    }

    func testRecoveryDecisionForEvalFatalForcesBootstrapReload() {
        let decision = recoveryDecisionForMermaidCorruptionEvent(
            .evalFatal
        )

        XCTAssertEqual(decision, .immediateRecovery(forceBootstrapReload: true))
    }

    func testRecoveryDecisionForRuntimeErrorDoesNotForceBootstrapReload() {
        let decision = recoveryDecisionForMermaidCorruptionEvent(
            .runtimeError
        )

        XCTAssertEqual(decision, .immediateRecovery(forceBootstrapReload: false))
    }

    func testRecoveryDecisionForHeightMissingSVGDoesNotForceBootstrapReload() {
        let decision = recoveryDecisionForMermaidCorruptionEvent(
            .heightMissingSVG
        )

        XCTAssertEqual(decision, .immediateRecovery(forceBootstrapReload: false))
    }
}

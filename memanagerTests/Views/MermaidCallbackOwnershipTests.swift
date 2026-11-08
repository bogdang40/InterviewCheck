import WebKit
import XCTest
@testable import memanager

@MainActor
final class MermaidCallbackOwnershipTests: XCTestCase {
    func testStaleAndInvalidHeightsCannotChangeCurrentDiagram() async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = AutoSizingWebView(frame: .zero, configuration: configuration)
        let coordinator = MermaidDiagramView.Coordinator(minHeight: 300)
        coordinator.webView = webView
        coordinator.activeRenderContextID = "current"
        defer { coordinator.cleanup() }

        for body: [String: Any] in [
            ["contextID": "previous", "height": 900],
            ["contextID": "current", "height": Double.nan],
            ["contextID": "current", "height": Double.infinity],
            ["contextID": "current", "height": -1]
        ] {
            coordinator.receiveScriptMessage(name: "mermaidHeight", body: body)
        }
        await drainMainQueue()
        XCTAssertEqual(webView.contentHeight, 300)
        XCTAssertNil(coordinator.lastHeightAckContextID)

        coordinator.receiveScriptMessage(name: "mermaidHeight",
                                         body: ["contextID": "current", "height": 450])
        await drainMainQueue()
        XCTAssertEqual(webView.contentHeight, 450)
        XCTAssertEqual(coordinator.lastHeightAckContextID, "current")
    }

    func testContextChangeBetweenMessageAndPublicationRejectsOldHeight() async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = AutoSizingWebView(frame: .zero, configuration: configuration)
        let coordinator = MermaidDiagramView.Coordinator(minHeight: 300)
        coordinator.webView = webView
        coordinator.activeRenderContextID = "old"
        defer { coordinator.cleanup() }

        coordinator.receiveScriptMessage(name: "mermaidHeight",
                                         body: ["contextID": "old", "height": 700])
        coordinator.activeRenderContextID = "new"
        await drainMainQueue()
        XCTAssertEqual(webView.contentHeight, 300)
        XCTAssertNil(coordinator.lastHeightAckContextID)
    }

    func testCancelledRetryCannotEnqueueAnotherRender() async {
        let coordinator = MermaidDiagramView.Coordinator(minHeight: 300)
        defer { coordinator.cleanup() }
        coordinator.lastRequestedPayload = .init(
            contextID: "old", diagramID: "diagram", diagramText: "flowchart LR\nA-->B",
            retryDiagramText: "flowchart LR\nA-->B", theme: "default",
            backgroundColor: "#fff", textColor: "#000", zoomScale: 1, minHeight: 300
        )
        coordinator.scheduleAutomaticRetry(contextID: "old")
        let retry = coordinator.scheduledRetryTask
        retry?.cancel()
        await retry?.value
        await drainMainQueue()
        XCTAssertNil(coordinator.activeRenderContextID)
        XCTAssertNil(coordinator.renderState.pendingRenderContextID)
    }

    func testQueuedHeightCannotAcknowledgeReplacementAttemptForSameDiagram() async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = AutoSizingWebView(frame: .zero, configuration: configuration)
        let coordinator = MermaidDiagramView.Coordinator(minHeight: 300)
        coordinator.webView = webView
        coordinator.activeRenderContextID = "diagram"
        coordinator.activeRenderToken = UUID()
        defer { coordinator.cleanup() }

        coordinator.receiveScriptMessage(name: "mermaidHeight",
                                         body: ["contextID": "diagram", "height": 700])
        let replacementToken = UUID()
        coordinator.activeRenderToken = replacementToken
        await drainMainQueue()
        XCTAssertEqual(webView.contentHeight, 300)
        XCTAssertNil(coordinator.lastHeightAckContextID)
        XCTAssertEqual(coordinator.activeRenderToken, replacementToken)
    }

    func testQueuedSuccessCannotCompleteAReplacementRender() async {
        let coordinator = MermaidDiagramView.Coordinator(minHeight: 300)
        defer { coordinator.cleanup() }
        coordinator.activeRenderContextID = "old"
        coordinator.activeRenderToken = UUID()
        coordinator.lastHeightAckContextID = "old"
        coordinator.receiveScriptMessage(name: "mermaidStatus",
                                         body: ["name": "render_primary_success", "contextID": "old"])
        let replacementToken = UUID()
        coordinator.activeRenderContextID = "old"
        coordinator.activeRenderToken = replacementToken
        await drainMainQueue()
        XCTAssertEqual(coordinator.activeRenderContextID, "old")
        XCTAssertEqual(coordinator.activeRenderToken, replacementToken)
    }

    func testGeometryHeightUpdatesCompletedDiagramWithoutReopeningRender() async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = AutoSizingWebView(frame: .zero, configuration: configuration)
        let coordinator = MermaidDiagramView.Coordinator(minHeight: 300)
        coordinator.webView = webView
        defer { coordinator.cleanup() }
        completeRender(coordinator, contextID: "current")

        coordinator.receiveScriptMessage(name: "mermaidHeight",
                                         body: ["contextID": "current", "height": 450])
        await drainMainQueue()
        XCTAssertEqual(webView.contentHeight, 450)
        XCTAssertNil(coordinator.activeRenderContextID)
        XCTAssertNil(coordinator.lastHeightAckContextID)
        XCTAssertEqual(coordinator.renderState.lastSuccessfulRenderContextID, "current")
        XCTAssertFalse(coordinator.renderState.needsReload)

        coordinator.receiveScriptMessage(name: "mermaidHeight",
                                         body: ["contextID": "older", "height": 900])
        await drainMainQueue()
        XCTAssertEqual(webView.contentHeight, 450)
    }

    func testQueuedGeometryHeightCannotOverwriteNewlyCompletedAttemptForSameContext() async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = AutoSizingWebView(frame: .zero, configuration: configuration)
        let coordinator = MermaidDiagramView.Coordinator(minHeight: 300)
        coordinator.webView = webView
        defer { coordinator.cleanup() }
        completeRender(coordinator, contextID: "current")

        coordinator.receiveScriptMessage(name: "mermaidHeight",
                                         body: ["contextID": "current", "height": 700])
        completeRender(coordinator, contextID: "current")
        webView.contentHeight = 480
        await drainMainQueue()
        XCTAssertEqual(webView.contentHeight, 480)
        XCTAssertNil(coordinator.activeRenderContextID)
        XCTAssertNil(coordinator.lastHeightAckContextID)
    }

    private func completeRender(_ coordinator: MermaidDiagramView.Coordinator, contextID: String) {
        let payload = MermaidDiagramView.MermaidRenderPayload(
            contextID: contextID, diagramID: "diagram", diagramText: "flowchart LR\nA-->B",
            retryDiagramText: "flowchart LR\nA-->B", theme: "default",
            backgroundColor: "#fff", textColor: "#000", zoomScale: 1, minHeight: 300
        )
        coordinator.markRenderEnqueued(contextID: contextID, payload: payload, policy: .immediate)
        coordinator.activeRenderToken = UUID()
        coordinator.finishActiveRender(outcome: .success)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

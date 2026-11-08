import SwiftUI
import XCTest
@testable import memanager

/// Renders the system design renderers to PNG files for visual inspection
/// at the regular and compact widths. Opt in through MEMANAGER_RENDER_SMOKE=1
/// (TEST_RUNNER_MEMANAGER_RENDER_SMOKE=1 through xcodebuild); see
/// `OverlayRenderHarness`. Mermaid web views may paint blank in the harness.
@MainActor
final class DesignRenderTests: XCTestCase {
    private let widths: [CGFloat] = [800, 440]

    override func setUpWithError() throws {
        try super.setUpWithError()
        try OverlayRenderHarness.skipUnlessEnabled()
    }

    nonisolated override func tearDown() {
        MainActor.assumeIsolated { Self.resetController() }
        super.tearDown()
    }

    private static func resetController() {
        let controller = SessionController.shared
        controller.systemDesignSectionIndex = 0
        controller.systemDesignStepIndexBySection = [:]
        controller.systemDesignCompletenessReport = nil
        controller.systemDesignRecoveryInProgress = false
        controller.systemDesignStableFallbackActive = false
        controller.systemDesignContextStatusMessage = nil
        controller.streamingResponseText = ""
        controller.updateSessionResponse(nil)
        controller.teleprompterModeEnabled = false
    }

    /// Settled renderers live inside the shell's ScrollView, so the harness
    /// wraps them the same way.
    private func renderInStage<Content: View>(_ name: String, width: CGFloat, height: CGFloat = 1500, @ViewBuilder content: () -> Content) async throws {
        try await OverlayRenderHarness.render(name, size: CGSize(width: width, height: height), settle: 2) {
            ScrollView {
                content()
                    .padding(OverlayLayout.stageInset)
            }
        }
    }

    func testRenderSectionsMode() async throws {
        let content = DesignRenderFixtures.content
        let controller = SessionController.shared
        controller.systemDesignCompletenessReport = SystemDesignCompletenessReport.from(content: content, recoveryAttempted: false)
        controller.systemDesignSectionIndex = 2
        controller.systemDesignStepIndexBySection = ["architecture": 1]
        for width in widths {
            try await renderInStage("design-sections-\(Int(width))", width: width) {
                SystemDesignSectionView(content: content, initialMode: .sections)
            }
        }
    }

    func testRenderOverviewMode() async throws {
        let content = DesignRenderFixtures.content
        SessionController.shared.systemDesignSectionIndex = 1
        for width in widths {
            try await renderInStage("design-overview-\(Int(width))", width: width, height: 900) {
                SystemDesignSectionView(content: content, initialMode: .overview)
            }
        }
    }

    func testRenderScriptMode() async throws {
        let content = DesignRenderFixtures.content
        let controller = SessionController.shared
        controller.systemDesignSectionIndex = 0
        controller.teleprompterModeEnabled = true
        controller.systemDesignRecoveryInProgress = true
        for width in widths {
            try await renderInStage("design-script-\(Int(width))", width: width) {
                SystemDesignSectionView(content: content, initialMode: .script)
            }
        }
    }

    func testRenderEstimationTable() async throws {
        let metrics = DesignRenderFixtures.content.estimation?.metrics ?? []
        XCTAssertFalse(metrics.isEmpty, "The fixture must parse estimation metrics")
        for width in widths {
            try await renderInStage("design-estimation-\(Int(width))", width: width, height: 360) {
                EstimationMetricsView(metrics: metrics, fontSize: 13)
            }
        }
    }

    func testRenderCanvasAndPlaceholder() async throws {
        let array = CanvasArrayPayload(id: "nums", values: ["3", "1", "4", "1", "5", "9", "2", "6"], label: "nums")
        let scene = CanvasScene(
            arrays: ["nums": array],
            windows: ["nums": CanvasWindowPayload(targetID: "nums", op: .set, left: 2, right: 5)],
            pointers: [
                "left": CanvasPointerPayload(id: "left", targetID: "nums", op: .set, name: "left", index: 2),
                "right": CanvasPointerPayload(id: "right", targetID: "nums", op: .set, name: "right", index: 5)
            ],
            highlights: [CanvasHighlightPayload(targetID: "nums", kind: .indices, value: "3, 4", ttlMs: 0)]
        )
        try await OverlayRenderHarness.render("design-canvas-440", size: CGSize(width: 440, height: 440)) {
            VStack(spacing: DesignTokens.Spacing.md) {
                CanvasScenePaneView(scene: scene)
                    .frame(maxHeight: 180)
                MermaidPlaceholderCard(height: 160)
            }
            .padding(OverlayLayout.stageInset)
        }
    }

    func testRenderLiveGeneration() async throws {
        let controller = SessionController.shared
        controller.streamingResponseText = String(DesignRenderFixtures.designAnswer.prefix(900))
        controller.session.response = DesignRenderFixtures.response
        controller.systemDesignStableFallbackActive = true
        controller.systemDesignRecoveryInProgress = true
        controller.systemDesignContextStatusMessage = "Screen capture was unavailable, so this answer uses the transcript only."
        try await OverlayRenderHarness.render("design-live-800", size: CGSize(width: 800, height: 1500), settle: 2) {
            SystemDesignLiveGenerationView()
        }

        controller.streamingResponseText = ""
        controller.session.response = nil
        controller.systemDesignRecoveryInProgress = false
        controller.systemDesignStableFallbackActive = false
        try await OverlayRenderHarness.render("design-live-waiting-440", size: CGSize(width: 440, height: 600)) {
            SystemDesignLiveGenerationView()
        }
    }

    func testRenderPopulatedDesignGenerationActions() async throws {
        let controller = SessionController.shared
        let originalLoading = controller.isLoading
        let originalStreaming = controller.isStreaming
        defer {
            controller.isLoading = originalLoading
            controller.isStreaming = originalStreaming
        }
        controller.updateSessionResponse(
            DesignRenderFixtures.response, precomputedParsedSystemDesign: DesignRenderFixtures.content
        )
        let sectionCount = DesignSectionCatalog.availableSections(in: DesignRenderFixtures.content).count
        XCTAssertGreaterThan(sectionCount, 0)
        for sectionIndex in [0, max(0, sectionCount - 1)] {
            controller.systemDesignSectionIndex = sectionIndex
            for busy in [false, true] {
                controller.isLoading = busy
                controller.isStreaming = busy
                for width: CGFloat in [400, 800] {
                    let name = "design-actions-\(sectionIndex == 0 ? "first" : "last")-\(busy ? "busy" : "settled")-\(Int(width))"
                    try await OverlayRenderHarness.render(name, size: CGSize(width: width, height: 700), validate: { view in
                        if sectionIndex == sectionCount - 1 && width == 400 {
                            try OverlayRenderHarness.assertHorizontalSelectionAtTrailingEdge(in: view)
                        }
                    }) {
                        DesignSurface(width: width)
                    }
                }
            }
        }
    }
}

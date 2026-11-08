import SwiftUI
import XCTest
@testable import memanager

@MainActor
final class QuickAssistSourcesRenderTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try OverlayRenderHarness.skipUnlessEnabled()
    }

    func testRenderSavedSourcesAtCompactAndRegularWidths() async throws {
        for width: CGFloat in [400, 620] {
            var state = QuickAssistRenderFixtures.state(
                isLoading: false, selectedResponse: "A recorded answer", streamingDraft: nil,
                activeThreadID: "recorded-thread"
            )
            state.sourceRecord = QuickAssistCallRecord(
                sessionId: "recorded-session", threadId: "recorded-thread",
                turnId: try XCTUnwrap(state.selectedTurnID).uuidString, provider: "Claude", model: "recorded-model",
                hasScreenshot: true, hasPreviousResponse: true, status: "success",
                transcriptText: "Interviewer: How did you handle retries after a request timed out?",
                question: "Explain retry safety in the recorded project.",
                extraContext: "Recorded project: Payments service\nThe source notes describe a stored request key and a reusable result.",
                previousResponse: "Give each operation a request key and return the stored result when it is retried.",
                questionSource: .auto,
                evidencePackManifest: "transcript_len=73\nscreenshot_count=1"
            )
            try await OverlayRenderHarness.render("assist-sources-\(Int(width))", size: CGSize(width: width, height: 900)) {
                QuickAssistInspector(
                    state: state, actions: QuickAssistRenderFixtures.actions, initialTab: .sources,
                    displayMode: .constant(.response), isVoiceGuardEnabled: false,
                    onFocusQuestion: {}, onClose: {}
                )
            }
        }
    }

    func testRenderUnavailableSources() async throws {
        try await OverlayRenderHarness.render("assist-sources-unavailable", size: CGSize(width: 400, height: 600)) {
            QuickAssistSourcesView(presentation: .unavailable(.missingRecord), onOpenContext: {})
                .padding(DesignTokens.Spacing.lg)
                .background(OverlayPalette.readingSurface)
        }
    }
}

import SwiftUI
import XCTest
@testable import memanager

/// Renders the Quick Assist studio and the threads panel to PNG files for
/// visual inspection. Opt in through MEMANAGER_RENDER_SMOKE=1.
@MainActor
final class QuickAssistRenderTests: XCTestCase {
    private struct ThreadsPanelHost: View {
        let model: QuickAssistThreadsPanelModel
        @State var batchSelection = HistoryBatchSelection()
        @State private var search = ""
        @State private var filters: Set<SidebarThreadFilter> = []
        @FocusState private var focus: Bool

        var body: some View {
            QuickAssistThreadsPanel(
                model: model,
                actions: QuickAssistRenderFixtures.panelActions,
                searchText: $search,
                searchFocus: $focus,
                activeFilters: $filters,
                batchSelection: $batchSelection
            )
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try OverlayRenderHarness.skipUnlessEnabled()
    }

    private func render(_ name: String, width: CGFloat = 800, height: CGFloat = 900, state: QuickAssistStudioState) async throws {
        try await OverlayRenderHarness.render(name, size: CGSize(width: width, height: height)) {
            QuickAssistStudioView(state: state, actions: QuickAssistRenderFixtures.actions)
        }
    }

    private var contextHints: [QuickAssistComposerContextHint] {
        QuickAssistContextHintBuilder.hints(hasTranscript: true, screenshotCount: 3, pinnedMemoryCount: 2, hasPriorTurn: true)
    }

    private var starBadge: QuickAssistAnswerFamilyBadge {
        QuickAssistAnswerFamilyBadge(familyName: "Conflict", frameworkName: "STAR-L", isProbe: false)
    }

    func testRenderEmptyState() async throws {
        try await render("assist-empty", state: QuickAssistRenderFixtures.state(
            isLoading: false, selectedResponse: nil, streamingDraft: nil, provider: .claude,
            contextHints: QuickAssistContextHintBuilder.hints(hasTranscript: false, screenshotCount: 0, pinnedMemoryCount: 0, hasPriorTurn: false)
        ))
    }

    func testRenderStreamingDraft() async throws {
        try await render("assist-streaming", state: QuickAssistRenderFixtures.state(
            isLoading: true, selectedResponse: nil, streamingDraft: QuickAssistRenderFixtures.streamingDraft,
            turnCount: 2, provider: .claude, answerFamilyBadge: starBadge, activeTier: .deep,
            activeThreadID: "thread-1", contextHints: contextHints
        ))
    }

    func testRenderSettledStarAnswer() async throws {
        try await render("assist-star", state: QuickAssistRenderFixtures.state(
            isLoading: false, selectedResponse: QuickAssistRenderFixtures.starAnswer, streamingDraft: nil,
            turnCount: 5, selectedIndex: 2, verificationRecord: QuickAssistRenderFixtures.reviewRecord,
            answerFamilyBadge: starBadge, resolvedMode: .behavioural, modeDiverges: true,
            activeThreadID: "thread-1", contextHints: contextHints
        ))
    }

    func testRenderVerifiedTurnWithInsightBanner() async throws {
        try await render("assist-verified", state: QuickAssistRenderFixtures.state(
            isLoading: false, selectedResponse: QuickAssistRenderFixtures.starAnswer, streamingDraft: nil,
            turnCount: 3, verificationRecord: QuickAssistRenderFixtures.verifiedRecord, feedbackStatus: .accepted,
            routeSummary: "Mode: Auto | Resolved: Behavioural | Intent: Conversation | Tier: FAST | Context: transcript",
            answerFamilyBadge: starBadge, resolvedMode: .behavioural, modeDiverges: true,
            activeThreadID: "thread-1", contextHints: contextHints
        ))
    }

    func testRenderCompactAndWideWidths() async throws {
        let state = QuickAssistRenderFixtures.state(
            isLoading: false, selectedResponse: QuickAssistRenderFixtures.starAnswer, streamingDraft: nil,
            turnCount: 5, selectedIndex: 2, verificationRecord: QuickAssistRenderFixtures.reviewRecord,
            contextStatusMessage: "Screenshots were skipped because the provider rejected the image.",
            answerFamilyBadge: starBadge, resolvedMode: .behavioural, modeDiverges: true,
            activeThreadID: "thread-1", contextHints: contextHints
        )
        try await render("assist-compact-440", width: 440, height: 900, state: state)
        try await render("assist-wide-1000", width: 1000, height: 900, state: state)
    }

    func testRenderBatchThreadSelection() async throws {
        let summaries = QuickAssistRenderFixtures.threadSummaries()
        let model = QuickAssistThreadsPanelModel(
            groups: ThreadDateGroup.group(summaries), totalCount: summaries.count,
            visibleCount: summaries.count, isFiltered: false, selectedThreadID: nil,
            activeThreadID: nil, pendingDeletionThreadID: nil,
            metadataMap: QuickAssistRenderFixtures.threadMetadata,
            deleteAction: .threads(Array(summaries.prefix(2)))
        )
        try await OverlayRenderHarness.render("assist-batch-selection", size: CGSize(width: 280, height: 800)) {
            ThreadsPanelHost(model: model, batchSelection: HistoryBatchSelection(isSelecting: true, ids: Set(summaries.prefix(2).map(\.id))))
        }
    }

    func testRenderThreadsList() async throws {
        let summaries = QuickAssistRenderFixtures.threadSummaries()
        let model = QuickAssistThreadsPanelModel(
            groups: ThreadDateGroup.group(summaries),
            totalCount: summaries.count,
            visibleCount: summaries.count,
            isFiltered: false,
            selectedThreadID: "thread-1",
            activeThreadID: "thread-0",
            pendingDeletionThreadID: "thread-3",
            metadataMap: QuickAssistRenderFixtures.threadMetadata,
            deleteAction: nil
        )
        try await OverlayRenderHarness.render("assist-threads", size: CGSize(width: 250, height: 700)) {
            ThreadsPanelHost(model: model)
        }
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import memanager

/// Renders the History screen at the three breakpoints, its panes with
/// fixture data, the Practice screen, and the diagnostics panel to PNG.
/// Opt in with MEMANAGER_RENDER_SMOKE=1; see `OverlayRenderHarness`.
@MainActor
final class HistoryRenderTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try OverlayRenderHarness.skipUnlessEnabled()
    }

    func testRenderHistoryScreenWidths() async throws {
        for (name, width) in [("history-wide", CGFloat(1000)), ("history-regular", CGFloat(720)), ("history-compact", CGFloat(440))] {
            try await OverlayRenderHarness.render(name, size: CGSize(width: width, height: 900), settle: 1.0) {
                SessionHistoryView()
            }
        }
    }

    func testRenderHistoryListColumn() async throws {
        try await OverlayRenderHarness.render("history-list", size: CGSize(width: 260, height: 620)) {
            SessionHistoryLeftPane(
                sessions: HistoryRenderFixtures.sessions,
                resolver: .constant(SessionListResolver()),
                selectedSessionId: .constant(HistoryRenderFixtures.sessionID),
                metadataMap: HistoryRenderFixtures.metadata,
                isLoading: false,
                onRefresh: {},
                activeSessionID: "s2",
                deletionUnavailableReason: { $0 == "s2" ? "End this session before deleting it." : nil },
                onDelete: { _ in },
                batchSelection: .constant(HistoryBatchSelection())
            )
        }
    }

    func testRenderBatchSessionSelection() async throws {
        try await OverlayRenderHarness.render("history-batch-selection", size: CGSize(width: 280, height: 700)) {
            SessionHistoryLeftPane(
                sessions: HistoryRenderFixtures.sessions,
                resolver: .constant(SessionListResolver()),
                selectedSessionId: .constant(nil),
                metadataMap: HistoryRenderFixtures.metadata,
                isLoading: false,
                onRefresh: {},
                activeSessionID: "s2",
                deletionUnavailableReason: { $0 == "s2" ? "End this session first." : nil },
                batchSelection: .constant(HistoryBatchSelection(isSelecting: true, ids: [HistoryRenderFixtures.sessionID])),
                onDeleteSelected: { _ in }
            )
        }
    }

    func testRenderHistoryCountsAndEmptyFilter() async throws {
        try await OverlayRenderHarness.render("history-counts-filter", size: CGSize(width: 280, height: 700)) {
            SessionHistoryLeftPane(
                sessions: HistoryRenderFixtures.sessions,
                resolver: .constant(SessionListResolver()),
                selectedSessionId: .constant(nil), metadataMap: HistoryRenderFixtures.metadata,
                isLoading: false, onRefresh: {}, batchSelection: .constant(HistoryBatchSelection()),
                totalSessionCount: 177, emptySessionCount: 3342, emptySessionIDs: [],
                includeEmptySessions: .constant(false), onLoadMore: {}
            )
        }
        try await OverlayRenderHarness.render("history-only-empty", size: CGSize(width: 280, height: 700)) {
            SessionHistoryLeftPane(
                sessions: [], resolver: .constant(SessionListResolver()),
                selectedSessionId: .constant(nil), metadataMap: [:], isLoading: false, onRefresh: {},
                batchSelection: .constant(HistoryBatchSelection()), totalSessionCount: 0,
                emptySessionCount: 3342, includeEmptySessions: .constant(false)
            )
        }
    }

    func testRenderOverviewCards() async throws {
        let summary = SessionSummary(sessionID: UUID(), status: .completed, actionItems: [
            .init(title: "Write the recovery proposal", owner: "You", dueDate: "Friday"),
            .init(title: "Confirm retention requirements", owner: "Priya")
        ], backgroundSummary: "Decision: use one writer for the initial release. Open question: what retention period is required?", followUpEmailDraft: "Thanks for the discussion. I will share the recovery proposal by Friday.")
        try await OverlayRenderHarness.render("history-outcome-summary", size: CGSize(width: 640, height: 850)) {
            ScrollView {
                SessionSummaryContent(sessionID: summary.sessionID.uuidString, summary: summary, isRegenerating: false, onGenerate: {})
                    .padding(DesignTokens.Spacing.md)
            }
        }
        try await OverlayRenderHarness.render("history-overview", size: CGSize(width: 640, height: 1100)) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    SessionSummaryRibbon(metrics: HistoryRenderFixtures.metrics)
                    ProviderComparisonCard(providers: HistoryRenderFixtures.providers)
                    ProviderStatsCardGroup(stats: HistoryRenderFixtures.providerStats)
                    SkillProgressionSection(report: HistoryRenderFixtures.skillReport)
                    ResumeSessionBar(sessionID: HistoryRenderFixtures.sessionID)
                }
                .padding(DesignTokens.Spacing.md)
            }
        }
    }

    func testRenderTimelineLane() async throws {
        let items = TimelineClusterEngine().cluster(events: HistoryRenderFixtures.events)
        try await OverlayRenderHarness.render("history-timeline", size: CGSize(width: 640, height: 900)) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    TimelineFilterChipBar(enabledTypes: .constant(Set(WorkstreamEventType.allCases)))
                    TimelineLaneView(items: items, selectedEventID: "e4", onSelect: { _ in })
                    SessionEventDetailCard(event: HistoryRenderFixtures.events[1], selectedThreadId: .constant(nil))
                    TurnDeepDiveRows(record: HistoryRenderFixtures.call)
                }
                .padding(DesignTokens.Spacing.md)
            }
        }
    }

    func testRenderConversationComparison() async throws {
        let comparison = WorkstreamThreadComparison(
            left: WorkstreamThreadMetrics(threadId: "original", title: "Original", turnCount: 2, successCount: 2, errorCount: 0, averageDurationMs: 1200, latestResponseSnippet: "Retry the request if it times out.", contextModeMix: [:]),
            right: WorkstreamThreadMetrics(threadId: "revised", title: "Revised", turnCount: 3, successCount: 3, errorCount: 0, averageDurationMs: 1500, latestResponseSnippet: "Use a request key and return the original outcome.", contextModeMix: [:]),
            highlights: ["The revised response discusses duplicate execution."])
        try await OverlayRenderHarness.render("history-comparison", size: CGSize(width: 640, height: 480)) {
            CompareResultView(comparison: comparison).padding(DesignTokens.Spacing.md)
        }
    }

    func testRenderReplayAndDebrief() async throws {
        try await OverlayRenderHarness.render("history-transcript", size: CGSize(width: 640, height: 760)) {
            ScrollView {
                ReplayTranscriptSection(entries: [
                    TranscriptEntryRecord(sessionId: "sample", speaker: "Interviewer", text: "How do you make retries safe?", source: "system_audio"),
                    TranscriptEntryRecord(sessionId: "sample", speaker: "You", text: "Use a request key and return the stored outcome.")
                ]).padding(DesignTokens.Spacing.md)
            }
        }
        try await OverlayRenderHarness.render("history-replay", size: CGSize(width: 640, height: 1000)) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    ReplayEvidenceSection(turns: HistoryRenderFixtures.replay.turns)
                    ReplayPracticeCardsSection(cards: HistoryRenderFixtures.replay.practiceCards)
                    ReplayDebriefSection(debrief: HistoryRenderFixtures.debrief)
                    ReplayTimelineSection(events: Array(HistoryRenderFixtures.events.prefix(3)))
                }
                .padding(DesignTokens.Spacing.md)
            }
        }
        try await OverlayRenderHarness.render("history-debrief", size: CGSize(width: 640, height: 900)) {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    ForEach(DebriefSectionCatalog.sections(for: HistoryRenderFixtures.debrief)) { section in
                        DebriefSectionCard(section: section)
                    }
                    DebriefDrillsSection(drills: HistoryRenderFixtures.debrief.drills, onPractice: { _ in })
                }
                .padding(DesignTokens.Spacing.md)
            }
        }
    }

    func testRenderPracticeScreen() async throws {
        let store = PracticeStore.shared
        store.insert(card: HistoryRenderFixtures.card, schedule: HistoryRenderFixtures.schedule)
        defer { store.archive(cardID: HistoryRenderFixtures.card.id) }
        try await OverlayRenderHarness.render("practice-screen", size: CGSize(width: 720, height: 900)) {
            PracticeStudioView()
        }
        try await OverlayRenderHarness.render("practice-reference-and-grades", size: CGSize(width: 440, height: 650)) {
            VStack(spacing: DesignTokens.Spacing.md) {
                PracticeIdealReveal(text: HistoryRenderFixtures.card.idealReasoning, isRevealed: .constant(true), shortcutEnabled: false)
                PracticeGradeButtons(previews: PracticeIntervalPreview.previews(for: HistoryRenderFixtures.schedule, scheduler: SM2PracticeScheduler()), shortcutsEnabled: false, onChoose: { _ in })
            }.padding(DesignTokens.Spacing.md)
        }
        try await OverlayRenderHarness.render("practice-screen-compact", size: CGSize(width: 440, height: 900)) {
            PracticeStudioView()
        }
        try await OverlayRenderHarness.render("practice-card", size: CGSize(width: 560, height: 760)) {
            PracticeCardView(card: HistoryRenderFixtures.card, schedule: HistoryRenderFixtures.schedule, onGrade: { _ in })
                .padding(DesignTokens.Spacing.md)
        }
    }

    func testRenderDiagnosticsPanel() async throws {
        try await OverlayRenderHarness.render("diagnostics-panel", size: CGSize(width: 420, height: 720)) {
            DiagnosticsPanelView(onClose: {})
                .padding(DesignTokens.Spacing.md)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

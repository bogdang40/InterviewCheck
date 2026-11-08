import XCTest
@testable import memanager

/// Pure resolvers behind the History screen.
@MainActor
final class HistoryResolverTests: XCTestCase {
    func testDeletionSelectsNextVisibleSessionAndThenPreviousOrEmpty() {
        XCTAssertEqual(SessionListResolver.selectionAfterDeleting("b", selectedID: "b", visibleIDs: ["a", "b", "c"]), "c")
        XCTAssertEqual(SessionListResolver.selectionAfterDeleting("c", selectedID: "c", visibleIDs: ["a", "b", "c"]), "b")
        XCTAssertNil(SessionListResolver.selectionAfterDeleting("b", selectedID: "b", visibleIDs: ["b"]))
        XCTAssertEqual(SessionListResolver.selectionAfterDeleting("b", selectedID: "a", visibleIDs: ["a", "b"]), "a")
    }

    func testLayoutResolverSwitchesModesAtCompactBreakpoint() {
        XCTAssertEqual(SessionHistoryLayoutResolver(width: 440).mode, .stacked)
        XCTAssertEqual(SessionHistoryLayoutResolver(width: 560).mode, .stacked)
        XCTAssertEqual(SessionHistoryLayoutResolver(width: 899).mode, .stacked)
        XCTAssertEqual(SessionHistoryLayoutResolver(width: 900).mode, .twoColumn)
        XCTAssertEqual(SessionHistoryLayoutResolver(width: 1000).mode, .twoColumn)
    }

    func testLateResultsCannotReplaceANewerSessionOrRefresh() {
        var gate = SessionHistoryRequestGate()
        let first = gate.begin(sessionID: "first")
        let second = gate.begin(sessionID: "second")
        XCTAssertFalse(gate.accepts(first, sessionID: "first"))
        XCTAssertTrue(gate.accepts(second, sessionID: "second"))
        let refresh = gate.begin(sessionID: "second")
        XCTAssertFalse(gate.accepts(second, sessionID: "second"))
        XCTAssertTrue(gate.accepts(refresh, sessionID: "second"))
        gate.select(nil)
        XCTAssertFalse(gate.accepts(refresh, sessionID: "second"))
    }

    func testLayoutResolverPanesIncludeSessionsOnlyWhenStacked() {
        XCTAssertEqual(SessionHistoryLayoutResolver(width: 440).panes, HistoryPane.allCases)
        XCTAssertEqual(SessionHistoryLayoutResolver(width: 720).panes, HistoryPane.allCases)
        XCTAssertEqual(SessionHistoryLayoutResolver(width: 900).panes, [.overview, .timeline, .replay, .debrief])
    }

    func testLayoutResolverMapsSessionsPaneToOverviewInTwoColumns() {
        XCTAssertEqual(SessionHistoryLayoutResolver(width: 900).resolvedPane(.sessions), .overview)
        XCTAssertEqual(SessionHistoryLayoutResolver(width: 440).resolvedPane(.sessions), .sessions)
        XCTAssertEqual(SessionHistoryLayoutResolver(width: 720).resolvedPane(.replay), .replay)
    }

    func testListResolverFiltersSearchesAndSorts() {
        let sessions = HistoryRenderFixtures.sessions
        let metadata = HistoryRenderFixtures.metadata

        var resolver = SessionListResolver()
        XCTAssertEqual(resolver.apply(to: sessions, metadata: metadata).map(\.id), [HistoryRenderFixtures.sessionID, "s2", "s3"])

        resolver.sortOrder = .oldest
        XCTAssertEqual(resolver.apply(to: sessions, metadata: metadata).first?.id, "s3")

        resolver = SessionListResolver(filters: [.hasDebrief])
        XCTAssertEqual(resolver.apply(to: sessions, metadata: metadata).map(\.id), [HistoryRenderFixtures.sessionID])

        resolver = SessionListResolver(filters: [.highActivity, .hasCoachFindings])
        XCTAssertEqual(resolver.apply(to: sessions, metadata: metadata).map(\.id), [HistoryRenderFixtures.sessionID])

        resolver = SessionListResolver(query: "openai")
        XCTAssertEqual(resolver.apply(to: sessions, metadata: metadata).map(\.id), ["s2"])

        resolver = SessionListResolver(query: "tradeoffs")
        XCTAssertEqual(resolver.apply(to: sessions, metadata: metadata).map(\.id), [HistoryRenderFixtures.sessionID])

        resolver = SessionListResolver(sortOrder: .byThreadCount)
        XCTAssertEqual(resolver.apply(to: sessions, metadata: metadata).first?.id, HistoryRenderFixtures.sessionID)
    }

    func testListResolverToggleFlipsFilters() {
        var resolver = SessionListResolver()
        resolver.toggle(.hasDebrief)
        XCTAssertTrue(resolver.filters.contains(.hasDebrief))
        XCTAssertTrue(resolver.isFiltering)
        resolver.toggle(.hasDebrief)
        XCTAssertFalse(resolver.isFiltering)
    }

    func testTimelineFilterBuilderAppliesSelection() {
        let base = WorkstreamTimelineFilter(sessionId: "old", threadId: "t", searchQuery: "x", includeDebugEvents: false, limit: 10)
        let filter = SessionHistoryTimelineFilter.filter(base: base, sessionId: "new", threadId: nil, query: "latency", includeDebugEvents: true)
        XCTAssertEqual(filter.sessionId, "new")
        XCTAssertNil(filter.threadId)
        XCTAssertEqual(filter.searchQuery, "latency")
        XCTAssertTrue(filter.includeDebugEvents)
        XCTAssertEqual(filter.limit, SessionHistoryTimelineFilter.eventLimit)
    }

    func testAvailableThreadsKeepsGlobalAndSessionThreads() {
        let threads = [
            QuickAssistThreadSummary(id: "a", title: "A", createdAt: Date(), updatedAt: Date(), originSessionId: "s1", turnCount: 1, lastTurnAt: nil, previewText: nil),
            QuickAssistThreadSummary(id: "b", title: "B", createdAt: Date(), updatedAt: Date(), originSessionId: nil, turnCount: 1, lastTurnAt: nil, previewText: nil),
            QuickAssistThreadSummary(id: "c", title: "C", createdAt: Date(), updatedAt: Date(), originSessionId: "s2", turnCount: 1, lastTurnAt: nil, previewText: nil)
        ]
        XCTAssertEqual(SessionHistoryTimelineFilter.availableThreads(threads, sessionId: "s1").map(\.id), ["a", "b"])
        XCTAssertEqual(SessionHistoryTimelineFilter.availableThreads(threads, sessionId: nil).count, 3)
        XCTAssertTrue(SessionHistoryTimelineFilter.threadSelectionSurvives(threadId: "b", in: threads))
        XCTAssertFalse(SessionHistoryTimelineFilter.threadSelectionSurvives(threadId: "zzz", in: threads))
        XCTAssertTrue(SessionHistoryTimelineFilter.threadSelectionSurvives(threadId: nil, in: []))
    }

    func testDebriefCatalogProducesFourTonedSections() {
        let sections = DebriefSectionCatalog.sections(for: HistoryRenderFixtures.debrief)
        XCTAssertEqual(sections.map(\.tone), [.info, .success, .warning, .neutral])
        XCTAssertEqual(sections.map(\.title), ["What happened", "Strong moments", "Missed opportunities", "Next focus"])
        XCTAssertEqual(sections[2].lines, ["Hedged on complexity instead of stating it."])
    }

    func testMetricsFormatterBuildsRibbonTiles() {
        let tiles = SessionMetricsFormatter.tiles(for: HistoryRenderFixtures.metrics)
        XCTAssertEqual(tiles.map(\.value), ["10", "60%", "842ms", "2", "3"])
        XCTAssertEqual(tiles.map(\.tone), [.neutral, .success, .neutral, .warning, .critical])
        let quiet = DebriefMetrics(totalQuickAssistCalls: 0, successfulCalls: 0, failedCalls: 0, verifiedCalls: 0, averageLatencyMs: nil, coachFindingCount: 0, responseCardCount: 0, unsupportedClaimTotal: 0)
        XCTAssertEqual(SessionMetricsFormatter.verifiedPercent(quiet), "0%")
        XCTAssertEqual(SessionMetricsFormatter.latency(quiet), "n/a")
    }

    func testProviderStatsAggregateGroupsByProvider() {
        let aggregates = ProviderStatsAggregate.grouped(HistoryRenderFixtures.providerStats + HistoryRenderFixtures.providerStats)
        XCTAssertEqual(aggregates.map(\.provider), ["Claude", "OpenAI"])
        XCTAssertEqual(aggregates[0].calls, 84)
        XCTAssertEqual(aggregates[0].averageDurationMs, 840, accuracy: 0.001)
        XCTAssertEqual(aggregates[1].successRate, 91.666, accuracy: 0.01)
    }

    func testProviderComparisonScaleIsRelativeToSlowest() {
        let scale = ProviderComparisonScale(providers: HistoryRenderFixtures.providers)
        XCTAssertEqual(scale.successFraction(HistoryRenderFixtures.providers[0]), 1, accuracy: 0.001)
        XCTAssertEqual(scale.latencyFraction(HistoryRenderFixtures.providers[1]), 1, accuracy: 0.001)
        XCTAssertEqual(scale.latencyFraction(HistoryRenderFixtures.providers[0]), 780.0 / 1420.0, accuracy: 0.001)
    }

    func testReplayPresentationSummaryAndEvidence() {
        XCTAssertEqual(ReplayPresentation.summaryLine(for: .empty, hasSession: false), "No session selected")
        XCTAssertEqual(ReplayPresentation.summaryLine(for: HistoryRenderFixtures.replay, hasSession: true), "6 events, 1 turn, 0 snapshots, 1 card")
        XCTAssertEqual(ReplayPresentation.evidenceLabel(for: .drill(drillID: "d1")), "drill d1")
        XCTAssertEqual(ReplayPresentation.evidenceLabel(for: .manual), "manual")
    }

    func testSessionCardFormatterLabels() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(SessionCardFormatter.durationLabel(startedAt: start, endedAt: start.addingTimeInterval(725)), "12m 05s")
        XCTAssertEqual(SessionCardFormatter.durationLabel(startedAt: start, endedAt: nil), "Unfinished")
        XCTAssertEqual(SessionCardFormatter.durationLabel(startedAt: start, endedAt: nil, isActive: true), "Active")
        XCTAssertEqual(SessionCardFormatter.durationLabel(startedAt: start, endedAt: start.addingTimeInterval(725), isActive: true), "Active")
        XCTAssertEqual(SessionCardFormatter.countLabel(1, singular: "thread", plural: "threads"), "1 thread")
        XCTAssertEqual(SessionCardFormatter.countLabel(4, singular: "thread", plural: "threads"), "4 threads")
    }

    func testSparklineGeometryNormalizesAndSpacesPoints() {
        XCTAssertEqual(SparklineGeometry.normalized([2, 4, 6]), [0, 0.5, 1])
        XCTAssertEqual(SparklineGeometry.normalized([3, 3]), [0.5, 0.5])
        let points = SparklineGeometry.points(for: [0, 1], in: CGSize(width: 100, height: 26), inset: 3)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].x, 0)
        XCTAssertEqual(points[1].x, 100)
        XCTAssertEqual(points[0].y, 23)
        XCTAssertEqual(points[1].y, 3)
    }

    func testTimelinePresentationMapsSeverityToTone() {
        XCTAssertEqual(WorkstreamEventSeverity.info.tone, .info)
        XCTAssertEqual(WorkstreamEventSeverity.warning.tone, .warning)
        XCTAssertEqual(WorkstreamEventSeverity.critical.tone, .critical)
        XCTAssertEqual(WorkstreamEventType.quickAssist.shortTitle, "Assist")
        XCTAssertFalse(TimelineTimeFormatter.range(from: Date(), to: Date()).contains("-"))
    }
}

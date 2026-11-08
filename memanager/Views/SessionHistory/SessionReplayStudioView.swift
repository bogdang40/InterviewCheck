import SwiftUI

private enum ReplayEvidenceTab: String, CaseIterable, Identifiable {
    case transcript, screenshots, turns, practice
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Persisted evidence stays tied to its session. There is no audio replay.
struct SessionReplayStudioView: View {
    let sessionID: String?
    @State private var replay: SessionReplay = .empty
    @State private var isLoading = false
    @State private var requestID = UUID()
    @State private var selectedTab: ReplayEvidenceTab = .transcript
    private let loader: SessionReplayLoading = SessionReplayService()

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeader("Session evidence", systemImage: "doc.text.viewfinder", subtitle: ReplayPresentation.summaryLine(for: replay, hasSession: sessionID != nil)) {
                Button("Refresh", systemImage: "arrow.clockwise", action: load)
                    .buttonStyle(.overlay(.secondary, size: .small))
                    .disabled(sessionID == nil || isLoading)
            }
            .padding(DesignTokens.Spacing.md)
            ScrollView(.horizontal, showsIndicators: false) {
                SegmentStrip(items: ReplayEvidenceTab.allCases.map { SegmentItem(id: $0, title: $0.title) }, selection: $selectedTab)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.bottom, DesignTokens.Spacing.sm)
            Hairline()
            content
        }
        .onAppear(perform: load)
        .onChange(of: sessionID) { _, _ in load() }
    }

    @ViewBuilder
    private var content: some View {
        if sessionID == nil {
            HistorySelectionEmptyState()
        } else if isLoading {
            StageLoadingView(title: "Loading evidence", subtitle: "Reading saved transcript, screenshots and turns.")
        } else if replay.session == nil {
            OverlayEmptyState(systemImage: "doc.questionmark", title: "Session unavailable", message: "The saved session could not be loaded.", primary: EmptyStateAction(title: "Retry", action: load))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    switch selectedTab {
                    case .transcript:
                        ReplayTranscriptSection(entries: replay.transcriptEntries)
                    case .screenshots:
                        if replay.snapshots.isEmpty {
                            OverlayCompactEmptyState(systemImage: "photo", title: "No captured screens", message: "No screenshot evidence was saved for this session.")
                        } else {
                            ReplaySnapshotStrip(snapshots: replay.snapshots)
                        }
                    case .turns:
                        ReplayEvidenceSection(turns: replay.turns)
                    case .practice:
                        if replay.practiceCards.isEmpty {
                            OverlayCompactEmptyState(systemImage: "square.stack", title: "No practice cards", message: "Practice cards appear when a session produces a supported drill.")
                        } else {
                            ReplayPracticeCardsSection(cards: replay.practiceCards)
                        }
                        ReplayDebriefSection(debrief: replay.debrief)
                    }
                    ReplayTimelineSection(events: replay.events)
                }
                .padding(DesignTokens.Spacing.md)
            }
        }
    }

    private func load() {
        let token = UUID()
        requestID = token
        guard let sessionID else {
            replay = .empty
            isLoading = false
            return
        }
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = loader.load(sessionID: sessionID)
            DispatchQueue.main.async {
                guard token == requestID else { return }
                replay = loaded
                isLoading = false
            }
        }
    }
}

struct ReplayTranscriptSection: View {
    let entries: [TranscriptEntryRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            SurfaceHeader("Historical transcript", systemImage: "text.alignleft", count: entries.count, prominence: .heading)
            if entries.isEmpty {
                OverlayCompactEmptyState(systemImage: "text.bubble", title: "No saved transcript", message: "This session has no persisted transcript entries. Other evidence may still be available.")
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Text(entry.timestamp, style: .time).font(OverlayType.mono)
                            Text(entry.speaker).font(OverlayType.captionStrong)
                            Spacer(minLength: 0)
                            Text(entry.source == "system_audio" ? "System audio" : "Microphone")
                                .font(OverlayType.caption)
                        }
                        .foregroundStyle(OverlayPalette.textSecondary)
                        Text(entry.text)
                            .font(OverlayType.body)
                            .foregroundStyle(OverlayPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignTokens.Spacing.md)
                    .overlayCard(.base)
                }
            }
        }
    }
}

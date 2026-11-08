import SwiftUI

/// The session list column: header with count, search, sort and filter
/// chips, and the sessions grouped by day.
struct SessionHistoryLeftPane: View {
    let sessions: [SessionRecord]
    @Binding var resolver: SessionListResolver
    @Binding var selectedSessionId: String?
    let metadataMap: [String: SessionCardMetadata]
    let isLoading: Bool
    let onRefresh: () -> Void
    var onSelect: ((String) -> Void)? = nil
    var activeSessionID: String? = nil
    var deletionUnavailableReason: (String) -> String? = { _ in nil }
    var onDelete: ((SessionRecord) -> Void)? = nil

    @Binding var batchSelection: HistoryBatchSelection
    var onDeleteSelected: ((Set<String>) -> Void)? = nil
    var totalSessionCount: Int? = nil
    var emptySessionCount = 0
    var emptySessionIDs: Set<String>? = nil
    var includeEmptySessions: Binding<Bool>? = nil
    var loadError: String? = nil
    var onLoadMore: (() -> Void)? = nil

    private var visibleSessions: [SessionRecord] {
        resolver.apply(to: sessions, metadata: metadataMap)
    }

    private var eligibleIDs: Set<String> {
        Set(visibleSessions.filter { deletionUnavailableReason($0.id) == nil }.map(\.id))
    }

    private var groups: [SessionDateGroup] {
        resolver.groups(from: sessions, metadata: metadataMap)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                SurfaceHeader("Sessions", systemImage: "clock.arrow.circlepath", count: totalSessionCount ?? sessions.count) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.overlayIcon(size: 24))
                    .help("Refresh sessions")
                }
                OverlaySearchField(placeholder: "Search provider, model or summary", text: $resolver.query)
                SessionFilterBar(resolver: $resolver)
                if let includeEmptySessions {
                    Toggle("Include empty sessions (\(emptySessionCount))", isOn: includeEmptySessions)
                        .toggleStyle(.checkbox)
                        .font(OverlayType.caption)
                }
                if let onDeleteSelected {
                    HistoryBatchSelectionBar(
                        selection: $batchSelection,
                        eligibleIDs: eligibleIDs,
                        emptyIDs: emptySessionIDs ?? Set(visibleSessions.filter { HistoryBatchSelection.emptySession($0, metadata: metadataMap[$0.id]) }.map(\.id)),
                        onDelete: onDeleteSelected
                    )
                }
            }
            .padding(DesignTokens.Spacing.md)

            Hairline()
            if let loadError {
                Text("Could not load sessions: \(loadError)")
                    .font(OverlayType.caption)
                    .padding(DesignTokens.Spacing.sm)
            }
            content
            if let totalSessionCount, sessions.count < totalSessionCount, let onLoadMore {
                HStack {
                    Text("Loaded \(sessions.count) of \(totalSessionCount)")
                        .font(OverlayType.caption)
                    Spacer(minLength: 0)
                    Button("Load more", action: onLoadMore)
                        .buttonStyle(.overlaySecondary)
                        .disabled(isLoading)
                }
                .padding(DesignTokens.Spacing.sm)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if sessions.isEmpty {
            if isLoading {
                loadingRow
            } else {
                OverlayEmptyState(
                    systemImage: "clock.arrow.circlepath",
                    title: emptySessionCount > 0 ? "No sessions with activity" : "No sessions yet",
                    message: emptySessionCount > 0 ? "Include empty sessions to inspect or remove unused history." : "Recording, capturing a screen or asking a question starts a session."
                )
            }
        } else if groups.isEmpty {
            HistoryEmptyStateView(
                icon: "line.3.horizontal.decrease.circle",
                title: "No matching sessions",
                message: "Try another search or clear a filter."
            )
            .padding(DesignTokens.Spacing.md)
            Button("Clear filters") { resolver = SessionListResolver() }
                .buttonStyle(.overlaySecondary)
            Spacer(minLength: 0)
        } else {
            GroupedSessionListView(
                groups: groups,
                selectedSessionId: $selectedSessionId,
                metadataMap: metadataMap,
                onSelect: onSelect,
                activeSessionID: activeSessionID,
                deletionUnavailableReason: deletionUnavailableReason,
                onDelete: onDelete,
                batchSelection: $batchSelection
            )
        }
    }

    private var loadingRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Loading sessions")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

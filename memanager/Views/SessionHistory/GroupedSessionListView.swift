import SwiftUI

/// Sessions grouped by day bucket with pinned group headers. Each row is a
/// `SelectableRow` so selection and hover match every other list.
struct GroupedSessionListView: View {
    let groups: [SessionDateGroup]
    @Binding var selectedSessionId: String?
    let metadataMap: [String: SessionCardMetadata]
    var onSelect: ((String) -> Void)? = nil
    var activeSessionID: String? = nil
    var deletionUnavailableReason: (String) -> String? = { _ in nil }
    var onDelete: ((SessionRecord) -> Void)? = nil

    @Binding var batchSelection: HistoryBatchSelection

    var body: some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Spacing.xxs, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.sessions, id: \.id) { session in
                            HStack(spacing: DesignTokens.Spacing.xxs) {
                                if batchSelection.isSelecting {
                                    HistorySelectionCheckbox(
                                        id: session.id,
                                        title: SessionCardFormatter.dateLabel(session.startedAt),
                                        selection: $batchSelection,
                                        isEnabled: deletionUnavailableReason(session.id) == nil
                                    )
                                }
                                SelectableRow(isSelected: batchSelection.isSelecting ? batchSelection.ids.contains(session.id) : session.id == selectedSessionId, action: {
                                    if batchSelection.isSelecting {
                                        if deletionUnavailableReason(session.id) == nil { batchSelection.toggle(session.id) }
                                    } else {
                                        selectedSessionId = session.id
                                        onSelect?(session.id)
                                    }
                                }) {
                                    SessionCardView(session: session, metadata: metadataMap[session.id], isActive: session.id == activeSessionID)
                                }
                                if let onDelete, !batchSelection.isSelecting {
                                    Button(role: .destructive) { onDelete(session) } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.overlayIcon(size: 24))
                                    .disabled(deletionUnavailableReason(session.id) != nil)
                                    .help(deletionUnavailableReason(session.id) ?? "Delete session")
                                    .accessibilityLabel("Delete session from \(SessionCardFormatter.dateLabel(session.startedAt))")
                                    .accessibilityIdentifier("review.deleteSession.\(session.id)")
                                }
                            }
                            .contextMenu {
                                if let onDelete, !batchSelection.isSelecting {
                                    Button("Delete session", systemImage: "trash", role: .destructive) { onDelete(session) }
                                        .disabled(deletionUnavailableReason(session.id) != nil)
                                }
                            }
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, DesignTokens.Spacing.sm)
        }
    }

    private func groupHeader(_ group: SessionDateGroup) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            FieldLabel(text: group.bucket.rawValue)
            CountBadge(count: group.count)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.xs)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(OverlayPalette.canvas.opacity(0.85))
    }
}

import SwiftUI

/// Editable identity of a workspace. Every field debounces into one commit
/// so the store is not written per keystroke, pending edits are flushed
/// when the view disappears or the selection changes, and a commit only
/// ever applies to the workspace it was typed into.
struct WorkspaceMetadataForm: View {
    @ObservedObject var store: WorkspaceStore
    let workspace: JobWorkspace
    let breakpoint: OverlayLayout.Breakpoint

    @State private var draft: JobWorkspace
    @State private var tagsText: String
    @State private var pendingCommit: DispatchWorkItem?
    /// The last snapshot this form wrote to the store. When the store echoes
    /// it back (with a fresh updatedAt) the fields are left alone, so a
    /// commit never overwrites what was typed since.
    @State private var lastCommitted: JobWorkspace?
    @State private var saveFailed = false

    private static let debounce: TimeInterval = 0.8

    init(store: WorkspaceStore, workspace: JobWorkspace, breakpoint: OverlayLayout.Breakpoint = .regular) {
        self.store = store
        self.workspace = workspace
        self.breakpoint = breakpoint
        let restored = store.metadataDrafts[workspace.id] ?? workspace
        _draft = State(initialValue: restored)
        _tagsText = State(initialValue: WorkspaceTagsCodec.encode(restored.tags))
        _saveFailed = State(initialValue: store.metadataDrafts[workspace.id] != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            titleRow
            WorkspaceMetadataFields(draft: $draft, tagsText: $tagsText, breakpoint: breakpoint)
            if saveFailed {
                ToneBanner(tone: .critical, title: "Changes are not saved", message: store.lastError ?? "The draft is retained. Retry when storage is available.", actions: [BannerAction(title: "Retry save", action: { commit(against: workspace) })])
            } else {
                Text(pendingCommit == nil ? "Changes saved" : "Saving changes…")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
            }
        }
        .overlayCard(.base, padding: DesignTokens.Spacing.lg)
        .onChange(of: draft) { _, _ in scheduleCommit() }
        .onChange(of: tagsText) { _, _ in scheduleCommit() }
        .onSubmit { flushPendingCommit() }
        .onDisappear { flushPendingCommit() }
        .onChange(of: workspace) { previous, incoming in resync(previous: previous, incoming: incoming) }
    }

    private var titleRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: draft.status.systemImage)
                .font(OverlayType.title)
                .foregroundStyle(OverlayPalette.textSecondary)
            OverlayTextInput(placeholder: workspace.displayTitle, text: $draft.name, font: OverlayType.title)
            WorkspaceStageMenu(status: $draft.status)
        }
    }

    // MARK: Resync with the store

    private func resync(previous: JobWorkspace, incoming: JobWorkspace) {
        if incoming.id != draft.id {
            flushPendingCommit(against: previous)
            draft = store.metadataDrafts[incoming.id] ?? incoming
            tagsText = WorkspaceTagsCodec.encode(draft.tags)
            saveFailed = store.metadataDrafts[incoming.id] != nil
            lastCommitted = nil
            return
        }
        if let lastCommitted, WorkspaceMetadataForm.sameEditableContent(incoming, lastCommitted) {
            // Our own commit coming back: keep the fields as typed, but
            // absorb what the store owns (timestamps, archive state, folder).
            draft = WorkspaceMetadataForm.absorbingStoreOwnedFields(from: incoming, into: draft)
            return
        }
        if incoming.updatedAt <= draft.updatedAt {
            return
        }
        // A foreign write (archive button, import) landed: keep the text
        // being typed and take only the fields the form does not edit.
        draft = WorkspaceMetadataForm.absorbingStoreOwnedFields(from: incoming, into: draft)
    }

    // MARK: Commit pipeline

    private func scheduleCommit() {
        pendingCommit?.cancel()
        let baseline = workspace
        let work = DispatchWorkItem { commit(against: baseline) }
        pendingCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + WorkspaceMetadataForm.debounce, execute: work)
    }

    private func flushPendingCommit(against baseline: JobWorkspace? = nil) {
        guard let pendingCommit else { return }
        pendingCommit.cancel()
        self.pendingCommit = nil
        commit(against: baseline ?? workspace)
    }

    /// Applies the draft only to the workspace it was typed into.
    private func commit(against baseline: JobWorkspace) {
        pendingCommit = nil
        var updated = draft
        updated.tags = WorkspaceTagsCodec.decode(tagsText)
        guard updated.id == baseline.id, updated != baseline else { return }
        draft.tags = updated.tags
        store.metadataDrafts[updated.id] = updated
        saveFailed = !store.update(updated)
        if !saveFailed { lastCommitted = updated }
    }
}

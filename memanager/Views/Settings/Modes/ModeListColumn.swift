import SwiftUI

/// The list of modes with add, remove, and set active. Rows are selectable;
/// `onOpen` lets the compact column jump to the editor after a pick.
struct ModeListColumn: View {
    @ObservedObject var store: ModeStore
    @Binding var selectedModeID: UUID?
    var onOpen: (() -> Void)? = nil
    @State private var modeToRemove: Mode?

    private var canRemove: Bool {
        selectedModeID != nil && store.modes.count > 1
    }

    private var canActivate: Bool {
        selectedModeID != nil && selectedModeID != store.activeModeID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SurfaceHeader("Modes", count: store.modes.count, prominence: .heading)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignTokens.Spacing.sm) { listActions }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) { listActions }
            }

            VStack(spacing: DesignTokens.Spacing.xxs) {
                ForEach(store.modes) { mode in
                    ModeListRow(
                        mode: mode,
                        isSelected: mode.id == selectedModeID,
                        isActive: store.activeModeID == mode.id
                    ) {
                        selectedModeID = mode.id
                        onOpen?()
                    }
                }
            }
            .padding(DesignTokens.Spacing.xs)
            .overlayCard(.base, cornerRadius: DesignTokens.Radius.md)
        }
        .confirmationDialog("Delete \(modeToRemove?.title ?? "mode")?", isPresented: Binding(get: { modeToRemove != nil }, set: { if !$0 { modeToRemove = nil } }), titleVisibility: .visible) {
            Button("Delete mode", role: .destructive) {
                guard let mode = modeToRemove else { return }
                store.deleteMode(id: mode.id)
                ModeEditingState.shared.discard(modeID: mode.id)
                selectedModeID = store.modes.first?.id
                modeToRemove = nil
            }
            Button("Cancel", role: .cancel) { modeToRemove = nil }
        } message: {
            Text("This removes its saved prompt, attachments and any unsaved draft. Original files outside \(AppBrand.name) are kept.")
        }
    }

    @ViewBuilder
    private var listActions: some View {
        Button("New mode", action: addMode)
            .buttonStyle(.overlay(.secondary, size: .small))
        Button("Set active", action: activateSelected)
            .buttonStyle(.overlay(.secondary, size: .small))
            .disabled(!canActivate)
        Button("Delete mode") { modeToRemove = selectedModeID.flatMap { store.mode(with: $0) } }
            .buttonStyle(.overlay(.destructive, size: .small))
            .disabled(!canRemove)
    }

    private func activateSelected() {
        if let id = selectedModeID { store.setActive(id) }
    }

    private func addMode() {
        selectedModeID = store.addMode(title: "Untitled Mode").id
    }

}

/// One mode in the list: title, a one line summary, and the active badge.
struct ModeListRow: View {
    let mode: Mode
    let isSelected: Bool
    let isActive: Bool
    let action: () -> Void

    private var subtitle: String {
        ModeListRowSummary.subtitle(for: mode)
    }

    var body: some View {
        SelectableRow(isSelected: isSelected, action: action) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(mode.title.isEmpty ? "Untitled" : mode.title)
                        .font(OverlayType.callout)
                        .foregroundStyle(OverlayPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isActive {
                        ToneBadge(text: "Active", tone: .success)
                    }
                }
                Text(subtitle)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// Pure one line summary for a mode row.
enum ModeListRowSummary {
    static func subtitle(for mode: Mode) -> String {
        var parts: [String] = []
        if !mode.attachments.isEmpty {
            parts.append(mode.attachments.count == 1 ? "1 attachment" : "\(mode.attachments.count) attachments")
        }
        if mode.projectFolder?.isEnabled == true {
            parts.append("project folder")
        }
        if parts.isEmpty {
            let prompt = mode.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return prompt.isEmpty ? "Empty prompt" : prompt
        }
        return parts.joined(separator: ", ")
    }
}

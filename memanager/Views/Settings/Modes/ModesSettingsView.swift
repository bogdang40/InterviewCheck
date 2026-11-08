import SwiftUI

/// Which half of the Modes pane the compact column is showing.
enum ModesPaneColumn: String, CaseIterable {
    case list
    case editor
}

/// Root of the Modes pane. Two columns at regular width, a segment switch
/// between list and editor in the compact column. `ModeStore` is the single
/// source of truth; the pane only tracks the selection.
struct ModesSettingsView: View {
    @ObservedObject private var store = ModeStore.shared
    @Environment(\.settingsBreakpoint) private var breakpoint
    @ObservedObject private var editing = ModeEditingState.shared
    @State private var compactColumn: ModesPaneColumn = .list

    private var columnItems: [SegmentItem<ModesPaneColumn>] {
        [
            SegmentItem(id: .list, title: "Modes", systemImage: "list.bullet"),
            SegmentItem(id: .editor, title: "Editor", systemImage: "square.and.pencil")
        ]
    }

    var body: some View {
        Group {
            if breakpoint != .wide {
                compactLayout
            } else {
                regularLayout
            }
        }
        .onAppear {
            if editing.selectedModeID == nil {
                editing.selectedModeID = store.activeModeID ?? store.modes.first?.id
            }
        }
        .onChange(of: store.modes) { _, modes in
            editing.retain(modes)
        }
    }

    private var regularLayout: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.lg) {
            ModeListColumn(store: store, selectedModeID: $editing.selectedModeID)
                .frame(width: OverlayColumnWidth.minimumList)
            editor
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            SegmentStrip(items: columnItems, selection: $compactColumn)
                .fixedSize(horizontal: true, vertical: false)
            switch compactColumn {
            case .list:
                ModeListColumn(store: store, selectedModeID: $editing.selectedModeID) {
                    compactColumn = .editor
                }
            case .editor:
                editor
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let mode = resolveSelectedMode() {
            ModeEditorColumn(store: store, mode: mode)
                .id(mode.id)
        } else {
            OverlayEmptyState(
                systemImage: "square.stack.3d.up",
                title: "No mode selected",
                message: "Create a mode to tailor how Quick Assist answers.",
                primary: EmptyStateAction(title: "Create mode") {
                    editing.selectedModeID = store.addMode(title: "Untitled Mode").id
                }
            )
        }
    }

    private func resolveSelectedMode() -> Mode? {
        guard let selectedModeID = editing.selectedModeID else { return store.modes.first }
        return store.modes.first(where: { $0.id == selectedModeID })
    }
}

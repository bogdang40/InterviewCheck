import SwiftUI

struct HistoryBatchSelectionBar: View {
    @Binding var selection: HistoryBatchSelection
    let eligibleIDs: Set<String>
    let emptyIDs: Set<String>
    let onDelete: (Set<String>) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                if selection.isSelecting {
                    Text("\(selection.ids.count) selected")
                        .font(OverlayType.caption)
                    Spacer(minLength: 0)
                    Button("Done") { selection.finish() }
                } else {
                    Button("Select", systemImage: "checkmark.circle") { selection.isSelecting = true }
                        .disabled(eligibleIDs.isEmpty)
                    Spacer(minLength: 0)
                }
            }
            if selection.isSelecting {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button("Select shown") { selection.ids = eligibleIDs }
                        .disabled(eligibleIDs.isEmpty)
                    Button("Select empty") { selection.ids = emptyIDs.intersection(eligibleIDs) }
                        .disabled(emptyIDs.intersection(eligibleIDs).isEmpty)
                }
                HStack {
                    Button("Clear") { selection.ids = [] }
                        .disabled(selection.ids.isEmpty)
                    Spacer(minLength: 0)
                    Button("Delete selected", systemImage: "trash", role: .destructive) {
                        onDelete(selection.ids.intersection(eligibleIDs))
                    }
                    .disabled(selection.ids.isEmpty)
                    .accessibilityIdentifier("history.deleteSelected")
                }
            }
        }
        .buttonStyle(.overlay(.ghost, size: .small))
        .onChange(of: eligibleIDs) { _, eligible in selection.retainEligible(eligible) }
    }
}

struct HistorySelectionCheckbox: View {
    let id: String
    let title: String
    @Binding var selection: HistoryBatchSelection
    var isEnabled = true

    var body: some View {
        Toggle("Select \(title)", isOn: Binding(
            get: { selection.ids.contains(id) },
            set: { selected in
                if selected { selection.ids.insert(id) } else { selection.ids.remove(id) }
            }
        ))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(!isEnabled)
        .accessibilityLabel("Select \(title)")
        .accessibilityIdentifier("history.select.\(id)")
    }
}

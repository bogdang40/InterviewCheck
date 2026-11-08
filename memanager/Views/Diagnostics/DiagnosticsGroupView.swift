import SwiftUI

/// A diagnostics group as a disclosure card of label and value rows.
struct DiagnosticsGroupView: View {
    let group: DiagnosticsGroup

    @State private var isExpanded: Bool

    init(group: DiagnosticsGroup) {
        self.group = group
        _isExpanded = State(initialValue: !group.startsCollapsed)
    }

    var body: some View {
        DisclosureCard(group.title, systemImage: group.systemImage, count: group.rows.count, isExpanded: $isExpanded) {
            VStack(spacing: DesignTokens.Spacing.xs) {
                ForEach(group.rows) { row in
                    DiagnosticsRowView(row: row)
                }
            }
        }
    }
}

/// Caption label on the left, selectable mono value on the right.
struct DiagnosticsRowView: View {
    let row: DiagnosticsRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Text(row.label)
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textTertiary)
                .frame(width: 124, alignment: .leading)
                .lineLimit(1)
            Text(row.value)
                .font(OverlayType.mono)
                .foregroundStyle(OverlayPalette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

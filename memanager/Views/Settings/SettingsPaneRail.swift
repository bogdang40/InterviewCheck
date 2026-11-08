import SwiftUI

/// Vertical page list on the left of the Settings screen. Shows icons and
/// labels from the regular breakpoint and icons only in the compact column
/// so the page keeps its reading width.
struct SettingsPaneRail: View {
    let panes: [SettingsPane]
    @Binding var selection: SettingsPane
    let showsLabels: Bool

    static func width(showsLabels: Bool) -> CGFloat {
        showsLabels ? 164 : 48
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            ForEach(panes) { pane in
                SettingsPaneRailRow(
                    pane: pane,
                    isSelected: pane == selection,
                    showsLabel: showsLabels
                ) {
                    selection = pane
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.xs)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(width: Self.width(showsLabels: showsLabels))
        }
        .background(OverlayPalette.surface)
    }
}

struct SettingsPaneRailRow: View {
    let pane: SettingsPane
    let isSelected: Bool
    let showsLabel: Bool
    let action: () -> Void

    var body: some View {
        SelectableRow(isSelected: isSelected, action: action) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: pane.systemImage)
                    .font(OverlayType.callout)
                    .frame(width: 16)
                if showsLabel {
                    Text(pane.title)
                        .font(OverlayType.callout)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected ? OverlayPalette.accent : OverlayPalette.textSecondary)
        }
        .help(pane.title)
        .accessibilityLabel(pane.title)
    }
}

import SwiftUI

/// How a row arranges its control relative to the label.
enum SettingsRowLayout: Equatable {
    /// Control on the trailing edge, label on the leading edge.
    case trailing
    /// Control under the label at full width.
    case stacked
    /// Trailing at regular and wide widths, stacked in the compact column.
    case adaptive
}

/// One setting: a label, optional helper text, and a control. Every row in
/// the settings screen is built from this so the eye can scan a column of
/// labels and find the control in the same place each time.
struct SettingsRow<Control: View>: View {
    let title: String
    var helper: String? = nil
    var layout: SettingsRowLayout = .trailing
    @ViewBuilder var control: () -> Control

    @Environment(\.settingsBreakpoint) private var breakpoint

    private var isStacked: Bool {
        switch layout {
        case .trailing: return false
        case .stacked: return true
        case .adaptive: return breakpoint == .compact
        }
    }

    var body: some View {
        Group {
            if isStacked {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    labels
                    control()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
                    labels
                    Spacer(minLength: DesignTokens.Spacing.md)
                    control()
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, SettingsRowMetrics.verticalPadding)
        .frame(minHeight: SettingsRowMetrics.minimumHeight)
    }

    private var labels: some View {
        SettingsRowLabels(title: title, helper: helper)
    }
}

/// Shared measurements so rows built outside `SettingsRow` line up with it.
enum SettingsRowMetrics {
    static let verticalPadding: CGFloat = 10
    static let minimumHeight: CGFloat = 40
}

/// Label column shared by every row: title in the callout role and helper
/// text in the tertiary tone.
struct SettingsRowLabels: View {
    let title: String
    var helper: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
            Text(title)
                .font(OverlayType.callout)
                .foregroundStyle(OverlayPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let helper, !helper.isEmpty {
                Text(helper)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Read only row: a label with a value on the trailing edge.
struct SettingsValueRow: View {
    let title: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        SettingsRow(title: title) {
            Text(value)
                .font(monospaced ? OverlayType.mono : OverlayType.callout)
                .foregroundStyle(OverlayPalette.textSecondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

import SwiftUI

/// A labelled switch. The native toggle keeps its accessibility label while
/// the visible label lives in the row so it wraps like every other row.
struct SettingsToggleRow: View {
    let title: String
    var helper: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, helper: helper) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(OverlayPalette.accent)
        }
    }
}

import SwiftUI

/// An integer stepper with the current value printed beside it.
struct SettingsStepperRow: View {
    let title: String
    var helper: String? = nil
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    let caption: (Int) -> String

    var body: some View {
        SettingsRow(title: title, helper: helper) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text(caption(value))
                    .font(OverlayType.mono)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                Stepper(title, value: $value, in: range, step: step)
                    .labelsHidden()
                    .controlSize(.small)
            }
        }
    }
}

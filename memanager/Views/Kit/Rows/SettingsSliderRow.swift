import SwiftUI

/// A slider with its current value printed beside it in the mono role so
/// the number can be read without dragging. Sits beside the label at
/// regular width and drops under it in the compact column.
struct SettingsSliderRow<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
    let title: String
    var helper: String? = nil
    @Binding var value: Value
    let range: ClosedRange<Value>
    var step: Value.Stride? = nil
    var commitOnRelease = false
    /// Changing recipes cancels a draft even when the new saved scalar is equal.
    var editingContext: AnyHashable? = nil
    let caption: (Value) -> String

    @State private var editing = SettingsSliderEditingState<Value>()
    @Environment(\.isEnabled) private var isEnabled

    private static var controlWidth: CGFloat { 220 }

    private var displayedValue: Value {
        commitOnRelease ? editing.displayedValue(committed: value) : value
    }

    private var quantization: SettingsSliderQuantization<Value>? {
        step.flatMap { SettingsSliderQuantization(range: range, step: Value($0)) }
    }

    var body: some View {
        SettingsRow(title: title, helper: helper, layout: .adaptive) {
            HStack(spacing: DesignTokens.Spacing.md) {
                slider
                    .tint(OverlayPalette.accent)
                    .controlSize(.small)
                Text(caption(displayedValue))
                    .font(OverlayType.mono)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .monospacedDigit()
                    .frame(minWidth: 48, alignment: .trailing)
            }
            .frame(maxWidth: Self.controlWidth)
        }
        .onChange(of: value) { _, _ in editing.invalidate() }
        .onChange(of: range) { _, _ in editing.invalidate() }
        .onChange(of: step) { _, _ in editing.invalidate() }
        .onChange(of: editingContext) { _, _ in editing.invalidate() }
        .onChange(of: isEnabled) { _, enabled in
            // A retained, hidden control may never receive its drag-end callback.
            if !enabled { editing.cancel() }
        }
        .onDisappear { editing.cancel() }
    }

    @ViewBuilder
    private var slider: some View {
        if let quantization, quantization.usesContinuousSlider {
            // macOS 26 creates a tick layout for every step. Fine precision
            // belongs in the binding, not hundreds of invisible tick views.
            Slider(value: sliderValue, in: range,
                label: { Text(title) }, onEditingChanged: editingChanged)
                .labelsHidden()
                .accessibilityValue(Text(caption(displayedValue)))
                .accessibilityAdjustableAction { direction in
                    guard isEnabled else { return }
                    switch direction {
                    case .increment: adjustStep(increment: true)
                    case .decrement: adjustStep(increment: false)
                    @unknown default: break
                    }
                }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    guard isEnabled else { return .ignored }
                    adjustStep(increment: press.key == .rightArrow || press.key == .upArrow)
                    return .handled
                }
        } else if let step, quantization != nil {
            Slider(value: sliderValue, in: range, step: step,
                label: { Text(title) }, onEditingChanged: editingChanged)
                .labelsHidden()
        } else {
            Slider(value: sliderValue, in: range,
                label: { Text(title) }, onEditingChanged: editingChanged)
                .labelsHidden()
        }
    }

    private var sliderValue: Binding<Value> {
        return Binding(get: { displayedValue }, set: { proposed in
            guard isEnabled else { return }
            let proposed = quantization?.usesContinuousSlider == true
                ? quantization?.snapped(proposed) : proposed
            guard let proposed, proposed.isFinite else { return }
            if !commitOnRelease {
                if proposed != value { value = proposed }
            } else if let committed = editing.update(proposed, committed: value, range: range) {
                value = committed
            }
        })
    }

    private func adjustStep(increment: Bool) {
        guard isEnabled else { return }
        if let proposed = quantization?.adjusted(displayedValue, increment: increment) {
            sliderValue.wrappedValue = proposed
        }
    }

    private func editingChanged(_ isEditing: Bool) {
        guard isEnabled else { editing.cancel(); return }
        guard commitOnRelease else { return }
        if isEditing {
            editing.begin(committed: value)
        } else if let committed = editing.end(committed: value, range: range) {
            value = committed
        }
    }
}

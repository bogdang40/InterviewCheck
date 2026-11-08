import SwiftUI

/// The selected material's controls, shared with the native render fixture.
struct BorderShaderSettingsSection: View {
    @Binding var selection: BorderShaderStyle
    @Binding var configuration: BorderShaderConfiguration
    let onReset: () -> Void
    @State private var resetGeneration = 0

    private var controlsAreVisible: Bool { selection != .none }

    var body: some View {
        VStack(alignment: .leading, spacing: controlsAreVisible ? DesignTokens.Spacing.xl : 0) {
            SettingsSection("Border shader", footer: footer, trailing: {
                if selection != .none {
                    Button("Reset") {
                        // Discard drafts even when the saved recipe already equals the preset.
                        resetGeneration += 1
                        onReset()
                    }
                        .buttonStyle(.overlay(.ghost, size: .small))
                        .accessibilityLabel("Reset \(selection.title) border")
                        .accessibilityIdentifier("appearance.border.reset")
                }
            }) {
                Picker("Border shader", selection: $selection) {
                    ForEach(BorderShaderStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Border shader")
                .accessibilityIdentifier("appearance.borderShaderStyle")
            }

            RetainedSettingsContent(isVisible: controlsAreVisible) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
                    shapeControls
                    opticalControls
                    motionControls
                }
            }
            .id(resetGeneration)
        }
    }

    private var footer: String {
        selection.description + (selection == .none ? "" : " Slider changes apply when you release the control.")
    }

    private var shapeControls: some View {
        SettingsSection("Border shape") {
            SettingsSliderRow(title: "Width", value: $configuration.width,
                range: 2...48, step: 1, commitOnRelease: true, editingContext: selection) { "\(Int($0.rounded()))pt" }
                .accessibilityIdentifier("appearance.border.width")

            SettingsSliderRow(title: "Depth", value: Binding(
                get: { configuration.effectiveDepth },
                set: { configuration.depth = $0 }),
                range: 1...configuration.maximumDepth, step: 0.1, commitOnRelease: true, editingContext: selection) { decimal($0, places: 1) + "pt" }
                .accessibilityIdentifier("appearance.border.depth")

            SettingsSliderRow(title: "Fluidity", helper: "Movement of the border's outline.",
                value: $configuration.fluidity, range: 0...1, commitOnRelease: true, editingContext: selection) { percent($0) }
                .accessibilityIdentifier("appearance.border.fluidity")

            SettingsSliderRow(title: "Water ripples", helper: "Fine waves across the surface.",
                value: $configuration.waterRipples, range: 0...1, commitOnRelease: true, editingContext: selection) { percent($0) }
                .accessibilityIdentifier("appearance.border.waterRipples")
        }
    }

    private var opticalControls: some View {
        SettingsSection("Border optics") {
            SettingsSliderRow(title: "Refraction (IOR)", helper: "How strongly the border bends light.",
                value: $configuration.ior, range: 1...2.2, step: 0.001, commitOnRelease: true, editingContext: selection) { decimal($0, places: 3) }
                .accessibilityIdentifier("appearance.border.ior")

            SettingsSliderRow(title: "Color dispersion", helper: "Separation of color at the edges.",
                value: $configuration.dispersion, range: 0...0.06, step: 0.001, commitOnRelease: true, editingContext: selection) { decimal($0, places: 3) }
                .accessibilityIdentifier("appearance.border.dispersion")

            SettingsSliderRow(title: "Roughness", value: $configuration.roughness,
                range: 0...0.08, step: 0.001, commitOnRelease: true, editingContext: selection) { decimal($0, places: 3) }
                .accessibilityIdentifier("appearance.border.roughness")

            SettingsSliderRow(title: "Border intensity", value: $configuration.reflectionStrength,
                range: 0...1, commitOnRelease: true, editingContext: selection) { percent($0) }
                .accessibilityIdentifier("appearance.border.reflectionStrength")

            SettingsSliderRow(title: "Transmission amount", value: $configuration.transmissionShare,
                range: 0...0.35, commitOnRelease: true, editingContext: selection) { percent($0) }
                .accessibilityIdentifier("appearance.border.transmissionShare")
        }
    }

    private var motionControls: some View {
        SettingsSection("Border motion") {
            SettingsSliderRow(title: "Moving light", value: $configuration.lightStrength,
                range: 0...1, commitOnRelease: true, editingContext: selection) { percent($0) }
                .accessibilityIdentifier("appearance.border.lightStrength")

            SettingsToggleRow(title: "Animate border", isOn: $configuration.animationEnabled)
                .accessibilityIdentifier("appearance.border.animationEnabled")

            SettingsSliderRow(title: "Motion speed", value: $configuration.motionSpeed,
                range: 0.1...2, step: 0.1, commitOnRelease: true, editingContext: selection) { decimal($0, places: 1) + "×" }
                .accessibilityIdentifier("appearance.border.motionSpeed")
        }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    private func decimal(_ value: Double, places: Int) -> String {
        value.formatted(.number.precision(.fractionLength(places)))
    }
}

/// Keep native controls mounted at their natural size while collapsing their
/// contribution to the page. Hidden controls cannot receive input or AX focus.
struct RetainedSettingsContent<Content: View>: View {
    let isVisible: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: isVisible ? nil : 0, alignment: .top)
            .clipped()
            .opacity(isVisible ? 1 : 0)
            .disabled(!isVisible)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}

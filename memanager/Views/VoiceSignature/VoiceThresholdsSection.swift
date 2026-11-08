import SwiftUI

/// Recognition thresholds as a preset strip plus two sliders, and the live
/// test that shows them in action.
struct VoiceThresholdsSection: View {
    @ObservedObject var store: VoiceSignatureStore
    @Binding var selectedPreset: VoiceStrictnessPreset
    let onLiveTest: () -> Void

    private var presetItems: [SegmentItem<VoiceStrictnessPreset>] {
        VoiceStrictnessPreset.allCases.map { SegmentItem(id: $0, title: $0.rawValue) }
    }

    private var canTest: Bool {
        store.hasProfile && store.accessKeyStatus.isConfigured
    }

    var body: some View {
        SettingsSection(
            "Recognition thresholds",
            footer: "Higher thresholds mean fewer false positives but may miss some of your speech."
        ) {
            SettingsRow(title: "Strictness", layout: .adaptive) {
                SegmentStrip(items: presetItems, selection: $selectedPreset) { preset in
                    applyPreset(preset)
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            SettingsSliderRow(
                title: "Enter threshold",
                helper: "Score needed before speech counts as you.",
                value: $store.thresholdEnterMe,
                range: 0.5...1.0,
                step: 0.01
            ) { String(format: "%.2f", $0) }
            .onChange(of: store.thresholdEnterMe) { _, value in
                store.thresholdExitMe = VoiceStrictnessPreset.clampedExit(store.thresholdExitMe, enter: value)
                syncPreset()
            }

            SettingsSliderRow(
                title: "Exit threshold",
                helper: "Score below which speech stops counting as you.",
                value: $store.thresholdExitMe,
                range: 0.0...1.0,
                step: 0.01
            ) { String(format: "%.2f", $0) }
            .onChange(of: store.thresholdExitMe) { _, newValue in
                let clamped = VoiceStrictnessPreset.clampedExit(newValue, enter: store.thresholdEnterMe)
                if clamped != newValue { store.thresholdExitMe = clamped }
                syncPreset()
            }
        }

        SettingsSection("Test recognition") {
            SettingsRow(
                title: "Live test",
                helper: canTest
                    ? "Speak to see recognition scores and labels in real time."
                    : "Needs an enrolled profile and a Picovoice AccessKey."
            ) {
                Button("Start live test", action: onLiveTest)
                    .buttonStyle(.overlay(.secondary, size: .small))
                    .disabled(!canTest)
            }
        }
    }

    private func applyPreset(_ preset: VoiceStrictnessPreset) {
        guard let thresholds = preset.thresholds else { return }
        store.thresholdEnterMe = thresholds.enter
        store.thresholdExitMe = thresholds.exit
    }

    private func syncPreset() {
        selectedPreset = VoiceStrictnessPreset.from(enter: store.thresholdEnterMe, exit: store.thresholdExitMe)
    }
}

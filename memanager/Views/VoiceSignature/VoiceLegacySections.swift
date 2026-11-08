import SwiftUI

/// Legacy identification on the mixed stream: manual marking or automatic
/// matching against the enrolled voice.
struct VoiceLegacyIdentificationSection: View {
    @ObservedObject var store: VoiceSignatureStore

    private var modeItems: [SegmentItem<SpeakerIdentificationMode>] {
        SpeakerIdentificationMode.allCases.map { SegmentItem(id: $0, title: $0.displayName) }
    }

    private var footer: String {
        switch store.speakerIdentificationMode {
        case .auto:
            return "Auto mode marks the current diarized speaker as you when it detects your voice. It needs voice signature recognition and an enrolled profile. Tap a transcript row or use the mark shortcut to override."
        case .manual:
            return "Tap a transcript row or use the mark shortcut to identify yourself."
        }
    }

    var body: some View {
        SettingsSection("Legacy identification", footer: footer, trailing: {
            KeyHint(label: "Mark me", shortcut: ShortcutCatalog.shortcut(for: "markCurrentSpeaker", fallback: "Cmd+Shift+M"))
        }) {
            SettingsRow(
                title: "Mode",
                helper: "All speakers are identified acoustically on the mixed stream.",
                layout: .adaptive
            ) {
                SegmentStrip(items: modeItems, selection: $store.speakerIdentificationMode)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

/// Gain balance between the microphone and system audio for legacy mode.
struct VoiceLegacyMixSection: View {
    @ObservedObject var store: VoiceSignatureStore

    private var micGain: Binding<Double> {
        Binding(get: { Double(store.legacyMicGain) }, set: { store.legacyMicGain = Float($0) })
    }

    private var systemGain: Binding<Double> {
        Binding(get: { Double(store.legacySystemGain) }, set: { store.legacySystemGain = Float($0) })
    }

    var body: some View {
        SettingsSection(
            "Legacy mix balance",
            footer: "Applies only to the mixed audio mode. Helps diarization when one source dominates."
        ) {
            SettingsToggleRow(
                title: "Auto balance mic and system",
                helper: "Levels both sources before they are mixed.",
                isOn: $store.legacyAutoBalanceEnabled
            )
            SettingsSliderRow(title: "Mic gain", value: micGain, range: 0...2) { String(format: "%.2fx", $0) }
            SettingsSliderRow(title: "System gain", value: systemGain, range: 0...2) { String(format: "%.2fx", $0) }
        }
    }
}

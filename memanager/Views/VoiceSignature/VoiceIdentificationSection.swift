import SwiftUI

/// The primary choice: label speakers by audio source, or fall back to the
/// legacy acoustic identification on the mixed stream.
struct VoiceIdentificationSection: View {
    @ObservedObject var store: VoiceSignatureStore

    var body: some View {
        SettingsSection(
            "Speaker identification",
            footer: store.useSourceBasedIdentification
                ? "Recommended for video calls and remote meetings."
                : "Legacy mode analyses one mixed stream and needs a voice profile to tell you apart."
        ) {
            SettingsToggleRow(
                title: "Source based identification",
                helper: "Your microphone is you. System audio is everyone else.",
                isOn: $store.useSourceBasedIdentification
            )

            if store.useSourceBasedIdentification {
                SettingsRow(title: "Microphone", helper: "Always labelled as you.") {
                    ToneBadge(text: "You", tone: .info, systemImage: "mic.fill")
                }
                SettingsRow(title: "System audio", helper: "Call participants are separated by Deepgram diarization.") {
                    ToneBadge(text: "Others", tone: .neutral, systemImage: "speaker.wave.2.fill")
                }
            }
        }
    }
}

/// Echo de duplication for source based mode.
struct VoiceEchoFilterSection: View {
    @ObservedObject var store: VoiceSignatureStore

    var body: some View {
        SettingsSection(
            "Echo filter",
            footer: store.echoFilterEnabled
                ? "Higher similarity means stricter matching. A larger window catches delayed echoes."
                : "When off, every transcription is kept even if it appears on both streams."
        ) {
            SettingsToggleRow(
                title: "Filter duplicate transcriptions",
                helper: "Removes duplicate transcript lines that appear on both audio streams.",
                isOn: $store.echoFilterEnabled
            )

            if store.echoFilterEnabled {
                SettingsSliderRow(
                    title: "Similarity",
                    value: $store.echoFilterThreshold,
                    range: 0.3...0.95,
                    step: 0.05
                ) { String(format: "%.0f%%", $0 * 100) }

                SettingsSliderRow(
                    title: "Time window",
                    value: $store.echoFilterTimeWindow,
                    range: 0.5...5.0,
                    step: 0.5
                ) { String(format: "%.1fs", $0) }
            }
        }
    }
}

import SwiftUI

/// Overlay opacity and text size, audio capture, diagnostics, the
/// intelligent hub switches, and the one destructive action at the bottom.
struct AppearanceSettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        let borderStyle = settings.borderShaderStyle
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xl) {
            SettingsSection("Appearance", footer: "System follows macOS. Light and Dark keep your choice when the system changes. Accessibility display preferences apply in either appearance.") {
                Picker("Appearance", selection: $settings.overlayAppearance) {
                    ForEach(OverlayAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearance.preference")
            }

            BorderShaderSettingsSection(
                selection: $settings.borderShaderStyle,
                configuration: Binding(
                    get: { settings.configuration(for: borderStyle) ?? .liquidDefault },
                    set: {
                        guard settings.borderShaderStyle == borderStyle else { return }
                        settings.updateConfiguration($0, for: borderStyle)
                    }),
                onReset: { settings.resetConfiguration(for: settings.borderShaderStyle) })

            SettingsSection("Overlay") {
                SettingsSliderRow(
                    title: "Opacity",
                    helper: "How solid the panel is over the call.",
                    value: $settings.overlayOpacity,
                    range: 0.5...1.0,
                    commitOnRelease: true
                ) { "\(Int(($0 * 100).rounded()))%" }

                SettingsSliderRow(
                    title: "Font size",
                    helper: "Reading size for answers and transcripts.",
                    value: $settings.fontSize,
                    range: 10...24,
                    step: 1,
                    commitOnRelease: true
                ) { "\(Int($0))pt" }
            }

            AppearanceReadingPreview(fontSize: settings.fontSize, opacity: settings.overlayOpacity)

            SettingsSection("Audio") {
                SettingsToggleRow(
                    title: "Capture system audio",
                    helper: "Hears the other side of the call. macOS shows its sharing indicator while this is on.",
                    isOn: $settings.captureSystemAudio
                )
            }

            SettingsSection("Diagnostics", trailing: {
                KeyHint(label: "Toggle", shortcut: ShortcutCatalog.toggleDiagnostics)
            }) {
                SettingsToggleRow(
                    title: "Session diagnostics overlay",
                    helper: "Timing and pipeline detail in the top corner.",
                    isOn: $settings.showDiagnosticsOverlay
                )
                SettingsToggleRow(
                    title: "Force legacy Apple dictation",
                    helper: "Disables the on device analyzer and Deepgram.",
                    isOn: $settings.forceAppleSpeech
                )
            }

            AppearanceHubSection()
        }
    }
}

/// Uses the same glass chrome and translucent reading veil as the live overlay.
private struct AppearanceReadingPreview: View {
    let fontSize: Double
    let opacity: Double

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Preview")
                .font(OverlayType.callout)
                .foregroundStyle(OverlayPalette.textPrimary)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Label("Say first", systemImage: "waveform")
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.accent)
                    Spacer(minLength: 0)
                    Text("Example answer")
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textSecondary)
                }
                Text("I'd use an idempotency key so retries don't create duplicate payments.")
                    .font(.system(size: fontSize))
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignTokens.Spacing.md)
                    .background(OverlayPalette.readingSurface, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(DesignTokens.Spacing.lg)
            .pearlGlass(opacity: opacity, radius: 20)

            Text("Glass follows opacity. Your desktop stays visible through the reading surface.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("appearance.readingPreview")
    }
}

/// The intelligent hub switches and the clear memory action, isolated so
/// the destructive button is the last thing on the page.
struct AppearanceHubSection: View {
    @ObservedObject private var settings = SettingsManager.shared
    @State private var confirmsClearMemory = false

    var body: some View {
        SettingsSection("Intelligent hub") {
            SettingsToggleRow(title: "Intent router", helper: "Routes each question to the right playbook.", isOn: $settings.hubRouterEnabled)
            SettingsToggleRow(title: "Cross session memory", helper: "Remembers answers and facts between sessions.", isOn: $settings.hubMemoryEnabled)
            SettingsToggleRow(title: "Proactive interview nudges", helper: "Coaching lines while you answer.", isOn: $settings.hubProactiveNudgesEnabled)
            SettingsToggleRow(title: "Proactive failure coach", helper: "Flags likely misses and suggests recoveries.", isOn: $settings.hubFailureCoachEnabled)
            SettingsToggleRow(title: "Open timeline for coach suggestions", helper: "Jumps to the timeline when the coach speaks.", isOn: $settings.hubFailureCoachAutoOpenTimeline)
                .disabled(!settings.hubFailureCoachEnabled)
                .opacity(settings.hubFailureCoachEnabled ? 1 : 0.45)
            SettingsToggleRow(title: "Quick Assist auto compare", helper: "Scores answers against a second provider.", isOn: $settings.quickAssistAutoCompareEnabled)
            SettingsToggleRow(title: "Session debriefs", helper: "Writes a debrief when a session ends.", isOn: $settings.sessionAutoDebriefEnabled)
            SettingsToggleRow(title: "Encrypted replay snapshots", helper: "Keeps manual screenshots for replay.", isOn: $settings.sessionReplayStorageEnabled)
        }

        SettingsSection("Reset", footer: "Clearing removes everything the hub remembered across sessions. This cannot be undone.") {
            SettingsRow(title: "Clear hub memory", helper: "Available while cross session memory is on.") {
                Button("Clear memory") {
                    confirmsClearMemory = true
                }
                .buttonStyle(.overlay(.destructive, size: .small))
                .disabled(!settings.hubMemoryEnabled)
            }
        }
        .confirmationDialog("Clear all cross session hub memory?", isPresented: $confirmsClearMemory) {
            Button("Clear hub memory", role: .destructive) { SessionController.shared.clearHubMemory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the hub's remembered context. Your session history and workspace documents remain available.")
        }
    }
}

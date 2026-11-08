import AppKit
import SwiftUI

/// A review of current setup, not a successful connection or capture test.
struct SessionReadinessView: View {
    @ObservedObject private var permissions = PermissionManager.shared
    @ObservedObject private var settings = SettingsManager.shared
    @State private var usesAudio = true
    let onBack: () -> Void
    var onSelectPane: (SettingsPane) -> Void = { OverlayNavigator.shared.showSettings($0) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                Button("Back to Settings", action: onBack)
                    .buttonStyle(.overlay(.ghost, size: .small))
                SurfaceHeader("Review session setup", subtitle: "Check the sources you plan to use before starting a session.")
                Picker("Session input", selection: $usesAudio) {
                    Text("Listen to a call").tag(true)
                    Text("Use a screenshot").tag(false)
                }
                .pickerStyle(.segmented)
                SettingsSection("System access") {
                    if usesAudio {
                        readinessRow("Microphone", helper: "Capture your speech", status: permissions.microphoneStatus)
                        readinessRow("System audio", helper: "Capture the other side of a call using Screen Recording access", status: permissions.screenRecordingStatus)
                        readinessRow("Speech Recognition", helper: "Used when Apple transcription is selected", status: permissions.speechRecognitionStatus)
                    } else {
                        readinessRow("Screen Recording", helper: "Capture a screenshot for Solve or Design", status: permissions.screenRecordingStatus)
                    }
                    readinessRow("Accessibility", helper: "Use global shortcuts while another app has focus", status: permissions.accessibilityStatus)
                }
                SettingsSection("Answer provider") {
                    SettingsRow(title: settings.selectedProvider.displayName,
                                helper: settings.apiKeyStatus(for: settings.selectedProvider).message,
                                layout: .adaptive) {
                        Button("Open Providers") { onSelectPane(.aiProvider) }
                            .buttonStyle(.overlay(.secondary, size: .small))
                    }
                }
                Text("Voice enrollment is optional. Permission and stored key status do not confirm that capture or a provider request will succeed.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Permissions") { onSelectPane(.permissions) }
                        .buttonStyle(.overlaySecondary)
                    Spacer(minLength: 0)
                    Button("Refresh") { permissions.refreshAllStatuses() }
                        .buttonStyle(.overlayPrimary)
                }
            }
            .padding(OverlayLayout.stageInset)
            .frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { permissions.refreshAllStatuses() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refreshAllStatuses()
        }
    }

    private func readinessRow(_ title: String, helper: String, status: PermissionStatus) -> some View {
        SettingsRow(title: title, helper: helper, layout: .adaptive) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                ToneBadge(text: status.displayText, tone: PermissionRowState.badgeTone(for: status))
                Button("Review") { onSelectPane(.permissions) }
                    .buttonStyle(.overlay(.ghost, size: .small))
                    .accessibilityLabel("Review \(title) permission")
            }
        }
    }
}

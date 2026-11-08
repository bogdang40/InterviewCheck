import AppKit
import SwiftUI

/// Current readiness first, with full subsystem data available on demand.
struct DiagnosticsPanelView: View {
    @ObservedObject private var audioService = AudioCaptureService.shared
    @ObservedObject private var permissionManager = PermissionManager.shared
    @ObservedObject private var controller = SessionController.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var voiceStore = VoiceSignatureStore.shared

    @State private var showsTechnicalDetails = false

    let onClose: () -> Void
    var availableWidth: CGFloat = Self.width

    static let width: CGFloat = 380
    private let maximumHeight: CGFloat = 600

    private var groups: [DiagnosticsGroup] {
        let system = DiagnosticsSystemReport(audioService: audioService, permissionManager: permissionManager, controller: controller)
        return [
            DiagnosticsSessionReport(controller: controller, settings: settings).group,
            DiagnosticsAudioReport(audioService: audioService, settings: settings, permissionManager: permissionManager, voiceStore: voiceStore).group,
            system.transcriptGroup,
            system.permissionsGroup,
            system.errorsGroup
        ]
    }

    private var captureModel: SessionPillModel {
        SessionPillModel(state: controller.session.state, isRecording: audioService.isRecording,
                         isLoading: controller.isLoading, isStreaming: controller.isStreaming)
    }

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeader("Diagnostics", systemImage: "stethoscope", subtitle: "Capture, provider and system access") {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.overlayIcon(size: 24))
                .accessibilityLabel("Close diagnostics")
                .help("Close diagnostics")
            }
            .padding(DesignTokens.Spacing.md)
            Hairline()
            ScrollView {
                VStack(spacing: DesignTokens.Spacing.sm) {
                    captureSummary
                    providerSummary
                    permissionsSummary
                    DisclosureCard("Technical details", systemImage: "slider.horizontal.3",
                                   isExpanded: $showsTechnicalDetails) {
                        VStack(spacing: DesignTokens.Spacing.sm) {
                            ForEach(groups) { group in
                                DiagnosticsGroupView(group: group)
                            }
                        }
                    }
                }
                .padding(DesignTokens.Spacing.md)
            }
            .frame(maxHeight: maximumHeight)
        }
        .frame(width: min(Self.width, max(0, availableWidth)))
        .overlayCard(.overlay)
        .onAppear { permissionManager.refreshAllStatuses() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissionManager.refreshAllStatuses()
        }
    }

    private var captureSummary: some View {
        summaryCard("Capture", systemImage: "waveform") {
            HStack(spacing: DesignTokens.Spacing.sm) {
                StatusDot(state: captureModel.dotState, size: 7)
                Text(audioService.isStartingCaptureFlag ? "Starting capture" : captureModel.label)
                    .font(OverlayType.heading)
                    .foregroundStyle(OverlayPalette.textPrimary)
            }
            Text("Audio capture: \(audioService.isRecording ? "running" : "inactive") · System audio: \(audioService.isSystemAudioActive ? "active" : "inactive")")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let issue = audioService.transcriptionError?.errorDescription ?? audioService.errorMessage {
                Text(issue)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button("Capture settings") { openSettings(.appearance) }
                    .buttonStyle(.overlay(.secondary, size: .small))
                if audioService.isRecording && audioService.activeTranscriptionMode.usesDualStreamTopology {
                    Button("Retry system audio") { audioService.retrySystemStream() }
                        .buttonStyle(.overlay(.secondary, size: .small))
                        .help("Restart the system audio stream for the active session")
                }
            }
        }
    }

    private var providerSummary: some View {
        summaryCard("Answer provider", systemImage: "brain") {
            Text(controller.currentProviderDisplayName)
                .font(OverlayType.heading)
                .foregroundStyle(OverlayPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(settings.apiKeyStatus(for: settings.selectedProvider).message)
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Providers") { openSettings(.aiProvider) }
                .buttonStyle(.overlay(.secondary, size: .small))
        }
    }

    private var permissionsSummary: some View {
        summaryCard("System access", systemImage: "hand.raised") {
            permissionRow("Microphone", status: permissionManager.microphoneStatus)
            permissionRow("Screen and system audio", status: permissionManager.screenRecordingStatus)
            permissionRow("Speech Recognition", status: permissionManager.speechRecognitionStatus)
            permissionRow("Accessibility", status: permissionManager.accessibilityStatus)
            Text("Speech Recognition is used for Apple transcription. Permission status does not confirm successful capture.")
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button("Open Permissions") { openSettings(.permissions) }
                    .buttonStyle(.overlay(.secondary, size: .small))
                Button("Refresh") { permissionManager.refreshAllStatuses() }
                    .buttonStyle(.overlay(.ghost, size: .small))
            }
        }
    }

    private func permissionRow(_ title: String, status: PermissionStatus) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text(title)
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textPrimary)
            Spacer(minLength: 0)
            ToneBadge(text: status.displayText, tone: PermissionRowState.badgeTone(for: status))
        }
    }

    private func summaryCard<Content: View>(_ title: String, systemImage: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Label(title, systemImage: systemImage)
                .font(OverlayType.caption)
                .foregroundStyle(OverlayPalette.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlayCard(.base, padding: DesignTokens.Spacing.md)
    }

    private func openSettings(_ pane: SettingsPane) {
        onClose()
        OverlayNavigator.shared.showSettings(pane)
    }
}

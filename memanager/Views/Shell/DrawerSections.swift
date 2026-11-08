import SwiftUI

/// Transcript section of the context drawer: the latest rows, the live
/// state, transcription errors with their recovery actions, and a way to
/// open the full transcript surface.
struct TranscriptDrawerSection: View {
    @ObservedObject private var audioService = AudioCaptureService.shared
    @ObservedObject private var controller = SessionController.shared
    @ObservedObject private var voiceStore = VoiceSignatureStore.shared
    @AppStorage("memanager.drawer.transcriptExpanded", store: AppDefaults.standard) private var isExpanded = true

    private static let rowLimit = 14

    private var rows: [TranscriptRowModel] {
        TranscriptRowsBuilder.rows(
            entries: audioService.transcriptEntries,
            partialMe: audioService.partialMe,
            partialOther: audioService.partialOther,
            partialOtherSpeaker: audioService.partialOtherSpeaker,
            limit: Self.rowLimit
        )
    }

    private var tone: OverlayTone {
        if audioService.transcriptionError != nil { return .warning }
        if audioService.isRecording { return .success }
        if !audioService.transcriptEntries.isEmpty { return .info }
        return .neutral
    }

    var body: some View {
        DisclosureCard(
            "Transcript",
            systemImage: "waveform",
            count: audioService.transcriptEntries.count,
            tone: tone,
            isExpanded: $isExpanded,
            trailing: {
                Button {
                    controller.showTranscriptLog()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.overlayIcon(size: 20, bordered: false))
                .help("Open the full transcript (\(ShortcutCatalog.openTranscript))")
            }
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                if let error = audioService.transcriptionError {
                    TranscriptionErrorBanner(
                        error: error,
                        onOpenSettings: { audioService.openSystemSettings() },
                        onRetry: { audioService.retrySystemStream() },
                        onDismiss: { audioService.clearError() }
                    )
                }
                if rows.isEmpty {
                    Text(audioService.isRecording ? "Listening for speech" : "Nothing captured yet")
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textTertiary)
                } else {
                    TranscriptList(
                        rows: rows,
                        density: .compact,
                        fontSize: 12,
                        scrollTarget: nil,
                        useSourceBasedIdentification: voiceStore.useSourceBasedIdentification,
                        onSpeakerTapped: { audioService.markSpeakerAsMe($0) }
                    )
                    .frame(maxHeight: 260)
                }
            }
        }
    }
}

/// Screenshot stack in the drawer with capture and clear actions.
struct ScreenshotsDrawerSection: View {
    @ObservedObject private var screenshotService = ScreenshotService.shared
    @AppStorage("memanager.drawer.screenshotsExpanded", store: AppDefaults.standard) private var isExpanded = true

    var body: some View {
        DisclosureCard(
            "Screenshots",
            systemImage: "photo.on.rectangle",
            count: screenshotService.screenshots.count,
            isExpanded: $isExpanded,
            trailing: {
                Button {
                    screenshotService.captureFullScreen()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.overlayIcon(size: 20, bordered: false))
                .help("Capture the screen (\(ShortcutCatalog.screenshot))")
            }
        ) {
            ScreenshotStack(
                screenshots: screenshotService.screenshots,
                onRemove: { id in
                    if let index = screenshotService.screenshots.firstIndex(where: { $0.id == id }) {
                        screenshotService.removeScreenshot(at: index)
                    }
                },
                onClearAll: { screenshotService.clearAll() }
            )
        }
    }
}

/// Related memory snippets Quick Assist will cite, with pin toggles.
struct MemoryDrawerSection: View {
    @ObservedObject private var controller = SessionController.shared
    @AppStorage("memanager.drawer.memoryExpanded", store: AppDefaults.standard) private var isExpanded = false
    @State private var confirmsClear = false

    var body: some View {
        DisclosureCard(
            "Related memory",
            systemImage: "brain.head.profile",
            count: controller.quickAssistRelatedMemorySnippets.count,
            isExpanded: $isExpanded
        ) {
            if controller.quickAssistRelatedMemorySnippets.isEmpty {
                Text("Past turns and debriefs that match the conversation appear here.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    ForEach(controller.quickAssistRelatedMemorySnippets, id: \.id) { snippet in
                        MemorySnippetRow(snippet: snippet) {
                            controller.toggleQuickAssistMemoryPin(snippet.id)
                        }
                    }
                    Button("Clear memory", role: .destructive) {
                        confirmsClear = true
                    }
                    .buttonStyle(.overlay(.destructive, size: .small))
                }
            }
        }
        .confirmationDialog("Clear related memory?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear memory", role: .destructive) { controller.clearHubMemory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes stored memory nodes and their links. Session transcripts and saved answers remain available.")
        }
    }
}

struct MemorySnippetRow: View {
    let snippet: RelatedMemorySnippet
    let onTogglePin: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.text)
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(snippet.sourceType.rawValue) \(Int((snippet.score * 100).rounded()))%")
                    .font(OverlayType.monoMicro)
                    .foregroundStyle(OverlayPalette.textTertiary)
            }
            Spacer(minLength: 0)
            Button(action: onTogglePin) {
                Image(systemName: snippet.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.overlayIcon(size: 20, isActive: snippet.isPinned, bordered: false))
            .help(snippet.isPinned ? "Unpin" : "Pin so every turn includes it")
        }
    }
}

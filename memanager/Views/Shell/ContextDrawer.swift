import SwiftUI

/// Context can be hosted beside a wide answer or in a compact sheet.
/// Opening it never changes the active Live mode or clears a draft.
struct ContextDrawer: View {
    enum Tab: String, CaseIterable, Identifiable {
        case context = "Sources", transcript = "Transcript", screenshots = "Screenshots", threads = "Conversation"
        var id: String { rawValue }
        var title: String { rawValue }
    }

    @ObservedObject private var audio = AudioCaptureService.shared
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var voice = VoiceSignatureStore.shared
    @State private var tab: Tab
    @Binding private var historySearchFocusRequested: Bool
    let onClose: () -> Void

    init(initialTab: Tab = .context, historySearchFocusRequested: Binding<Bool> = .constant(false), onClose: @escaping () -> Void) {
        _tab = State(initialValue: initialTab)
        _historySearchFocusRequested = historySearchFocusRequested
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tab.title).font(OverlayType.heading)
                Spacer()
                Button("Close", systemImage: "xmark", action: onClose)
                    .buttonStyle(.overlay(.ghost, size: .small))
            }
            .padding(DesignTokens.Spacing.md)
            SegmentStrip(items: Tab.allCases.map { SegmentItem(id: $0, title: $0.title) }, selection: $tab)
                .padding(.horizontal, DesignTokens.Spacing.sm)
            Hairline()
            switch tab {
            case .context:
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        Text("Captured context")
                            .font(OverlayType.title).foregroundStyle(OverlayPalette.textPrimary)
                        Text("Review the transcript, screenshots and related memory. Context changes apply to the next request.")
                            .font(OverlayType.caption).foregroundStyle(OverlayPalette.textSecondary)
                        TranscriptDrawerSection()
                        ScreenshotsDrawerSection()
                        MemoryDrawerSection()
                    }
                    .padding(DesignTokens.Spacing.md)
                }
            case .transcript:
                TranscriptSurface(
                    rows: TranscriptRowsBuilder.rows(
                        entries: audio.transcriptEntries, partialMe: audio.partialMe,
                        partialOther: audio.partialOther, partialOtherSpeaker: audio.partialOtherSpeaker, limit: nil
                    ),
                    entryCount: audio.transcriptEntries.count, isRecording: audio.isRecording,
                    error: audio.transcriptionError, fontSize: settings.fontSize,
                    useSourceBasedIdentification: voice.useSourceBasedIdentification,
                    onSpeakerTapped: { audio.markSpeakerAsMe($0) },
                    onOpenSettings: { audio.openSystemSettings() },
                    onRetry: { audio.retrySystemStream() }, onDismissError: { audio.clearError() },
                    onClose: onClose
                )
            case .screenshots:
                ScrollView { ScreenshotsDrawerSection().padding(DesignTokens.Spacing.md) }
            case .threads:
                QuickAssistHistorySidebar(searchFocusRequested: $historySearchFocusRequested)
            }
        }
        .background(OverlayPalette.readingSurface)
        .onChange(of: historySearchFocusRequested) { _, requested in
            if requested { tab = .threads }
        }
    }
}

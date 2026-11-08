import SwiftUI

/// The Design surface while an answer streams: a header with the streaming
/// dot, the context and recovery banners, the live response card, then the
/// structured sections as soon as any section parses. Mounted directly by
/// the shell, so this view owns the vertical scroll.
struct SystemDesignLiveGenerationView: View {
    @ObservedObject private var controller = SessionController.shared
    @ObservedObject private var settings = SettingsManager.shared
    @State private var didLogShown = false
    @State private var showsRawResponse = false

    private var partialContent: SystemDesignContent? {
        controller.parsedSystemDesignContent ?? controller.session.response?.parsedSystemDesign
    }

    private var structuredContent: SystemDesignContent? {
        guard let partialContent, partialContent.hasStructuredContent else { return nil }
        return partialContent
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SurfaceHeader("Designing", systemImage: "building.2", subtitle: "Sections fill in as the answer streams") {
                    StatusDot(state: .streaming)
                    Text(StatusDotState.streaming.label)
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textSecondary)
                }

                if let message = controller.systemDesignContextStatusMessage, !message.isEmpty {
                    ToneBanner(tone: .warning, message: message)
                }

                if let banner = DesignCompletenessPresenter.liveBanner(
                    report: controller.systemDesignCompletenessReport,
                    recoveryInProgress: controller.systemDesignRecoveryInProgress
                ) {
                    ToneBanner(tone: banner.tone, title: banner.title, message: banner.message, systemImage: banner.systemImage)
                }

                if structuredContent == nil {
                    DesignLiveStreamCard(text: controller.streamingResponseText, fontSize: settings.fontSize)
                } else {
                    DisclosureGroup("Live response text", isExpanded: $showsRawResponse) {
                        DesignLiveStreamCard(text: controller.streamingResponseText, fontSize: settings.fontSize)
                    }
                    .font(OverlayType.caption)
                }

                Hairline()

                SurfaceHeader(
                    "Structured sections",
                    systemImage: "square.stack.3d.up",
                    count: structuredContent.map { DesignSectionCatalog.availableSections(in: $0).count },
                    prominence: .heading
                )

                if let content = structuredContent {
                    if controller.systemDesignStableFallbackActive {
                        ToneBanner(
                            tone: .info,
                            message: "Showing the latest stable sections while new output streams.",
                            systemImage: "clock.arrow.circlepath"
                        )
                    }
                    SystemDesignSectionView(content: content, showsStatusBanners: false)
                } else {
                    waitingForSections
                }
            }
            .padding(OverlayLayout.stageInset)
            .frame(maxWidth: OverlayLayout.readingColumnMaximum + 2 * OverlayLayout.stageInset, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            guard !didLogShown else { return }
            didLogShown = true
            SessionLogger.shared.logSystemDesignEvent(
                name: "streaming_view_shown",
                details: "isLoading=\(controller.isLoading), isStreaming=\(controller.isStreaming)"
            )
        }
    }

    private var waitingForSections: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text("Waiting for the first structured section.")
                .font(OverlayType.body)
                .foregroundStyle(OverlayPalette.textSecondary)
            Spacer(minLength: 0)
        }
        .overlayCard(.base, padding: DesignTokens.Spacing.lg)
    }
}

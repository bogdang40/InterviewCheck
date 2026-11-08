import SwiftUI

/// A settled system design answer: the mode strip, the completeness state,
/// then the section list, the overview, or the talk through script. The
/// host owns the vertical scroll, so nothing in here scrolls on its own.
struct SystemDesignSectionView: View {
    let content: SystemDesignContent
    private let sections: [DesignSection]
    private let showsStatusBanners: Bool

    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var controller = SessionController.shared
    @State private var mode: DesignViewMode

    /// `showsStatusBanners` is false when a host such as the live view
    /// already reports completeness and recovery above this view.
    init(content: SystemDesignContent, initialMode: DesignViewMode = .sections, showsStatusBanners: Bool = true) {
        self.content = content
        self.sections = DesignSectionCatalog.availableSections(in: content)
        self.showsStatusBanners = showsStatusBanners
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        if !sections.isEmpty {
            structured
        } else if content.hasContent {
            ToneBanner(tone: .neutral, message: "Structured sections are unavailable. The original answer is preserved below.")
            SpeakableMarkdownView(
                text: content.rawContent,
                fontSize: settings.fontSize,
                showChunkIndicators: true,
                chunkTrackingMode: .teleprompter
            )
        } else {
            emptyNote
        }
    }

    private var structured: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            modeStrip

            if showsStatusBanners, let banner = DesignCompletenessPresenter.settledBanner(
                report: controller.systemDesignCompletenessReport,
                recoveryInProgress: controller.systemDesignRecoveryInProgress
            ) {
                ToneBanner(tone: banner.tone, title: banner.title, message: banner.message, systemImage: banner.systemImage)
            }

            switch mode {
            case .sections:
                DesignSectionListView(content: content, sections: sections)
            case .overview:
                DesignOverviewView(content: content, sections: sections) { index in
                    controller.systemDesignSectionIndex = index
                    mode = .sections
                }
            case .script:
                DesignScriptView(content: content, sections: sections)
            }
        }
    }

    private var modeStrip: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            SegmentStrip(items: DesignViewMode.segments, selection: $mode)
            Spacer(minLength: 0)
            CountPill(value: sections.count, label: sections.count == 1 ? "section" : "sections")
        }
    }

    private var emptyNote: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text("No system design content yet.")
                .font(OverlayType.body)
                .foregroundStyle(OverlayPalette.textSecondary)
            KeyHint(label: "Design", shortcut: ShortcutCatalog.solveSystemDesign)
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}

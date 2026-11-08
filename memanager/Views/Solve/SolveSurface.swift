import SwiftUI

/// The coding surface: a stage strip over the five sections and the
/// content for the selected one. Streams progressively: as soon as the
/// partial response has text the sections render, with a live marker.
struct SolveSurface: View {
    @ObservedObject private var controller = SessionController.shared
    @ObservedObject private var settings = SettingsManager.shared

    let width: CGFloat
    @State private var drawer: ContextDrawer.Tab?

    private var sectionItems: [SegmentItem<MentorResponse.Section>] {
        MentorSurfaceResolver.solveSections.map { section in
            SegmentItem(
                id: section,
                title: section.title,
                systemImage: section.icon,
                shortcut: ShortcutCatalog.jumpToSection(section)
            )
        }
    }

    private var selectedSection: MentorResponse.Section {
        controller.currentSection == .systemDesign ? .problem : controller.currentSection
    }

    var body: some View {
        VStack(spacing: 0) {
            SegmentStrip(
                items: sectionItems,
                selection: Binding(get: { selectedSection }, set: { controller.selectSection($0) }),
                iconsOnly: false,
                showsShortcuts: OverlayLayout.breakpoint(for: width) == .wide
            )
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.xs)

            Hairline()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if controller.session.response?.hasSolveContent == true {
                Hairline()
                actionShelf
            }
        }
        .sheet(item: $drawer) { tab in
            ContextDrawer(initialTab: tab, onClose: { drawer = nil })
                .frame(minWidth: 360, idealWidth: 620, minHeight: 420, idealHeight: 640)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let response = controller.session.response, response.hasSolveContent {
            SolveSectionContent(
                section: selectedSection,
                response: response,
                isStreaming: controller.isStreaming || controller.isLoading,
                width: width
            )
        } else if controller.isLoading {
            StageLoadingView(
                title: "Working through it",
                subtitle: "Restating the problem, planning the approach, then coding it step by step.",
                onCancel: { controller.cancelActiveRequest() }
            )
        } else {
            SolveEmptyState(
                state: controller.session.state,
                onStart: { controller.startSession() },
                onSolve: { Task { await controller.solve() } },
                onScreenshot: { ScreenshotService.shared.captureFullScreen() },
                onResume: { controller.togglePauseSession() },
                onEnd: { controller.endSession() }
            )
        }
    }

    private var actionShelf: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                contextActions
                Spacer(minLength: DesignTokens.Spacing.md)
                answerActions
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                answerActions
                HStack(spacing: DesignTokens.Spacing.sm) { contextActions }
            }
        }
        .buttonStyle(.overlay(.ghost, size: .small))
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OverlayPalette.surfaceRaised)
    }

    private var answerActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.sm) { navigationActions; generateAgain }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.sm) { navigationActions }
                generateAgain
            }
        }
    }

    @ViewBuilder private var generateAgain: some View {
        if !controller.isLoading && !controller.isStreaming {
            Button("Generate again", systemImage: "arrow.clockwise") {
                Task { await controller.solve() }
            }
            .buttonStyle(.overlay(.secondary))
            .accessibilityIdentifier("solve.generateAgain")
            .help("Generate a new solution using the current transcript, screenshots and previous answer.")
        }
    }

    @ViewBuilder private var navigationActions: some View {
        let stages = MentorSurfaceResolver.solveSections
        let index = stages.firstIndex(of: selectedSection) ?? 0
        Button("Previous", systemImage: "chevron.left") { controller.selectSection(stages[index - 1]) }
            .disabled(index == 0)
        if controller.isLoading || controller.isStreaming {
            Button("Cancel generation", action: controller.cancelActiveRequest)
                .buttonStyle(.overlay(.secondary))
        } else if index + 1 < stages.count {
            Button("Next: \(stages[index + 1].title)") { controller.selectSection(stages[index + 1]) }
                .buttonStyle(.overlayPrimary)
        }
    }

    @ViewBuilder private var contextActions: some View {
        Button("Sources", systemImage: "doc.text") { drawer = .context }
        Button("Transcript", systemImage: "text.alignleft") { drawer = .transcript }
        Button("Copy", systemImage: "doc.on.doc") {
            QuickAssistClipboard().copy(controller.session.response?.content(for: selectedSection) ?? "")
        }
    }
}

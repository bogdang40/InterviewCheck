import SwiftUI

/// Six phases, one selected section, and a contextual footer. Capture state
/// belongs to the shell and is independent of answer generation.
struct DesignSurface: View {
    @ObservedObject private var controller = SessionController.shared
    let width: CGFloat
    @State private var drawer: ContextDrawer.Tab?

    private var content: SystemDesignContent? {
        controller.parsedSystemDesignContent ?? controller.session.response?.parsedSystemDesign
    }
    private var sections: [DesignSection] {
        content.map(DesignSectionCatalog.availableSections(in:)) ?? []
    }
    private var phase: Int {
        guard sections.indices.contains(controller.systemDesignSectionIndex) else { return 0 }
        return DesignPhaseCatalog.phaseIndex(forSectionID: sections[controller.systemDesignSectionIndex].id) ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            SegmentStrip(
                items: DesignPhaseCatalog.phases.map { SegmentItem(id: $0.id, title: $0.title) },
                selection: Binding(get: { phase }, set: { id in
                    if let index = sections.firstIndex(where: { DesignPhaseCatalog.phaseIndex(forSectionID: $0.id) == id }) {
                        controller.systemDesignSectionIndex = index
                    }
                })
            )
            .padding(.horizontal, OverlayLayout.stageInset)
            .padding(.vertical, DesignTokens.Spacing.sm)
            Hairline()
            stage.frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline()
            footer
        }
        .sheet(item: $drawer) { tab in
            ContextDrawer(initialTab: tab, onClose: { drawer = nil })
                .frame(minWidth: 360, idealWidth: 620, minHeight: 420, idealHeight: 640)
        }
    }

    @ViewBuilder private var stage: some View {
        if controller.isLoading || controller.isStreaming {
            SystemDesignLiveGenerationView()
        } else if let content, content.hasContent {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    ScrollViewRegistrar(target: .main).frame(width: 0, height: 0)
                    if let message = controller.systemDesignContextStatusMessage {
                        ToneBanner(tone: .warning, message: message)
                    }
                    SystemDesignSectionView(content: content)
                }
                .padding(OverlayLayout.stageInset)
                .frame(maxWidth: OverlayLayout.readingWidth(for: width) + 2 * OverlayLayout.stageInset, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        } else {
            OverlayEmptyState(
                systemImage: "building.2", title: "Design a system",
                message: "Describe the system or capture its prompt. Clarify requirements, estimate the workload, then explain the design and its tradeoffs.",
                primary: EmptyStateAction(title: "Design", shortcut: ShortcutCatalog.solveSystemDesign) {
                    Task { await controller.solveSystemDesign() }
                },
                secondary: EmptyStateAction(title: "Capture screen", shortcut: ShortcutCatalog.screenshot) {
                    ScreenshotService.shared.captureFullScreen()
                }
            )
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DesignTokens.Spacing.sm) { contextActions; answerActions }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                answerActions
                HStack { contextActions }
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
        if !controller.isLoading && !controller.isStreaming && content?.hasContent == true {
            Button("Generate again", systemImage: "arrow.clockwise") {
                Task { await controller.solveSystemDesign() }
            }
            .buttonStyle(.overlay(.secondary))
            .accessibilityIdentifier("design.generateAgain")
            .help("Generate a new design using the current conversation, screen context and previous answer.")
        }
    }

    @ViewBuilder private var contextActions: some View {
        Button("Sources", systemImage: "doc.text") { drawer = .context }
        Button("Transcript", systemImage: "text.alignleft") { drawer = .transcript }
        Button("Copy", systemImage: "doc.on.doc") { QuickAssistClipboard().copy(content?.rawContent ?? "") }
            .disabled(content?.hasContent != true)
    }

    @ViewBuilder private var navigationActions: some View {
        Button("Previous section", systemImage: "chevron.left", action: controller.previousSystemDesignSection)
            .disabled(controller.systemDesignSectionIndex <= 0 || sections.isEmpty)
        if controller.isLoading || controller.isStreaming {
            Button("Cancel generation", action: controller.cancelActiveRequest).buttonStyle(.overlay(.secondary))
        } else {
            Button("Next section", systemImage: "chevron.right", action: controller.nextSystemDesignSection)
                .buttonStyle(.overlayPrimary)
                .disabled(controller.systemDesignSectionIndex + 1 >= sections.count)
        }
    }
}

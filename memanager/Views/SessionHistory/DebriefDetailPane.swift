import SwiftUI

/// The debrief: generate on demand, then the four sections read in under a
/// minute and the drills that feed Practice.
struct DebriefDetailPane: View {
    @ObservedObject private var controller = SessionController.shared
    let selectedSessionId: String?
    @State private var displayedDebrief: SessionDebrief?

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeader("Debrief", systemImage: "doc.text.magnifyingglass", subtitle: "What happened, strong moments, missed opportunities, next focus") {
                if controller.isGeneratingDebrief {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(displayedDebrief == nil ? "Generate" : "Regenerate", action: generate)
                    .buttonStyle(.overlay(.primary, size: .small))
                    .disabled(selectedSessionId == nil || controller.isGeneratingDebrief)
            }
            .padding(DesignTokens.Spacing.md)
            Hairline()
            if let error = controller.debriefError {
                ToneBanner(tone: .critical, title: "Debrief unavailable", message: error, actions: [BannerAction(title: "Retry", action: generate)])
                    .padding(DesignTokens.Spacing.md)
            }
            content
        }
        .onAppear(perform: loadSelectedDebrief)
        .onChange(of: selectedSessionId) { _, _ in loadSelectedDebrief() }
        .onChange(of: controller.currentSessionDebrief) { _, incoming in
            if incoming?.sessionId == selectedSessionId { displayedDebrief = incoming }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let debrief = displayedDebrief {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    ForEach(DebriefSectionCatalog.sections(for: debrief)) { section in
                        DebriefSectionCard(section: section)
                    }
                    DebriefDrillsSection(drills: debrief.drills) { drill in
                        controller.startPracticeFromDrill(drill)
                    }
                }
                .padding(DesignTokens.Spacing.md)
            }
        } else if controller.isGeneratingDebrief {
            StageLoadingView(title: "Writing the debrief", subtitle: "Reading the transcript, turns, and coach findings.")
        } else {
            OverlayEmptyState(
                systemImage: "doc.text.magnifyingglass",
                title: "No debrief yet",
                message: "Generate one after a session ends, or once there is enough transcript or Quick Assist evidence.",
                primary: selectedSessionId == nil ? nil : EmptyStateAction(title: "Generate", action: generate)
            )
        }
    }

    private func generate() {
        guard let selectedSessionId else { return }
        controller.generateSessionDebrief(sessionID: selectedSessionId)
    }

    private func loadSelectedDebrief() {
        displayedDebrief = selectedSessionId.flatMap { SessionLogger.shared.loadSessionDebrief(sessionId: $0) }
    }
}

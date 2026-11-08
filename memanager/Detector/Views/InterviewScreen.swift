import SwiftUI

/// The Live destination: setup, the interview itself, and its summary.
struct InterviewScreen: View {
    @ObservedObject var controller = InterviewController.shared
    @ObservedObject var timeline = InterviewTimeline.shared
    @ObservedObject var settings = DetectorSettings.shared
    @ObservedObject var workspaces = WorkspaceStore.shared
    @ObservedObject var roles = RoleStore.shared
    @ObservedObject var navigator = OverlayNavigator.shared
    let width: CGFloat

    private var planned: [PlannedQuestion] {
        workspaces.activeWorkspace.map { roles.profile(for: $0.id).plannedQuestions } ?? []
    }

    var body: some View {
        switch controller.phase {
        case .setup:
            InterviewSetupView(
                controller: controller, settings: settings, workspace: workspaces.activeWorkspace,
                readiness: .current(),
                onChooseRole: { navigator.show(.workspaces) },
                onOpenSettings: { navigator.showSettings(.aiProvider) }
            )
        case .live:
            InterviewLiveView(controller: controller, timeline: timeline, plannedQuestions: planned, width: width)
        case .ended:
            InterviewEndedView(controller: controller, onOpenReport: { navigator.show(.history) })
        }
    }
}

/// After "End": the overall line and what to do next.
struct InterviewEndedView: View {
    @ObservedObject var controller: InterviewController
    let onOpenReport: () -> Void

    var body: some View {
        let interview = controller.interview
        let scoring = controller.questions.contains { controller.scores[$0.id]?.isFinal != true && !$0.answerText.isEmpty }
        VStack(spacing: DesignTokens.Spacing.lg) {
            Text("Interview ended").font(OverlayType.display).foregroundStyle(OverlayPalette.textPrimary)
            if let percent = interview?.overallPercent {
                Text("\(percent)%")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(ScoreBand(percent: percent).tone.color)
                Text("\(ScoreBand(percent: percent).title) overall \u{00B7} \(interview?.flaggedCount ?? 0) of \(interview?.questionCount ?? 0) answers flagged")
                    .font(OverlayType.body).foregroundStyle(OverlayPalette.textSecondary)
            } else {
                Text("No answers were scored.").font(OverlayType.body).foregroundStyle(OverlayPalette.textSecondary)
            }
            if scoring { ProgressCaptionRow(text: "Finishing the last scores\u{2026}") }
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button("Open report", systemImage: "doc.text.magnifyingglass", action: onOpenReport)
                    .buttonStyle(.overlay(.primary))
                Button("New interview", systemImage: "plus") { controller.reset() }
                    .buttonStyle(.overlay(.secondary))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignTokens.Spacing.xl)
    }
}

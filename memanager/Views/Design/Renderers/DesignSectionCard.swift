import SwiftUI

/// One section's explanation and diagram, with supporting facts available
/// locally. The parent selects the section; this view never duplicates it.
struct DesignSectionCard: View {
    let section: DesignSection
    let number: Int
    let total: Int
    let content: SystemDesignContent
    let isExpanded: Bool
    let onSelect: () -> Void
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var controller = SessionController.shared
    @State private var showsReference = false

    private var steps: [ProgressiveDesignStep] { content.progressiveSteps(for: section.id) }
    private var status: SystemDesignSectionCompleteness? {
        controller.systemDesignCompletenessReport?.status(for: section.id)
    }
    private var progress: DesignStepProgress {
        DesignStepProgress(
            stepCount: steps.count, expectedStepCount: status?.expectedStepCount ?? section.expectedStepCount,
            currentIndex: controller.systemDesignStepIndex(for: section.id, stepCount: steps.count),
            isComplete: status?.isComplete
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text(section.title).font(OverlayType.title).foregroundStyle(OverlayPalette.textPrimary)
            if progress.hasSteps {
                DesignStepperView(
                    section: section, steps: steps, progress: progress, fontSize: settings.fontSize,
                    onPrevious: { controller.previousSystemDesignStep(in: section.id, stepCount: steps.count) },
                    onNext: { controller.nextSystemDesignStep(in: section.id, stepCount: steps.count) }
                )
                DisclosureGroup("Reference details", isExpanded: $showsReference) {
                    DesignSectionDetailView(section: section, content: content, fontSize: settings.fontSize)
                        .padding(.top, DesignTokens.Spacing.md)
                }
                .font(OverlayType.heading)
            } else {
                DesignSectionDetailView(section: section, content: content, fontSize: settings.fontSize)
            }
            if let status, let issue = DesignCompletenessPresenter.sectionIssue(status) {
                ToneBanner(tone: issue.tone, title: issue.title, message: issue.message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

import SwiftUI

/// One section of the talk through: the spoken script for the current step
/// as speakable chunks, then that step's diagram. The active card gets the
/// accent edge and reports its chunk count to the teleprompter.
struct DesignScriptCard: View {
    let section: DesignSection
    let number: Int
    let content: SystemDesignContent
    let isActive: Bool

    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var controller = SessionController.shared
    @State private var showsDiagram = false

    private var steps: [ProgressiveDesignStep] {
        content.progressiveSteps(for: section.id)
    }

    private var progress: DesignStepProgress {
        DesignStepProgress(
            stepCount: steps.count,
            expectedStepCount: nil,
            currentIndex: controller.systemDesignStepIndex(for: section.id, stepCount: steps.count)
        )
    }

    private var currentStep: ProgressiveDesignStep? {
        progress.hasSteps ? steps[progress.currentIndex] : nil
    }

    private var script: String {
        DesignScriptComposer.script(section: section, steps: steps, stepIndex: progress.currentIndex)
    }

    private var sectionColor: Color {
        DesignSectionToneResolver.color(for: section.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            header

            if !script.isEmpty {
                SpeakableChunksView(
                    text: script,
                    fontSize: settings.fontSize,
                    showChunkIndicators: true,
                    chunkTrackingMode: .teleprompter,
                    chunkCountReportingEnabled: isActive
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, DesignTokens.Spacing.md)
            }

            if let step = currentStep {
                DesignStepControls(
                    progress: progress,
                    onPrevious: { controller.previousSystemDesignStep(in: section.id, stepCount: steps.count) },
                    onNext: { controller.nextSystemDesignStep(in: section.id, stepCount: steps.count) }
                )
                DisclosureGroup("Diagram", isExpanded: $showsDiagram) { diagram(for: step) }
            }
        }
        .padding(.vertical, DesignTokens.Spacing.sm)
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            NumberBadge(number: number, color: sectionColor, isActive: isActive)
            Image(systemName: section.symbol)
                .font(OverlayType.callout)
                .foregroundStyle(sectionColor)
            Text(section.title)
                .font(OverlayType.heading)
                .foregroundStyle(OverlayPalette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: DesignTokens.Spacing.sm)

            if progress.hasSteps {
                Text(progress.positionLabel)
                    .font(OverlayType.monoMicro)
                    .foregroundStyle(OverlayPalette.textTertiary)
            }

            if isActive, controller.teleprompterModeEnabled {
                KeyHint(
                    label: "Chunk \(controller.currentChunkIndex + 1) of \(controller.totalChunkCount)",
                    shortcut: DesignShortcutHints.section
                )
            }
        }
    }

    private func diagram(for step: ProgressiveDesignStep) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: "rectangle.3.group")
                    .font(OverlayType.micro)
                Text("\(section.title) diagram, step \(step.number)")
                    .font(OverlayType.caption)
            }
            .foregroundStyle(OverlayPalette.textTertiary)

            AdaptiveMermaidDiagramView(
                diagram: step.mermaidDiagram,
                height: 300,
                renderPolicy: .systemDesignAdaptiveSerial(slotID: "script.\(section.id)")
            )
            .onAppear {
                SessionLogger.shared.logMermaidEvent(
                    name: "script_step_diagram_appear",
                    details: "section=\(section.id), step=\(step.number), diagramLen=\(step.mermaidDiagram.count)"
                )
            }
            .onDisappear {
                SessionLogger.shared.logMermaidEvent(
                    name: "script_step_diagram_disappear",
                    details: "section=\(section.id), step=\(step.number)"
                )
            }
        }
    }
}

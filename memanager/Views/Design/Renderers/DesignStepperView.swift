import SwiftUI

/// One progressive step at a time: title, narration, the progression
/// context, the decision and trade off, the diagram, and the step controls.
struct DesignStepperView: View {
    let section: DesignSection
    let steps: [ProgressiveDesignStep]
    let progress: DesignStepProgress
    let fontSize: CGFloat
    let onPrevious: () -> Void
    let onNext: () -> Void

    private var step: ProgressiveDesignStep {
        steps[progress.currentIndex]
    }

    private var previous: ProgressiveDesignStep? {
        progress.hasPrevious ? steps[progress.currentIndex - 1] : nil
    }

    private var slotID: String {
        "progressive.\(section.id)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                Text("Step \(step.number)")
                    .font(OverlayType.monoMicro)
                    .foregroundStyle(OverlayPalette.accent)
                Text(step.title)
                    .font(OverlayType.bodyStrong(fontSize))
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if DesignTextValidator.isMeaningful(step.reasoning) {
                SpeakableMarkdownView(
                    text: step.reasoning,
                    fontSize: fontSize,
                    showChunkIndicators: false,
                    chunkTrackingMode: .teleprompter
                )
            }

            DesignStepDetailRows(
                context: DesignStepContextResolver.context(for: step, previous: previous),
                decision: step.decision,
                tradeOff: DesignStepContextResolver.meaningfulTradeOff(step.tradeOff),
                fontSize: fontSize
            )

            AdaptiveMermaidDiagramView(
                diagram: step.mermaidDiagram,
                height: 330,
                renderPolicy: .systemDesignAdaptiveSerial(slotID: slotID)
            )
            .onAppear {
                SessionLogger.shared.logMermaidEvent(
                    name: "progressive_step_diagram_appear",
                    details: "section=\(section.id), step=\(step.number), diagramLen=\(step.mermaidDiagram.count)"
                )
            }
            .onDisappear {
                SessionLogger.shared.logMermaidEvent(
                    name: "progressive_step_diagram_disappear",
                    details: "section=\(section.id), step=\(step.number)"
                )
            }

            DesignStepControls(progress: progress, onPrevious: onPrevious, onNext: onNext)
        }
    }
}

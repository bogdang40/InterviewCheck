import SwiftUI

/// Only the selected step occupies the reading surface. All steps remain
/// directly reachable and keep their original number and cumulative code.
struct ImplementationStepList: View {
    let content: ImplementationContent
    let fontSize: CGFloat
    @ObservedObject private var controller = SessionController.shared

    private var selectedIndex: Int {
        content.steps.firstIndex { $0.number == controller.expandedImplementationStep } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            ImplementationStepNavigation(content: content)
            if content.steps.indices.contains(selectedIndex) {
                let step = content.steps[selectedIndex]
                Text(step.title)
                    .font(OverlayType.bodyStrong(fontSize + 2))
                    .foregroundStyle(OverlayPalette.textPrimary)
                ImplementationStepDetail(
                    step: step, fontSize: fontSize,
                    teleprompter: controller.teleprompterModeEnabled
                        ? TeleprompterProgress(current: controller.currentChunkIndex, total: controller.totalChunkCount) : nil
                )
                .id(step.number)
            }
        }
        .onAppear { controller.setImplementationStepCount(content.steps.count) }
        .onChange(of: content.steps.count) { _, count in controller.setImplementationStepCount(count) }
    }
}

/// Shared step navigation for code and spoken views, with usable controls
/// in addition to the existing keyboard shortcuts.
struct ImplementationStepNavigation: View {
    let content: ImplementationContent
    @ObservedObject private var controller = SessionController.shared

    private var index: Int {
        content.steps.firstIndex { $0.number == controller.expandedImplementationStep } ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            SegmentStrip(
                items: content.steps.map { SegmentItem(id: $0.number, title: "\($0.number). \($0.title)") },
                selection: $controller.expandedImplementationStep
            )
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    navigationActions
                    teleprompterButton
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    HStack(spacing: DesignTokens.Spacing.sm) { navigationActions }
                    teleprompterButton
                }
            }
            .buttonStyle(.overlay(.ghost, size: .small))
        }
    }

    @ViewBuilder private var navigationActions: some View {
        Button("Previous step", systemImage: "chevron.left") {
            controller.expandedImplementationStep = content.steps[index - 1].number
        }
        .disabled(index == 0 || content.steps.isEmpty)
        .help(ShortcutCatalog.previousStep)
        Button("Next step", systemImage: "chevron.right") {
            controller.expandedImplementationStep = content.steps[index + 1].number
        }
        .disabled(index + 1 >= content.steps.count)
        .help(ShortcutCatalog.nextStep)
    }

    private var teleprompterButton: some View {
        Button(controller.teleprompterModeEnabled ? "Teleprompter on" : "Teleprompter",
               systemImage: "text.cursor", action: controller.toggleTeleprompterMode)
            .buttonStyle(.overlay(controller.teleprompterModeEnabled ? .secondary : .ghost))
            .help(ShortcutCatalog.toggleTeleprompter)
    }
}

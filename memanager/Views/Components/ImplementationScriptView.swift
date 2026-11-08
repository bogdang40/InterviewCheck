import SwiftUI

/// The selected step's spoken answer. Code reading style and teleprompter
/// controls change presentation without regenerating the solution.
struct ImplementationScriptView: View {
    let content: ImplementationContent
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var controller = SessionController.shared
    @State private var speechStyle: SpokenCodeFormatter.Style = .mixed

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            ImplementationStepNavigation(content: content)
            SegmentStrip(items: [
                SegmentItem(id: SpokenCodeFormatter.Style.mixed, title: "Natural code reading"),
                SegmentItem(id: SpokenCodeFormatter.Style.literal, title: "Literal code reading")
            ], selection: $speechStyle)
            if let step = content.steps.first(where: { $0.number == controller.expandedImplementationStep }) ?? content.steps.first {
                ImplementationScriptCard(step: step, fontSize: settings.fontSize, style: speechStyle, isActive: true)
                    .id(step.number)
            }
        }
        .onAppear { controller.setImplementationStepCount(content.steps.count) }
    }
}

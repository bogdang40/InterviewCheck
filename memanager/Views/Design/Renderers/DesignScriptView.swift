import SwiftUI

/// Spoken mode shares section and step selection with the reference view.
struct DesignScriptView: View {
    let content: SystemDesignContent
    let sections: [DesignSection]
    @ObservedObject private var controller = SessionController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            DesignSectionNavigation(sections: sections)
            Button(controller.teleprompterModeEnabled ? "Teleprompter on" : "Teleprompter",
                   systemImage: "text.cursor", action: controller.toggleTeleprompterMode)
                .buttonStyle(.overlay(controller.teleprompterModeEnabled ? .secondary : .ghost))
                .help(DesignShortcutHints.teleprompter)
            if sections.indices.contains(controller.systemDesignSectionIndex) {
                let index = controller.systemDesignSectionIndex
                DesignScriptCard(section: sections[index], number: index + 1, content: content, isActive: true)
                    .id(sections[index].id)
            }
        }
        .onAppear { controller.setSystemDesignSectionCount(sections.count) }
        .onChange(of: sections.count) { _, count in controller.setSystemDesignSectionCount(count) }
    }
}

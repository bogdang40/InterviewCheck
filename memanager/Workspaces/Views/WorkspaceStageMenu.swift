import SwiftUI

/// Stage picker rendered as a tone badge; the menu lists every stage with
/// its symbol and marks the current one.
struct WorkspaceStageMenu: View {
    @Binding var status: JobWorkspaceStatus

    var body: some View {
        BadgeMenu(
            text: status.displayName,
            tone: WorkspaceStatusPresentation.tone(for: status),
            systemImage: status.systemImage,
            help: "Stage of this application"
        ) {
            ForEach(JobWorkspaceStatus.allCases) { stage in
                Button {
                    status = stage
                } label: {
                    Label(stage.displayName, systemImage: stage == status ? "checkmark" : stage.systemImage)
                }
            }
        }
    }
}

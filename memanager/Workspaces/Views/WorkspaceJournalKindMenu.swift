import SwiftUI

/// Journal kind picker rendered as a tone badge.
struct WorkspaceJournalKindMenu: View {
    @Binding var kind: WorkspaceJournalKind

    var body: some View {
        BadgeMenu(
            text: kind.displayName,
            tone: WorkspaceJournalKindPresentation.tone(for: kind),
            systemImage: kind.systemImage,
            help: "Kind of entry"
        ) {
            ForEach(WorkspaceJournalKind.allCases) { candidate in
                Button {
                    kind = candidate
                } label: {
                    Label(candidate.displayName, systemImage: candidate == kind ? "checkmark" : candidate.systemImage)
                }
            }
        }
    }
}

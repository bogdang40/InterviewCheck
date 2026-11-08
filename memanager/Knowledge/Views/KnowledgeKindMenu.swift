import SwiftUI

/// Kind picker for the fact editor, shown as a tone badge.
struct KnowledgeKindMenu: View {
    @Binding var kind: KnowledgeNodeKind

    var body: some View {
        BadgeMenu(
            text: kind.displayName,
            tone: KnowledgeNodePresentation.tone(for: kind),
            systemImage: kind.systemImage,
            help: "Kind of fact"
        ) {
            ForEach(KnowledgeNodeKind.allCases) { candidate in
                Button {
                    kind = candidate
                } label: {
                    Label(candidate.displayName, systemImage: candidate == kind ? "checkmark" : candidate.systemImage)
                }
            }
        }
    }
}

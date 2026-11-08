import SwiftUI

/// Kind filter for the fact list, shown as a badge that carries the
/// selected kind's tone so an active filter is visible at a glance.
struct KnowledgeKindFilterMenu: View {
    @Binding var selection: KnowledgeNodeKind?

    var body: some View {
        BadgeMenu(
            text: selection?.displayName ?? "All kinds",
            tone: selection.map(KnowledgeNodePresentation.tone) ?? .neutral,
            systemImage: selection?.systemImage ?? "line.3.horizontal.decrease",
            help: "Filter by kind"
        ) {
            Button {
                selection = nil
            } label: {
                Label("All kinds", systemImage: selection == nil ? "checkmark" : "line.3.horizontal.decrease")
            }
            Divider()
            ForEach(KnowledgeNodeKind.allCases) { kind in
                Button {
                    selection = kind
                } label: {
                    Label(kind.displayName, systemImage: kind == selection ? "checkmark" : kind.systemImage)
                }
            }
        }
    }
}

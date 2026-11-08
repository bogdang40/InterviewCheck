import SwiftUI

/// Composer for a new relation from the selected fact: pick the relation
/// and the target, note the evidence, link. Folded until it is wanted.
struct KnowledgeLinkForm: View {
    let targets: [KnowledgeNode]
    let onLink: (KnowledgeLinkRequest) throws -> Void

    @State private var isExpanded = false
    @State private var targetID: UUID?
    @State private var relation: KnowledgeRelation = .relatedTo
    @State private var evidence = ""
    @State private var errorMessage: String?

    private var target: KnowledgeNode? {
        targets.first { $0.id == targetID }
    }

    var body: some View {
        DisclosureCard("Link to another fact", systemImage: "link.badge.plus", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                    LabeledField("Relation") {
                        relationMenu
                    }
                    LabeledField("Target") {
                        targetMenu
                    }
                }
                LabeledField("Evidence", hint: "Optional. Targets come from the list; search there to narrow them.") {
                    OverlayTextInput(placeholder: "Where this relation shows up", text: $evidence)
                }
                HStack {
                    Spacer(minLength: 0)
                    Button("Link", action: link)
                        .buttonStyle(.overlay(.primary, size: .small))
                        .disabled(target == nil)
                }
                if let errorMessage {
                    ToneBanner(tone: .critical, title: "Relation was not saved", message: errorMessage)
                }
            }
        }
    }

    private var relationMenu: some View {
        BadgeMenu(text: relation.displayName, tone: .info, help: "Relation") {
            ForEach(KnowledgeRelation.allCases) { candidate in
                Button(candidate.displayName) { relation = candidate }
            }
        }
    }

    private var targetMenu: some View {
        MenuField(
            title: target?.label ?? "Choose a fact",
            systemImage: target?.kind.systemImage ?? "circle.dashed",
            isPlaceholder: target == nil
        ) {
            if targets.isEmpty {
                Text("No other facts yet")
            }
            ForEach(targets) { candidate in
                Button {
                    targetID = candidate.id
                } label: {
                    Label("\(candidate.label) (\(candidate.kind.displayName))", systemImage: candidate.kind.systemImage)
                }
            }
        }
    }

    private func link() {
        guard let target else { return }
        let trimmed = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try onLink(KnowledgeLinkRequest(targetID: target.id, relation: relation, evidence: trimmed.isEmpty ? nil : trimmed))
            evidence = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

import SwiftUI

/// The identity fields under the title: company and role side by side from
/// the regular breakpoint up, tags, then the two long form editors.
struct WorkspaceMetadataFields: View {
    @Binding var draft: JobWorkspace
    @Binding var tagsText: String
    let breakpoint: OverlayLayout.Breakpoint

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if breakpoint == .compact {
                company
                role
            } else {
                HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
                    company
                    role
                }
            }
            LabeledField("Tags") {
                OverlayTextInput(placeholder: "payments, go, distributed systems", text: $tagsText)
            }
            LabeledField("Role summary", hint: "What the job wants, in your words") {
                OverlayTextEditor(
                    placeholder: "Own the payments ledger, lead a team of four, ship in Go",
                    text: $draft.jobDescriptionSummaryText,
                    height: 72
                )
            }
            LabeledField("Notes") {
                OverlayTextEditor(
                    placeholder: "Anything worth remembering about this pursuit",
                    text: $draft.notes,
                    height: 60
                )
            }
        }
    }

    private var company: some View {
        LabeledField("Company") {
            OverlayTextInput(placeholder: "Company", text: $draft.company)
        }
    }

    private var role: some View {
        LabeledField("Role") {
            OverlayTextInput(placeholder: "Role", text: $draft.role)
        }
    }
}

private extension JobWorkspace {
    var jobDescriptionSummaryText: String {
        get { jobDescriptionSummary ?? "" }
        set { jobDescriptionSummary = newValue.isEmpty ? nil : newValue }
    }
}

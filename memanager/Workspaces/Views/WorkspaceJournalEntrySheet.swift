import SwiftUI

/// Manual journal entry form.
struct WorkspaceJournalEntrySheet: View {
    let onSave: (WorkspaceJournalKind, String, String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: WorkspaceJournalKind = .note
    @State private var title = ""
    @State private var entryBody = ""
    @State private var errorMessage: String?

    var body: some View {
        OverlaySheetFrame(
            title: "New journal entry",
            subtitle: "Rounds, decisions, and open questions you want the next Quick Assist turn to know about.",
            primaryTitle: "Save",
            isPrimaryEnabled: canSave,
            onPrimary: save,
            onCancel: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                LabeledField("Kind") {
                    WorkspaceJournalKindMenu(kind: $kind)
                }
                LabeledField("Title") {
                    OverlayTextInput(placeholder: "Second round with the payments team", text: $title)
                }
                LabeledField("Body") {
                    OverlayTextEditor(placeholder: "What happened, what was asked, what you want to remember", text: $entryBody, height: 140)
                }
                if let errorMessage {
                    ToneBanner(tone: .critical, title: "Entry was not saved", message: errorMessage)
                }
            }
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !entryBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard canSave else { return }
        do {
            try onSave(
                kind,
                title.trimmingCharacters(in: .whitespaces),
                entryBody.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

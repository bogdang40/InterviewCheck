import SwiftUI

/// Explicit text saving keeps active prompts stable while a replacement is drafted.
struct ModeEditorColumn: View {
    @ObservedObject var store: ModeStore
    let mode: Mode
    @ObservedObject private var editing = ModeEditingState.shared
    @State private var showsDiscardConfirmation = false
    @FocusState private var focusedField: Field?

    private enum Field { case title, prompt }
    private var draft: ModeEditorDraft { editing.draft(for: mode) }
    private var title: Binding<String> {
        Binding(get: { draft.title }, set: { value in editing.update(mode) { $0.title = value } })
    }
    private var prompt: Binding<String> {
        Binding(get: { draft.prompt }, set: { value in editing.update(mode) { $0.prompt = value } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                FieldLabel(text: "Title")
                TextField("Mode title", text: title)
                    .font(OverlayType.body)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .focused($focusedField, equals: .title)
                    .overlayField(isFocused: focusedField == .title)
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack {
                    FieldLabel(text: "Prompt")
                    Spacer(minLength: 0)
                    ToneBadge(text: draft.isDirty ? "Unsaved" : "Saved", tone: draft.isDirty ? .warning : .neutral)
                }
                TextEditor(text: prompt)
                    .font(OverlayType.body)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .prompt)
                    .frame(minHeight: 140, maxHeight: 260)
                    .overlayField(isFocused: focusedField == .prompt, horizontalPadding: 6, verticalPadding: 6)
                Text("Quick Assist uses the saved prompt while this mode is active. Drafts stay here when you change pages.")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Discard edits") { showsDiscardConfirmation = true }
                        .buttonStyle(.overlay(.ghost, size: .small))
                        .disabled(!draft.isDirty)
                    Spacer(minLength: 0)
                    Button("Save prompt") { editing.save(modeID: mode.id, store: store) }
                        .buttonStyle(.overlay(.primary, size: .small))
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!draft.isDirty)
                }
            }
            ModeAttachmentsSection(store: store, mode: mode)
            ModeProjectFolderSection(store: store, mode: mode)
        }
        .confirmationDialog("Discard edits to \(mode.title)?", isPresented: $showsDiscardConfirmation, titleVisibility: .visible) {
            Button("Discard edits", role: .destructive) { editing.discard(modeID: mode.id) }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("The saved title and prompt will remain in use.")
        }
    }
}

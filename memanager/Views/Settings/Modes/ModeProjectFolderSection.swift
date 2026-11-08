import SwiftUI
import UniformTypeIdentifiers

/// The optional read only project folder for a mode: enable it, pick the
/// folder, and tune the caps Quick Assist works under.
struct ModeProjectFolderSection: View {
    @ObservedObject var store: ModeStore
    let mode: Mode

    @State private var isFolderPickerPresented = false
    @State private var pickerError: String?
    @State private var showsLimits = false
    @State private var confirmsClear = false

    private var editor: ModeProjectFolderEditor {
        ModeProjectFolderEditor(store: store, mode: mode)
    }

    private var config: ProjectFolderConfig { editor.config }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { config.isEnabled }, set: { editor.setEnabled($0) })
    }

    var body: some View {
        SettingsSection(
            "Project folder",
            footer: config.isEnabled ? nil : ProjectFolderCapabilities.helpText,
            trailing: {
                if config.isEnabled {
                    ToneBadge(text: "\(ProjectFolderCapabilities.toolCount) read only tools", tone: .success)
                }
            }
        ) {
            SettingsToggleRow(
                title: "Read only folder access",
                helper: "Quick Assist can list, read, and search one folder during a turn. Nothing is written or executed.",
                isOn: enabledBinding
            )

            if config.isEnabled {
                SettingsRow(
                    title: ProjectFolderPresentation.folderTitle(for: config),
                    helper: ProjectFolderPresentation.folderHelper(for: config),
                    layout: .adaptive
                ) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Button("Choose folder") { isFolderPickerPresented = true }
                            .buttonStyle(.overlay(.secondary, size: .small))
                        if config.bookmarkData != nil {
                            Button("Clear") { confirmsClear = true }
                                .buttonStyle(.overlay(.ghost, size: .small))
                        }
                    }
                }

                DisclosureCard("Advanced folder limits", systemImage: "slider.horizontal.3", isExpanded: $showsLimits) {
                    ModeProjectFolderLimitRows(editor: editor)
                }
                .padding(DesignTokens.Spacing.sm)

                if let pickerError {
                    ToneBanner(tone: .critical, message: pickerError, onDismiss: { self.pickerError = nil })
                        .padding(DesignTokens.Spacing.sm)
                }
            }
        }
        .fileImporter(isPresented: $isFolderPickerPresented, allowedContentTypes: [.folder]) { result in
            handleFolderSelection(result)
        }
        .confirmationDialog("Clear access to \(config.rootName.isEmpty ? "this folder" : config.rootName)?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear folder access", role: .destructive) { editor.clearFolder() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Quick Assist will no longer read this folder through this mode. The folder and its files stay on your Mac.")
        }
    }

    private func handleFolderSelection(_ result: Result<URL, Error>) {
        do {
            try editor.select(folder: try result.get())
            pickerError = nil
        } catch {
            pickerError = error.localizedDescription
        }
    }
}

/// The three caps as stepper rows.
struct ModeProjectFolderLimitRows: View {
    let editor: ModeProjectFolderEditor

    private func binding<Value>(_ keyPath: WritableKeyPath<ProjectFolderConfig, Value>) -> Binding<Value> {
        Binding(get: { editor.config[keyPath: keyPath] }, set: { editor.commit(keyPath, $0) })
    }

    var body: some View {
        SettingsDividedStack {
            SettingsStepperRow(
                title: "Max file size",
                helper: "Larger files are skipped.",
                value: binding(\.maxFileSizeBytes),
                range: 100_000...10_000_000,
                step: 100_000,
                caption: ProjectFolderPresentation.fileSizeCaption
            )
            SettingsStepperRow(
                title: "Max search results",
                value: binding(\.maxSearchResults),
                range: 20...1000,
                step: 20
            ) { "\($0)" }
            SettingsStepperRow(
                title: "Max tool iterations per turn",
                helper: "Caps how many tool calls one answer may make.",
                value: binding(\.maxToolIterations),
                range: 1...25
            ) { "\($0)" }
        }
    }
}

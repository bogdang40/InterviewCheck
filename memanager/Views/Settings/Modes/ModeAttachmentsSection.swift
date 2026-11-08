import SwiftUI
import UniformTypeIdentifiers

/// Files attached to a mode, with an importer for new ones.
struct ModeAttachmentsSection: View {
    @ObservedObject var store: ModeStore
    let mode: Mode

    @State private var isImporterPresented = false
    @State private var importError: String?
    @State private var attachmentToRemove: ModeAttachment?

    var body: some View {
        SettingsSection("Attachments", trailing: {
            Button {
                isImporterPresented = true
            } label: {
                Label("Add file", systemImage: "plus")
            }
            .buttonStyle(.overlay(.secondary, size: .small))
        }) {
            if mode.attachments.isEmpty {
                SettingsRow(
                    title: "No attachments",
                    helper: "Add PDFs, images, text, or markdown. Their text is injected into Quick Assist while this mode is active."
                ) {
                    Image(systemName: "paperclip")
                        .font(OverlayType.callout)
                        .foregroundStyle(OverlayPalette.textTertiary)
                }
            } else {
                ForEach(mode.attachments) { attachment in
                    ModeAttachmentRow(attachment: attachment) {
                        attachmentToRemove = attachment
                    }
                }
            }
            if let importError {
                ToneBanner(tone: .critical, message: importError, onDismiss: { self.importError = nil })
                    .padding(DesignTokens.Spacing.sm)
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: Self.allowedTypes,
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result: result)
        }
        .confirmationDialog("Remove \(attachmentToRemove?.originalFilename ?? "attachment")?", isPresented: Binding(get: { attachmentToRemove != nil }, set: { if !$0 { attachmentToRemove = nil } }), titleVisibility: .visible) {
            Button("Remove attachment", role: .destructive) {
                if let attachment = attachmentToRemove { store.removeAttachment(attachmentID: attachment.id, modeID: mode.id) }
                attachmentToRemove = nil
            }
            Button("Cancel", role: .cancel) { attachmentToRemove = nil }
        } message: {
            Text("This removes the copy stored for this mode. The original file is kept.")
        }
    }

    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var failures: [String] = []
            for url in urls {
                let didStartAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccess { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let attachment = try ModeAttachmentImporter.shared.importFile(at: url, intoMode: mode.id)
                    store.addAttachment(attachment, toMode: mode.id)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            importError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private static var allowedTypes: [UTType] {
        var types: [UTType] = [.pdf, .png, .jpeg, .plainText]
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        types.append(UTType(exportedAs: "net.daringfireball.markdown"))
        return types
    }
}

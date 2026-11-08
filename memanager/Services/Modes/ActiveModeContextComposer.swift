import Foundation
import AppKit

/// Composes the active Mode into the shape Quick Assist already understands: a single
/// realtime prompt string (prompt + attachment extracted text) and a list of base64 JPEG
/// image strings (mode image attachments merged with live screenshots).
///
/// This keeps the provider layer untouched while still delivering the documents to the model.
enum ActiveModeContextComposer {
    struct Source {
        var id: UUID?
        var title: String
        var promptText: String
        var attachments: [ModeAttachment]
    }

    struct Composed {
        var realtimePromptText: String
        var additionalImages: [String]
        var sourceModeID: UUID?
        var sourceModeTitle: String?
        var attachmentManifestLines: [String]
    }

    /// Build the composed context from whatever Mode is active right now. Returns nil if no
    /// Mode is active or the active Mode is empty (prompt blank and no attachments).
    static func compose(
        fallbackRealtimePrompt: String = "",
        mode: Mode? = ModeStoreBridge.activeMode(),
        storage: ModeAttachmentStoring = FileSystemModeAttachmentStorage.shared
    ) -> Composed? {
        guard let mode else { return nil }
        return compose(
            fallbackRealtimePrompt: fallbackRealtimePrompt,
            source: Source(
                id: mode.id,
                title: mode.title,
                promptText: mode.prompt,
                attachments: mode.attachments
            ),
            attachmentFileResolver: { attachment in
                guard let directory = try? storage.attachmentsDirectory(for: mode.id) else { return nil }
                return directory.appendingPathComponent(attachment.storedFilename)
            }
        )
    }

    static func compose(
        fallbackRealtimePrompt: String = "",
        source: Source?,
        attachmentFileResolver: ((ModeAttachment) -> URL?)? = nil
    ) -> Composed? {
        guard let source else { return nil }
        let trimmedPrompt = source.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrompt.isEmpty && source.attachments.isEmpty {
            return nil
        }

        var sections: [String] = []
        if !trimmedPrompt.isEmpty {
            sections.append("Mode: \(source.title)")
            sections.append(trimmedPrompt)
        } else {
            sections.append("Mode: \(source.title)")
        }

        var manifest: [String] = []
        var additionalImages: [String] = []

        for attachment in source.attachments {
            manifest.append(manifestLine(for: attachment))
            switch attachment.kind {
            case .image:
                if let base64 = imageBase64(for: attachment, attachmentFileResolver: attachmentFileResolver) {
                    additionalImages.append(base64)
                }
            case .pdf, .text, .markdown:
                if let text = attachment.extractedText, !text.isEmpty {
                    sections.append(attachmentSection(for: attachment, body: text))
                }
            }
        }

        if !manifest.isEmpty {
            sections.append("Attachments:\n" + manifest.joined(separator: "\n"))
        }

        var composedPrompt = sections.joined(separator: "\n\n")
        let trimmedFallback = fallbackRealtimePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallback.isEmpty {
            composedPrompt.append("\n\n")
            composedPrompt.append(trimmedFallback)
        }

        return Composed(
            realtimePromptText: composedPrompt,
            additionalImages: additionalImages,
            sourceModeID: source.id,
            sourceModeTitle: source.title,
            attachmentManifestLines: manifest
        )
    }

    private static func manifestLine(for attachment: ModeAttachment) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(attachment.byteSize), countStyle: .file)
        var line = "- \(attachment.originalFilename) [\(attachment.kind.displayName), \(size)]"
        if attachment.extractedTextTruncated {
            line.append(" (truncated)")
        }
        if let pageCount = attachment.pageCount {
            line.append(" (\(pageCount) pages)")
        }
        return line
    }

    private static func attachmentSection(for attachment: ModeAttachment, body: String) -> String {
        var header = "File: \(attachment.originalFilename)"
        if attachment.extractedTextTruncated {
            header.append(" (truncated excerpt)")
        }
        return header + "\n" + body
    }

    private static func imageBase64(
        for attachment: ModeAttachment,
        attachmentFileResolver: ((ModeAttachment) -> URL?)?
    ) -> String? {
        guard let fileURL = attachmentFileResolver?(attachment) else { return nil }
        guard
            let image = NSImage(contentsOf: fileURL),
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return nil }
        return jpeg.base64EncodedString()
    }
}

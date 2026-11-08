import SwiftUI

/// One attached file: kind badge, name, size and page count, a truncation
/// warning when the extracted text was cut, and a remove button.
struct ModeAttachmentRow: View {
    let attachment: ModeAttachment
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
            ToneBadge(
                text: attachment.kind.displayName,
                tone: .neutral,
                systemImage: ModeAttachmentPresentation.systemImage(for: attachment.kind),
                style: .outline
            )

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(attachment.originalFilename)
                    .font(OverlayType.callout)
                    .foregroundStyle(OverlayPalette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(ModeAttachmentPresentation.detail(for: attachment))
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textTertiary)
                        .lineLimit(1)
                    if attachment.extractedTextTruncated {
                        ToneBadge(text: "Truncated", tone: .warning)
                    }
                }
            }

            Spacer(minLength: DesignTokens.Spacing.sm)

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.overlayIcon(size: 24, bordered: false))
            .help("Remove this attachment")
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}

/// Pure presentation rules for attachment rows.
enum ModeAttachmentPresentation {
    static func systemImage(for kind: ModeAttachmentKind) -> String {
        switch kind {
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .text: return "doc.plaintext"
        case .markdown: return "doc.text"
        }
    }

    static func detail(for attachment: ModeAttachment) -> String {
        var parts = [ByteCountFormatter.string(fromByteCount: Int64(attachment.byteSize), countStyle: .file)]
        if let pageCount = attachment.pageCount {
            parts.append(pageCount == 1 ? "1 page" : "\(pageCount) pages")
        }
        return parts.joined(separator: ", ")
    }
}

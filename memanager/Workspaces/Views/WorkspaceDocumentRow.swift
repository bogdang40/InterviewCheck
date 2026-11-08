import SwiftUI

/// One indexed file: kind symbol, name, whether its text made it into the
/// index, and its size.
struct WorkspaceDocumentRow: View {
    let document: WorkspaceDocument
    @State private var isExpanded = false

    private var state: WorkspaceDocumentIndexState {
        WorkspaceDocumentIndexState.resolve(document)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Button { isExpanded.toggle() } label: { row }
                .buttonStyle(.plain)
                .accessibilityLabel("\(document.fileName), \(state.label)")
            if isExpanded {
                Text(document.relativePath)
                    .font(OverlayType.mono)
                    .foregroundStyle(OverlayPalette.textSecondary)
                    .textSelection(.enabled)
                Text("Indexed \(document.indexedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(OverlayType.caption)
                    .foregroundStyle(OverlayPalette.textSecondary)
                if let text = document.extractedText, document.hasText {
                    Text(text)
                        .font(OverlayType.body)
                        .foregroundStyle(OverlayPalette.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if document.extractedTruncated {
                        ToneBanner(tone: .warning, message: "Only part of this file was indexed.")
                    }
                } else {
                    Text("No searchable text is stored for this file.")
                        .font(OverlayType.caption)
                        .foregroundStyle(OverlayPalette.textSecondary)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: WorkspaceDocumentPresentation.symbol(for: document.kind))
                .font(OverlayType.callout)
                .foregroundStyle(OverlayPalette.textSecondary)
                .frame(width: 16)
            Text(document.fileName)
                .font(OverlayType.callout)
                .foregroundStyle(OverlayPalette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DesignTokens.Spacing.sm)
            ToneBadge(text: state.label, tone: state.tone)
            Text(WorkspaceDocumentPresentation.size(document.byteSize))
                .font(OverlayType.mono)
                .foregroundStyle(OverlayPalette.textTertiary)
                .lineLimit(1)
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(OverlayType.micro)
                .foregroundStyle(OverlayPalette.textSecondary)
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }
}

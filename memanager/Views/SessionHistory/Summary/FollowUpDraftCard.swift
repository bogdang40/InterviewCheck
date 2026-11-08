import AppKit
import SwiftUI

/// The follow up message drafted from the session, in a selectable mono
/// block so it can be copied as is.
struct FollowUpDraftCard: View {
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                FieldLabel(text: "Follow up draft")
                Spacer(minLength: 0)
                Button(copied ? "Copied" : "Copy draft", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.overlay(.secondary, size: .small))
            }
            Text(text)
                .font(OverlayType.mono)
                .foregroundStyle(OverlayPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignTokens.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                        .fill(OverlayPalette.well)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                        .stroke(OverlayPalette.hairline, lineWidth: 1)
                )
        }
        .onChange(of: text) { _, _ in copied = false }
    }
}

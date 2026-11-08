import SwiftUI
import AppKit

/// Copies the code to the clipboard and confirms it in place for a moment.
struct CodeBlockCopyButton: View {
    let code: String

    @State private var didCopy = false
    @State private var resetTask: Task<Void, Never>?

    private static let confirmationSeconds: UInt64 = 1_500_000_000

    var body: some View {
        Button(action: copy) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(didCopy ? OverlayTone.success.color : OverlayPalette.textSecondary)
                Text(didCopy ? "Copied" : "Copy")
            }
        }
        .buttonStyle(.overlay(.ghost, size: .small))
        .help(didCopy ? "Copied to the clipboard" : "Copy the code")
        .accessibilityLabel(didCopy ? "Copied" : "Copy code")
        .animation(DesignTokens.Motion.focus, value: didCopy)
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)

        didCopy = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.confirmationSeconds)
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }
}

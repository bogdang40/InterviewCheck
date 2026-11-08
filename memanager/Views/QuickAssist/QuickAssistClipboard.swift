import AppKit

/// Copies plain text for the say first card. Injected so a view can be
/// tested without touching the system pasteboard.
protocol QuickAssistTextCopying {
    func copy(_ text: String)
}

struct QuickAssistClipboard: QuickAssistTextCopying {
    func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

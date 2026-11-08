import AppKit
import SwiftUI

/// Gives a SwiftUI view access to its NSWindow once it is attached, for the
/// few window settings SwiftUI does not expose on macOS 14 (such as level).
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { configure(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Keeps this view's window above other apps' windows (for the Live
    /// Companion beside a video call). The window keeps its title bar and
    /// close button and shows in screen sharing like any other window.
    func floatingWindow() -> some View {
        background(WindowAccessor { window in
            window.level = .floating
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        })
    }
}

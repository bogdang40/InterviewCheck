import AppKit
import SwiftUI
@testable import memanager

/// Local production shell fixture used only to inspect the native glass host.
@MainActor
enum GlassPrototypeArtifacts {
    static let contentSize = CGSize(width: 720, height: 700)
    static let margin: CGFloat = 32

    static func makeShell(appearance: OverlayAppearance) -> NSView {
        let size = contentSize
        let shell = GlassPrototypeShell(width: size.width)
            .frame(width: size.width, height: size.height)
            .background(OverlayPalette.canvas.opacity(0.82))
            .environment(\.colorScheme, appearance.colorScheme!)
        let hosting = NSHostingView(rootView: shell)
        hosting.appearance = appearance.nativeAppearance
        hosting.frame = CGRect(origin: .zero, size: size)
        return hosting
    }

}

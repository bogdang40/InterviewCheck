import Combine
import SwiftUI

/// Root of the stealth overlay. Shows the access gate until the account is
/// entitled, then the shell. Three native backgrounds share geometry with
/// the retained content and leave real desktop gaps between the islands.
struct MentorView: View {
    @ObservedObject var settings = SettingsManager.shared
    @ObservedObject var access = AccessController.shared
    @Environment(\.overlayContentIsVisible) private var ancestorIsVisible
    @State private var isWindowVisible = false

    var body: some View {
        GeometryReader { geometry in
            let panes = FloatingShellGeometry(size: geometry.size,
                borderWidth: CGFloat(settings.configuration(for: settings.borderShaderStyle)?.width ?? 0))
            ZStack(alignment: .topLeading) {
                if access.isAllowed {
                    FloatingGlassBackdrop(geometry: panes)
                        .allowsHitTesting(false)
                    OverlayShellView(width: geometry.size.width)
                } else {
                    AccessGateView(controller: access)
                        .pearlGlass(opacity: settings.overlayOpacity, radius: 26)
                        .padding(20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tint(OverlayPalette.accent)
            .preferredColorScheme(settings.overlayAppearance.colorScheme)
            .overlay(alignment: .topLeading) {
                if access.isAllowed {
                    SessionDiagnosticsOverlay(availableWidth: max(0, panes.content.width - 32))
                        .padding(16)
                        .frame(width: panes.content.width, height: panes.content.height, alignment: .topLeading)
                        .clipped()
                        .position(x: panes.content.midX, y: panes.content.midY)
                }
            }
            .modifier(AbleyWelcomePresentation(access: access,
                isVisible: ancestorIsVisible && isWindowVisible))
        }
        .environment(\.overlayContentIsVisible, ancestorIsVisible && isWindowVisible)
        .onReceive(SessionController.shared.$isOverlayWindowVisible.removeDuplicates()) { visible in
            // Subscribe only to visibility; observing the whole controller here
            // would invalidate the root for every streamed answer update.
            if isWindowVisible != visible { isWindowVisible = visible }
        }
    }
}

#if DEBUG && XCODE_RUNNING_FOR_PREVIEWS
#Preview {
    MentorView()
}
#endif

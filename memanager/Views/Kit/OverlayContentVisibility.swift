import SwiftUI

private struct OverlayContentVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Retained destinations can stop decorative work without losing their drafts.
    var overlayContentIsVisible: Bool {
        get { self[OverlayContentVisibilityKey.self] }
        set { self[OverlayContentVisibilityKey.self] = newValue }
    }
}

import SwiftUI

/// The retained Assist studio owns its actions while the shell owns their
/// native glass. This value keeps the shelf aligned with that shared geometry.
struct FloatingDockLayout: Equatable {
    let height: CGFloat
    let gap: CGFloat
}

private struct FloatingDockLayoutKey: EnvironmentKey {
    static let defaultValue: FloatingDockLayout? = nil
}

extension EnvironmentValues {
    var floatingDockLayout: FloatingDockLayout? {
        get { self[FloatingDockLayoutKey.self] }
        set { self[FloatingDockLayoutKey.self] = newValue }
    }
}

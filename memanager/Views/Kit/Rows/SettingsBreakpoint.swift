import SwiftUI

/// The overlay breakpoint the settings screen is being rendered at. Rows
/// read it to decide whether a control sits beside its label or under it,
/// so the whole pane adapts from one measurement taken at the screen root.
private struct SettingsBreakpointKey: EnvironmentKey {
    static let defaultValue: OverlayLayout.Breakpoint = .regular
}

extension EnvironmentValues {
    var settingsBreakpoint: OverlayLayout.Breakpoint {
        get { self[SettingsBreakpointKey.self] }
        set { self[SettingsBreakpointKey.self] = newValue }
    }
}

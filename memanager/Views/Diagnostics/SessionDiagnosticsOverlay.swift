import SwiftUI

/// Floating diagnostics panel, shown while the setting is on. The panel
/// itself is `DiagnosticsPanelView` so it can be rendered on its own.
struct SessionDiagnosticsOverlay: View {
    @ObservedObject private var settings = SettingsManager.shared
    var availableWidth: CGFloat = DiagnosticsPanelView.width

    var body: some View {
        if settings.showDiagnosticsOverlay {
            DiagnosticsPanelView(onClose: { settings.showDiagnosticsOverlay = false }, availableWidth: availableWidth)
        }
    }
}

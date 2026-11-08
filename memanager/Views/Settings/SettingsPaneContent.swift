import SwiftUI

/// Maps a pane to its view. Kept apart from the screen so the routing table
/// reads at a glance and the screen owns only layout and selection.
struct SettingsPaneContent: View {
    let pane: SettingsPane
    @Binding var providerDraft: AIProviderSettingsDraft

    var body: some View {
        switch pane {
        case .detector:
            DetectorSettingsView()
        case .aiProvider:
            AIProviderSettingsView(draft: $providerDraft)
        case .hotkeys:
            HotkeySettingsView()
        case .modes:
            ModesSettingsView()
        case .appearance:
            AppearanceSettingsView()
        case .voice:
            VoiceSignatureSettingsView()
        case .permissions:
            PermissionsSettingsView()
        case .account:
            AccountSettingsView()
        case .admin:
            AdminPanelView()
        case .about:
            AboutSettingsView()
        }
    }
}

import Foundation

/// One page of the Settings screen. Order here is display order in the rail.
enum SettingsPane: String, CaseIterable, Identifiable {
    case detector
    case aiProvider
    case hotkeys
    case modes
    case appearance
    case voice
    case permissions
    case account
    case admin
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .detector: return "Detector"
        case .aiProvider: return "Providers"
        case .hotkeys: return "Hotkeys"
        case .modes: return "Modes"
        case .appearance: return "Appearance"
        case .voice: return "Voice"
        case .permissions: return "Permissions"
        case .account: return "Account"
        case .admin: return "Admin"
        case .about: return "About"
        }
    }

    /// One line under the pane title saying what lives on the page.
    var caption: String {
        switch self {
        case .detector: return "Which AIs answer each question, the AI review, and the candidate notice"
        case .aiProvider: return "Keys, models, and connection checks"
        case .hotkeys: return "Every action and the key that triggers it"
        case .modes: return "Prompt presets, attachments, and project folders for Quick Assist"
        case .appearance: return "Overlay, text, audio, diagnostics, and the intelligent hub"
        case .voice: return "Speaker identification and your voice signature"
        case .permissions: return "System access \(AppBrand.name) needs to hear the interview"
        case .account: return "Sign in, entitlement, billing, and the owner license"
        case .admin: return "Accounts, grants, and roles on the access server"
        case .about: return "Version and quit"
        }
    }

    var systemImage: String {
        switch self {
        case .detector: return "checkmark.shield"
        case .aiProvider: return "brain"
        case .hotkeys: return "keyboard"
        case .modes: return "square.stack.3d.up.fill"
        case .appearance: return "paintbrush"
        case .voice: return "waveform.circle"
        case .permissions: return "hand.raised"
        case .account: return "person.crop.circle"
        case .admin: return "person.badge.key"
        case .about: return "info.circle"
        }
    }

    /// The admin page exists only for accounts whose server role is admin.
    static func available(isAdmin: Bool) -> [SettingsPane] {
        allCases.filter { $0 != .admin || isAdmin }
    }
}

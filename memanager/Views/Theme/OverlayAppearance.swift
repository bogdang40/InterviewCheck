import AppKit
import SwiftUI

/// Persisted separately from the macOS setting so explicit choices remain stable.
enum OverlayAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nativeAppearance: NSAppearance? {
        // High-contrast names are matching identifiers, not constructible
        // appearances. AppKit applies accessibility contrast to these bases.
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static func restored(from value: String?) -> OverlayAppearance {
        value.flatMap(Self.init(rawValue:)) ?? .system
    }
}

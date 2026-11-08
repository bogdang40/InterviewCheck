import SwiftUI

/// A status colour family for small badges and messages.
enum OverlayTone: Equatable, Hashable {
    case neutral, info, success, warning, critical

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

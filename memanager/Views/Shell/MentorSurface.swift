import Foundation

/// The four surfaces of the mentor screen. Each maps onto existing
/// SessionController flags; the resolver below derives the active one and
/// the selector translates a pick back into controller calls, so the
/// controller keeps its flag based model untouched.
enum MentorSurface: String, CaseIterable, Identifiable {
    case assist
    case solve
    case design
    case transcript

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assist: return "Assist"
        case .solve: return "Solve"
        case .design: return "Design"
        case .transcript: return "Transcript"
        }
    }

    var systemImage: String {
        switch self {
        case .assist: return "sparkle"
        case .solve: return "terminal"
        case .design: return "square.on.square"
        case .transcript: return "waveform"
        }
    }

    /// The key that reveals the surface.
    var shortcut: String {
        switch self {
        case .assist: return ShortcutCatalog.showQuickAssist
        case .solve: return ShortcutCatalog.jumpToSection(.problem)
        case .design: return ShortcutCatalog.jumpToSection(.systemDesign)
        case .transcript: return ShortcutCatalog.openTranscript
        }
    }
}

/// Pure mapping from controller flags to the visible surface.
struct MentorSurfaceResolver {
    let isQuickAssistVisible: Bool
    let isTranscriptVisible: Bool
    let currentSection: MentorResponse.Section

    var surface: MentorSurface {
        if isTranscriptVisible { return .transcript }
        if isQuickAssistVisible { return .assist }
        if currentSection == .systemDesign { return .design }
        return .solve
    }

    /// The Solve stage strip only lists the coding sections.
    static let solveSections: [MentorResponse.Section] = MentorResponse.Section.allCases.filter { $0 != .systemDesign }
}

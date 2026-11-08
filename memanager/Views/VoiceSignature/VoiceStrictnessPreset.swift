import Foundation

/// Named threshold pairs for voice recognition. `custom` is any pair that
/// does not match a preset within a hundredth.
enum VoiceStrictnessPreset: String, CaseIterable, Identifiable {
    case relaxed = "Relaxed"
    case balanced = "Balanced"
    case strict = "Strict"
    case custom = "Custom"

    var id: String { rawValue }

    var thresholds: (enter: Float, exit: Float)? {
        switch self {
        case .relaxed: return (0.75, 0.65)
        case .balanced: return (0.85, 0.75)
        case .strict: return (0.92, 0.85)
        case .custom: return nil
        }
    }

    static let tolerance: Float = 0.01

    static func from(enter: Float, exit: Float) -> VoiceStrictnessPreset {
        for preset in allCases {
            if let thresholds = preset.thresholds,
               abs(thresholds.enter - enter) < tolerance,
               abs(thresholds.exit - exit) < tolerance {
                return preset
            }
        }
        return .custom
    }

    /// Keeps the exit threshold at or below the enter threshold.
    static func clampedExit(_ exit: Float, enter: Float, gap: Float = 0.05) -> Float {
        exit > enter ? enter - gap : exit
    }
}

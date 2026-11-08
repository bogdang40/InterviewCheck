import SwiftUI

/// High-level cadence classification of the interview room.
///
/// `.measured` is the neutral default. The other cases represent deliberate
/// choices by `PacingDirector` after two consecutive readings agree (the
/// hysteresis rule), so transitions are not noisy against natural pauses.
enum PacingState: Equatable {
    case decisive(confidence: Double)
    case measured(confidence: Double)
    case expansive(confidence: Double)
    case stalled(confidence: Double)

    static let measuredBaseline = PacingState.measured(confidence: 0)

    var kind: Kind {
        switch self {
        case .decisive: return .decisive
        case .measured: return .measured
        case .expansive: return .expansive
        case .stalled: return .stalled
        }
    }

    var confidence: Double {
        switch self {
        case .decisive(let value), .measured(let value),
             .expansive(let value), .stalled(let value):
            return value
        }
    }

    enum Kind: String, CaseIterable {
        case decisive
        case measured
        case expansive
        case stalled

        var label: String {
            switch self {
            case .decisive: return "Decisive"
            case .measured: return "Measured"
            case .expansive: return "Expansive"
            case .stalled: return "Stalled"
            }
        }

        /// Bar color. Uses system palette only; no generic gradients.
        var indicatorColor: Color {
            switch self {
            case .decisive: return .red
            case .measured: return .yellow
            case .expansive: return .green
            case .stalled: return .gray
            }
        }

        var accessibilityDescription: String {
            switch self {
            case .decisive:
                return "The interviewer is moving fast. Keep answers short and decisive."
            case .measured:
                return "Normal cadence. Answer with balanced depth."
            case .expansive:
                return "The interviewer is engaged. You can go deeper."
            case .stalled:
                return "Silence detected. Take the lead."
            }
        }
    }
}

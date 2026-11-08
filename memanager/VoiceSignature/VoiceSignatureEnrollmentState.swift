import Foundation

/// State of the enrollment process.
enum EnrollmentState: Equatable {
    case idle
    case preparing
    case enrolling(progress: Float)
    case exporting
    case completed
    case failed(String)

    var isActive: Bool {
        switch self {
        case .preparing, .enrolling, .exporting:
            return true
        default:
            return false
        }
    }
}

/// User-facing feedback during enrollment.
struct EnrollmentFeedback: Equatable {
    let message: String
    let isActionRequired: Bool

    static let keepSpeaking = EnrollmentFeedback(
        message: "Keep speaking naturally...",
        isActionRequired: false
    )
    static let speakLouder = EnrollmentFeedback(
        message: "Speak louder - no voice detected",
        isActionRequired: true
    )
    static let reduceNoise = EnrollmentFeedback(
        message: "Too much background noise",
        isActionRequired: true
    )
    static let onlyYou = EnrollmentFeedback(
        message: "Only you should be speaking",
        isActionRequired: true
    )
    static let tooShort = EnrollmentFeedback(
        message: "Keep speaking - need more audio",
        isActionRequired: false
    )
    static let goodQuality = EnrollmentFeedback(
        message: "Good audio quality",
        isActionRequired: false
    )
}

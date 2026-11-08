import Foundation

/// One historical review attempt on a `PracticeCard`. `grade` follows SM-2's
/// 0-5 scale where 0-2 are "failures" (card resets) and 3-5 are "successes"
/// (interval advances).
struct PracticeReview: Identifiable, Equatable, Hashable {
    let id: String
    let cardID: String
    let reviewedAt: Date
    let grade: PracticeGrade
    let durationMs: Int
    let selfReportedConfidence: Int?
    let feedback: String?
    let attemptTranscript: String?

    init(
        id: String = UUID().uuidString,
        cardID: String,
        reviewedAt: Date = Date(),
        grade: PracticeGrade,
        durationMs: Int = 0,
        selfReportedConfidence: Int? = nil,
        feedback: String? = nil,
        attemptTranscript: String? = nil
    ) {
        self.id = id
        self.cardID = cardID
        self.reviewedAt = reviewedAt
        self.grade = grade
        self.durationMs = durationMs
        self.selfReportedConfidence = selfReportedConfidence
        self.feedback = feedback
        self.attemptTranscript = attemptTranscript
    }
}

/// SM-2 five-point scale. Names are taken from the original algorithm so tests
/// and logs match well-known literature.
enum PracticeGrade: Int, Codable, Equatable, Hashable, CaseIterable {
    case blackout = 0
    case incorrectHardRecall = 1
    case incorrectEasyRecall = 2
    case correctDifficult = 3
    case correctHesitation = 4
    case perfect = 5

    var isPassing: Bool {
        rawValue >= 3
    }

    var label: String {
        switch self {
        case .blackout: return "Blackout"
        case .incorrectHardRecall: return "Wrong, hard"
        case .incorrectEasyRecall: return "Wrong, easy"
        case .correctDifficult: return "Correct, hard"
        case .correctHesitation: return "Correct, hesitated"
        case .perfect: return "Perfect"
        }
    }
}

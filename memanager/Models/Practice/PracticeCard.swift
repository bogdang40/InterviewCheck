import Foundation

/// The atomic unit of the Deliberate Practice Studio: a single micro-exercise
/// targeted at a moment the candidate fumbled during a session. Cards accumulate
/// over time and are scheduled via SM-2 so the weakest skills compound upward.
struct PracticeCard: Identifiable, Equatable, Hashable {
    let id: String
    let createdAt: Date
    let sessionID: String
    let topicTag: String
    let prompt: String
    let idealReasoning: String
    let transcriptSnippet: String
    let candidateAttemptSummary: String
    let difficulty: PracticeDifficulty
    let sourceEvidence: PracticeEvidence
    var isArchived: Bool

    init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        sessionID: String,
        topicTag: String,
        prompt: String,
        idealReasoning: String,
        transcriptSnippet: String,
        candidateAttemptSummary: String,
        difficulty: PracticeDifficulty,
        sourceEvidence: PracticeEvidence,
        isArchived: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sessionID = sessionID
        self.topicTag = topicTag
        self.prompt = prompt
        self.idealReasoning = idealReasoning
        self.transcriptSnippet = transcriptSnippet
        self.candidateAttemptSummary = candidateAttemptSummary
        self.difficulty = difficulty
        self.sourceEvidence = sourceEvidence
        self.isArchived = isArchived
    }
}

enum PracticeDifficulty: String, Codable, Equatable, Hashable {
    case easy
    case medium
    case hard
}

/// Why this card exists. Lets the UI surface the triggering moment and lets
/// analytics group cards by root cause.
enum PracticeEvidence: Equatable, Hashable {
    case drill(drillID: String)
    case coachFinding(findingID: String)
    case pacingStall(timestamp: Date)
    case lowConfidenceTranscript(entryID: String)
    case manual
}

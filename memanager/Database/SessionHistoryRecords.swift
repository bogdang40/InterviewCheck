import Foundation

struct TranscriptEntryRecord {
    let sessionId: String
    let speaker: String
    let text: String
    let timestamp: Date
    var confidence: Double?
    let source: String  // "microphone", "system_audio"
    
    init(
        sessionId: String,
        speaker: String,
        text: String,
        timestamp: Date = Date(),
        confidence: Double? = nil,
        source: String = "microphone"
    ) {
        self.sessionId = sessionId
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
        self.confidence = confidence
        self.source = source
    }
}

// MARK: - Screenshot Record

struct ScreenshotRecord {
    let sessionId: String
    let capturedAt: Date
    var width: Int?
    var height: Int?
    var sizeBytes: Int?
    let source: String  // "manual", "auto"
    
    init(
        sessionId: String,
        capturedAt: Date = Date(),
        width: Int? = nil,
        height: Int? = nil,
        sizeBytes: Int? = nil,
        source: String = "manual"
    ) {
        self.sessionId = sessionId
        self.capturedAt = capturedAt
        self.width = width
        self.height = height
        self.sizeBytes = sizeBytes
        self.source = source
    }
}

struct SessionSnapshotRecord: Identifiable, Equatable {
    let id: String
    let sessionId: String
    let capturedAt: Date
    let width: Int
    let height: Int
    let sizeBytes: Int
    let source: String
    let contentHash: String
    let encryptedPayload: Data
}

enum SessionDrillKind: String, Codable, Equatable, CaseIterable {
    case clarification
    case tradeoff
    case recovery
    case depth
    case pacing

    var displayLabel: String {
        switch self {
        case .clarification:
            return "Clarification"
        case .tradeoff:
            return "Tradeoff"
        case .recovery:
            return "Recovery"
        case .depth:
            return "Depth"
        case .pacing:
            return "Pacing"
        }
    }
}

struct SessionDrill: Identifiable, Equatable {
    let id: String
    let sessionId: String
    let debriefId: String
    let kind: SessionDrillKind
    let title: String
    let prompt: String
    let transcriptSpan: String
    let relatedThreadId: String?
    let relatedTurnId: String?
    let createdAt: Date
}

struct SessionDebrief: Identifiable, Equatable {
    let id: String
    let sessionId: String
    let whatHappened: [String]
    let strongMoments: [String]
    let missedOpportunities: [String]
    let recommendedDrills: [String]
    let nextSessionFocus: [String]
    let createdAt: Date
    let updatedAt: Date
    let drills: [SessionDrill]
}

// MARK: - Debug Event Record

import Foundation

// MARK: - Session Record

struct SessionRecord {
    let id: String
    let startedAt: Date
    var endedAt: Date?
    let state: String
    var transcript: String?
    var transcriptWordCount: Int
    var screenshotCount: Int
    var hasResponse: Bool
    var provider: String?
    var model: String?
    
    init(
        id: String,
        startedAt: Date,
        endedAt: Date? = nil,
        state: String,
        transcript: String? = nil,
        transcriptWordCount: Int = 0,
        screenshotCount: Int = 0,
        hasResponse: Bool = false,
        provider: String? = nil,
        model: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
        self.transcript = transcript
        self.transcriptWordCount = transcriptWordCount
        self.screenshotCount = screenshotCount
        self.hasResponse = hasResponse
        self.provider = provider
        self.model = model
    }
    
    /// Create from the app's Session model
    static func from(session: Session, provider: String?, model: String?) -> SessionRecord {
        let wordCount = session.transcript.split(whereSeparator: { $0.isWhitespace }).count
        return SessionRecord(
            id: session.id.uuidString,
            startedAt: session.startedAt ?? Date(),
            endedAt: nil,
            state: session.state.description,
            transcript: session.transcript,
            transcriptWordCount: wordCount,
            screenshotCount: session.screenshots.count,
            hasResponse: session.response != nil,
            provider: provider,
            model: model
        )
    }
}

extension Session.SessionState: CustomStringConvertible {
    var description: String {
        switch self {
        case .idle: return "idle"
        case .listening: return "listening"
        case .paused: return "paused"
        }
    }
}

// MARK: - API Call Record

struct APICallRecord {
    let sessionId: String
    let callType: String  // "solve", "quick_assist", "system_design"
    let provider: String
    let model: String
    let startedAt: Date
    var completedAt: Date?
    var durationMs: Int?
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var status: String  // "pending", "success", "error", "cancelled"
    var errorMessage: String?
    var requestSizeBytes: Int?
    var responseSizeBytes: Int?
    let isStreaming: Bool
    var endpoint: String?
    // Full payload storage
    var systemPrompt: String?
    var requestPayload: String?
    var responsePayload: String?
    
    init(
        sessionId: String,
        callType: String,
        provider: String,
        model: String,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        durationMs: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil,
        status: String = "pending",
        errorMessage: String? = nil,
        requestSizeBytes: Int? = nil,
        responseSizeBytes: Int? = nil,
        isStreaming: Bool = false,
        endpoint: String? = nil,
        systemPrompt: String? = nil,
        requestPayload: String? = nil,
        responsePayload: String? = nil
    ) {
        self.sessionId = sessionId
        self.callType = callType
        self.provider = provider
        self.model = model
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMs = durationMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.status = status
        self.errorMessage = errorMessage
        self.requestSizeBytes = requestSizeBytes
        self.responseSizeBytes = responseSizeBytes
        self.isStreaming = isStreaming
        self.endpoint = endpoint
        self.systemPrompt = systemPrompt
        self.requestPayload = requestPayload
        self.responsePayload = responsePayload
    }
    
    func withCompletion(
        completedAt: Date = Date(),
        status: String,
        errorMessage: String? = nil,
        responseSizeBytes: Int? = nil,
        responsePayload: String? = nil
    ) -> APICallRecord {
        var copy = self
        copy.completedAt = completedAt
        copy.durationMs = Int((completedAt.timeIntervalSince(startedAt)) * 1000)
        copy.status = status
        copy.errorMessage = errorMessage
        copy.responseSizeBytes = responseSizeBytes
        copy.responsePayload = responsePayload
        return copy
    }
}

// MARK: - Quick Assist Call Record

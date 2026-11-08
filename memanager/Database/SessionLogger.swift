import Foundation

/// High-level service for logging session activity to the database
/// Use this class to log all session events, API calls, etc.
final class SessionLogger {
    static let shared = SessionLogger()

    let database: SessionDatabase
    let debugSamplingPolicy = DebugEventSamplingPolicy()
    let state = SessionLoggerState()

    /// Injectable database seam for tests. Production keeps using `shared`,
    /// which binds to `SessionDatabase.shared` exactly as before.
    init(database: SessionDatabase = .shared) {
        self.database = database
    }


    
    // MARK: - Session Lifecycle
    
    /// Call when a new session starts
    func logSessionStarted(session: Session, provider: String, model: String) {
        state.resumedRecord = nil
        state.sessionId = session.id.uuidString
        state.provider = provider
        state.model = model
        
        let record = SessionRecord.from(session: session, provider: provider, model: model)
        database.insertSession(record)
        
        NSLog("[SessionLogger] Session started: \(session.id.uuidString)")
    }
    
    /// Call when session state changes
    func isLoggingSession(_ sessionID: UUID) -> Bool {
        state.sessionId == sessionID.uuidString
    }

    func logSessionUpdated(session: Session) {
        guard state.sessionId == session.id.uuidString else { return }
        
        var record = SessionRecord.from(session: session, provider: state.provider, model: state.model)
        if let original = state.resumedRecord, original.id == record.id {
            // Resume does not reconstruct images or Solve/Design response objects.
            // Their absence in memory must not erase recorded historical evidence.
            record.screenshotCount = max(record.screenshotCount, original.screenshotCount)
            record.hasResponse = record.hasResponse || original.hasResponse
        }
        database.insertSession(record)
    }

    /// Attach future updates to an existing session without reopening its dates.
    func logSessionResumed(sessionId: UUID) {
        guard let record = database.getSessionRecord(id: sessionId.uuidString) else { return }
        state.update(sessionId: record.id, provider: record.provider, model: record.model)
        state.resumedRecord = record
    }
    
    /// Call when a session ends
    func logSessionEnded(sessionId: UUID) {
        database.updateSessionEnded(sessionId: sessionId.uuidString, endedAt: Date())
        NSLog("[SessionLogger] Session ended: \(sessionId.uuidString)")
        
        if state.sessionId == sessionId.uuidString {
            state.sessionId = nil
        }
    }
    
    // MARK: - API Call Logging
    
    /// Create an API call tracker for the solve operation
    func startSolveCall(
        sessionId: String,
        provider: String,
        model: String,
        isStreaming: Bool = true,
        systemPrompt: String? = nil,
        requestPayload: String? = nil
    ) -> APICallTracker {
        let record = APICallRecord(
            sessionId: sessionId,
            callType: "solve",
            provider: provider,
            model: model,
            isStreaming: isStreaming,
            endpoint: getEndpoint(for: provider),
            systemPrompt: systemPrompt,
            requestPayload: requestPayload
        )
        return APICallTracker(record: record, database: database)
    }
    
    /// Create an API call tracker for system design
    func startSystemDesignCall(
        sessionId: String,
        provider: String,
        model: String,
        isStreaming: Bool = false,
        systemPrompt: String? = nil,
        requestPayload: String? = nil
    ) -> APICallTracker {
        let record = APICallRecord(
            sessionId: sessionId,
            callType: "system_design",
            provider: provider,
            model: model,
            isStreaming: isStreaming,
            endpoint: getEndpoint(for: provider),
            systemPrompt: systemPrompt,
            requestPayload: requestPayload
        )
        return APICallTracker(record: record, database: database)
    }
    
    /// Create an API call tracker for quick assist with full context
    func startQuickAssistCall(
        sessionId: String,
        threadId: String,
        turnId: String,
        provider: String,
        model: String,
        isFollowUp: Bool,
        transcriptText: String,
        question: String,
        extraContext: String,
        hasScreenshot: Bool,
        previousResponse: String?,
        contextMode: QuickAssistContextMode,
        modelTier: QuickAssistModelTier,
        questionSource: QuickAssistQuestionSource,
        routeConfidence: Double? = nil,
        verificationStatus: QuickAssistVerificationStatus = .pending,
        policyVersion: String? = nil,
        routeOverride: QuickAssistIntent? = nil,
        evidencePackManifest: String? = nil,
        requestPayload: String? = nil,
        experimentGroupId: String? = nil,
        candidateLabel: String? = nil,
        baseTurnId: String? = nil,
        candidateRole: QuickAssistCandidateRole? = nil
    ) -> QuickAssistCallTracker {
        let record = QuickAssistCallRecord(
            sessionId: sessionId,
            threadId: threadId,
            turnId: turnId,
            provider: provider,
            model: model,
            isFollowUp: isFollowUp,
            transcriptLength: transcriptText.count,
            hasScreenshot: hasScreenshot,
            hasPreviousResponse: previousResponse != nil,
            transcriptText: transcriptText,
            question: question,
            extraContext: extraContext,
            requestPayload: requestPayload,
            previousResponse: previousResponse,
            contextMode: contextMode,
            modelTier: modelTier,
            questionSource: questionSource,
            routeConfidence: routeConfidence,
            verificationStatus: verificationStatus,
            verificationConfidence: nil,
            unsupportedClaimCount: nil,
            verificationMissingQuestions: [],
            verificationSuggestedFollowUp: nil,
            policyVersion: policyVersion,
            routeOverride: routeOverride?.rawValue,
            evidencePackManifest: evidencePackManifest,
            experimentGroupId: experimentGroupId,
            candidateLabel: candidateLabel,
            baseTurnId: baseTurnId,
            candidateRole: candidateRole
        )
        return QuickAssistCallTracker(record: record, database: database)
    }
    
    // MARK: - Transcript Logging
    
    /// Log a transcript entry
    func logTranscriptEntry(
        sessionId: String,
        speaker: String,
        text: String,
        confidence: Double? = nil,
        source: String = "microphone"
    ) {
        let record = TranscriptEntryRecord(
            sessionId: sessionId,
            speaker: speaker,
            text: text,
            confidence: confidence,
            source: source
        )
        database.insertTranscriptEntry(record)
    }
    
    // MARK: - Screenshot Logging
    
    /// Log a screenshot capture
    func logScreenshot(
        sessionId: String,
        width: Int? = nil,
        height: Int? = nil,
        sizeBytes: Int? = nil,
        source: String = "manual"
    ) {
        let record = ScreenshotRecord(
            sessionId: sessionId,
            width: width,
            height: height,
            sizeBytes: sizeBytes,
            source: source
        )
        database.insertScreenshot(record)
    }
    
    // MARK: - Helpers
    
    private func getEndpoint(for provider: String) -> String {
        switch provider.lowercased() {
        case "claude": return "api.anthropic.com"
        case "openai": return "api.openai.com"
        case "azure openai", "azureopenai": return "azure"
        default: return "unknown"
        }
    }

}

import Foundation

/// Sources are copied from the displayed saved turn, never from current capture
/// or workspace services. Reject a stale record before exposing its contents.
enum QuickAssistSourcePresentation: Equatable {
    case saved(QuickAssistSourceSnapshot)
    case unavailable(UnavailableReason)

    enum UnavailableReason: Equatable {
        case noSelection, generating, interrupted, missingRecord

        var message: String {
            switch self {
            case .noSelection:
                return "Select a saved answer to inspect its recorded sources."
            case .generating:
                return "This answer is still being generated. Its saved sources are not available yet."
            case .interrupted:
                return "This partial answer has no saved source view. Select a saved turn to inspect its recorded sources."
            case .missingRecord:
                return "The saved source record for this answer is unavailable. Current capture and workspace context cannot identify its original sources."
            }
        }
    }

    init(turnID: UUID?, threadID: String?, record: QuickAssistCallRecord?,
         isStreaming: Bool, isInterrupted: Bool) {
        if isStreaming { self = .unavailable(.generating); return }
        if isInterrupted { self = .unavailable(.interrupted); return }
        guard let turnID else { self = .unavailable(.noSelection); return }
        guard let record, UUID(uuidString: record.turnId) == turnID,
              threadID == nil || record.threadId == threadID else {
            self = .unavailable(.missingRecord)
            return
        }
        self = .saved(QuickAssistSourceSnapshot(record: record))
    }
}

struct QuickAssistSourceSnapshot: Equatable {
    let turnID: String
    let threadID: String
    let sessionID: String
    let requestedAt: Date
    let question: String?
    let questionSource: QuickAssistQuestionSource
    let transcript: String?
    let extraContext: String?
    let previousResponse: String?
    let hasPreviousResponse: Bool
    let evidenceManifest: String?
    let hasScreenshot: Bool

    init(record: QuickAssistCallRecord) {
        turnID = record.turnId
        threadID = record.threadId
        sessionID = record.sessionId
        requestedAt = record.startedAt
        question = record.question
        questionSource = record.questionSource
        transcript = record.transcriptText
        extraContext = record.extraContext
        previousResponse = record.previousResponse
        hasPreviousResponse = record.hasPreviousResponse
        evidenceManifest = record.evidencePackManifest
        hasScreenshot = record.hasScreenshot
    }
}

extension QuickAssistStudioState {
    var sourceTurnID: UUID? {
        if !(selectedResponse?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return selectedTurnID
        }
        if !(lastStableResponse?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            return lastStableTurnID
        }
        return nil
    }

    var savedSources: QuickAssistSourcePresentation {
        QuickAssistSourcePresentation(
            turnID: sourceTurnID, threadID: activeThreadID, record: sourceRecord,
            isStreaming: shouldRenderStreamingDraft || (isLoading && responseForDisplay == nil),
            isInterrupted: !(interruptedResponse?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        )
    }
}

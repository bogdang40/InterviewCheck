import Foundation

extension SessionController {
    @MainActor
    func acceptsSolveUpdate(sessionID: UUID, requestID: UUID) -> Bool {
        session.id == sessionID && activeSolveRequestID == requestID && isLoading
    }

    @MainActor
    @discardableResult
    func applySolveStreamChunk(_ chunk: String, sessionID: UUID, requestID: UUID) -> Bool {
        guard acceptsSolveUpdate(sessionID: sessionID, requestID: requestID), isStreaming else { return false }
        let feed = canvasParser.feed(chunk)
        if !feed.commands.isEmpty {
            canvasDirector.apply(feed.commands)
        }
        streamingResponseText += feed.prose
        updateSessionResponse(MentorResponse.parse(from: streamingResponseText))
        return true
    }

    @MainActor
    @discardableResult
    func applySystemDesignStreamText(_ text: String, sessionID: UUID, requestID: UUID) -> Bool {
        guard acceptsSolveUpdate(sessionID: sessionID, requestID: requestID), isStreaming else { return false }
        streamingResponseText = text
        return true
    }
}

import Foundation

protocol AIProvider {
    var name: String { get }
    func complete(context: SessionContext) async throws -> MentorResponse
    func quickAssist(context: QuickAssistContext) async throws -> String

    /// Streaming version of quickAssist - calls onChunk with each text delta
    func quickAssistStreaming(
        context: QuickAssistContext,
        onChunk: @escaping (String) -> Void
    ) async throws

    /// Streaming version of complete - calls onChunk with each text delta for progressive display
    func completeStreaming(
        context: SessionContext,
        onChunk: @escaping (String) -> Void
    ) async throws -> MentorResponse
    
    /// Complete a system design question with architecture diagrams
    func completeSystemDesign(context: SessionContext) async throws -> MentorResponse
    
    /// Streaming version of completeSystemDesign - calls onChunk with each text delta
    func completeSystemDesignStreaming(
        context: SessionContext,
        onChunk: @escaping (String) -> Void
    ) async throws -> MentorResponse
    
    /// ML Guide streaming - EDA and modeling copilot for data science interviews
    func mlGuideStreaming(
        context: MLGuideContext,
        onChunk: @escaping (String) -> Void
    ) async throws

    /// Non-streaming post-session debrief generation
    func debrief(context: DebriefContext) async throws -> String
}

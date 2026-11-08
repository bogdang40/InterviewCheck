import Foundation

final class QuickAssistThread {
    struct Turn: Identifiable {
        let id: UUID
        let timestamp: Date
        let transcriptDelta: String
        let question: String
        let provider: AIProviderType
        let rawResponse: String
        let guardedResponse: String
        let response: String
        let contextMode: QuickAssistContextMode
        let modelTier: QuickAssistModelTier
        let questionSource: QuickAssistQuestionSource

        init(
            id: UUID,
            timestamp: Date,
            transcriptDelta: String,
            question: String,
            response: String,
            provider: AIProviderType = .claude,
            rawResponse: String? = nil,
            guardedResponse: String? = nil,
            contextMode: QuickAssistContextMode,
            modelTier: QuickAssistModelTier,
            questionSource: QuickAssistQuestionSource = .none
        ) {
            self.id = id
            self.timestamp = timestamp
            self.transcriptDelta = transcriptDelta
            self.question = question
            self.provider = provider
            self.rawResponse = rawResponse ?? response
            self.guardedResponse = guardedResponse ?? response
            self.response = response
            self.contextMode = contextMode
            self.modelTier = modelTier
            self.questionSource = questionSource
        }
    }

    private(set) var turns: [Turn] = []

    func appendTurn(_ turn: Turn) {
        turns.append(turn)
    }

    func replaceTurns(_ newTurns: [Turn]) {
        turns = newTurns
    }

    func reset() {
        turns.removeAll()
    }

    func resetContinuationContext() {
        // Keep turns for history but allow fresh generation
    }

    /// Build conversation history as user/assistant pairs for the AI prompt.
    /// Returns at most the last N turns.
    func buildConversationHistory(maxTurns limit: Int = 3) -> [(role: String, content: String)] {
        let recentTurns = turns.suffix(limit)
        var history: [(role: String, content: String)] = []

        for turn in recentTurns {
            var userContent = ""
            if !turn.transcriptDelta.isEmpty {
                userContent += "Transcript: \(turn.transcriptDelta)\n"
            }
            if !turn.question.isEmpty {
                userContent += "Question: \(turn.question)"
            }
            if !userContent.isEmpty {
                history.append((role: "user", content: userContent.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            if !turn.response.isEmpty {
                history.append((role: "assistant", content: turn.response))
            }
        }

        return history
    }

    var lastResponse: String? {
        turns.last?.response
    }

    var lastModelTier: QuickAssistModelTier? {
        turns.last?.modelTier
    }

    var turnCount: Int {
        turns.count
    }
}

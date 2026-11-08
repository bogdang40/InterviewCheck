import Foundation

extension SettingsManager {
    static let quickAssistPromptsKey = "memanager.quickAssistPrompts"
    static let quickAssistActivePromptKey = "memanager.quickAssistActivePromptID"
    static let mlGuidePromptsKey = "memanager.mlGuidePrompts"
    static let mlGuideActivePromptKey = "memanager.mlGuideActivePromptID"
    private static let quickAssistPromptMinSharedTerms = 2
    private static let quickAssistPromptStopWords: Set<String> = [
        "about", "above", "after", "again", "against", "answer", "approach", "asked",
        "being", "below", "brief", "candidate", "clarify", "continue", "detail",
        "design", "draw", "explain", "first", "focus", "given", "going", "have",
        "here", "interview", "interviewer", "just", "keep", "like", "next", "only",
        "problem", "question", "quick", "right", "screenshot", "should", "show",
        "solve", "system", "talk", "that", "them", "there", "think", "this", "through",
        "today", "transcript", "using", "what", "when", "where", "which", "with",
        "would", "your"
    ]
    func activeQuickAssistPromptText() -> String {
        // Prefer the new Mode store when it has an active mode with content. Falls back to the
        // legacy QuickAssistPrompt path otherwise so older code continues to work.
        if let activeModePrompt = ModeStoreBridge.activePromptTextIfAvailable(),
           !activeModePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return activeModePrompt
        }
        guard let activeID = activeQuickAssistPromptID,
              let prompt = quickAssistPrompts.first(where: { $0.id == activeID }) else {
            return ""
        }
        return prompt.prompt
    }

    func resolveQuickAssistPrompt(
        transcript: String,
        question: String,
        extraContext: String
    ) -> ResolvedQuickAssistPrompt {
        Self.resolveQuickAssistPromptText(
            activeQuickAssistPromptText(),
            transcript: transcript,
            question: question,
            extraContext: extraContext
        )
    }

    static func resolveQuickAssistPromptText(
        _ promptText: String,
        transcript: String,
        question: String,
        extraContext: String
    ) -> ResolvedQuickAssistPrompt {
        let trimmedPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            return ResolvedQuickAssistPrompt(
                text: "",
                status: .empty,
                originalLength: 0,
                appliedLength: 0
            )
        }

        let isRelevant = isPromptRelevant(
            promptText: trimmedPrompt,
            transcript: transcript,
            question: question,
            extraContext: extraContext
        )
        guard isRelevant else {
            return ResolvedQuickAssistPrompt(
                text: "",
                status: .ignoredIrrelevant,
                originalLength: trimmedPrompt.count,
                appliedLength: 0
            )
        }

        return ResolvedQuickAssistPrompt(
            text: trimmedPrompt,
            status: .applied,
            originalLength: trimmedPrompt.count,
            appliedLength: trimmedPrompt.count
        )
    }

    // MARK: - ML Guide Prompt Methods

    func activeMLGuidePromptText() -> String {
        guard let activeID = activeMLGuidePromptID,
              let prompt = mlGuidePrompts.first(where: { $0.id == activeID }) else {
            return ""
        }
        return prompt.prompt
    }

    func persistMLGuidePrompts() {
        if let data = try? JSONEncoder().encode(mlGuidePrompts) {
            defaults.set(data, forKey: Self.mlGuidePromptsKey)
        }
        defaults.set(activeMLGuidePromptID?.uuidString, forKey: Self.mlGuideActivePromptKey)
    }

    func persistQuickAssistPrompts() {
        if let data = try? JSONEncoder().encode(quickAssistPrompts) {
            defaults.set(data, forKey: Self.quickAssistPromptsKey)
        }
        defaults.set(activeQuickAssistPromptID?.uuidString, forKey: Self.quickAssistActivePromptKey)
    }

    private static func isPromptRelevant(
        promptText: String,
        transcript: String,
        question: String,
        extraContext: String
    ) -> Bool {
        let contextualText = [question, extraContext, transcript]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contextualText.isEmpty else {
            return false
        }

        let promptTerms = normalizedRelevanceTerms(from: promptText)
        let contextTerms = normalizedRelevanceTerms(from: contextualText)
        guard !promptTerms.isEmpty, !contextTerms.isEmpty else {
            return false
        }

        let overlap = promptTerms.intersection(contextTerms)
        if overlap.count >= quickAssistPromptMinSharedTerms {
            return true
        }

        // Allow a single uncommon long token match (e.g. company/project specific nouns).
        return overlap.contains(where: { $0.count >= 9 })
    }

    private static func normalizedRelevanceTerms(from text: String) -> Set<String> {
        let tokens = text
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)

        return Set(tokens.filter { token in
            guard token.count >= 5 else { return false }
            guard !quickAssistPromptStopWords.contains(token) else { return false }
            return true
        })
    }

}

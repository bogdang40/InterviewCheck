import Foundation

extension SessionController {
    func clearHubMemory() {
        do {
            try logger.clearHubMemory()
        } catch {
            errorMessage = "Could not clear hub memory: \(error.localizedDescription)"
            return
        }
        quickAssistMemorySnippets = []
        quickAssistRelatedMemorySnippets = []
        pinnedMemoryNodeIDsByThread = [:]
        lastQuickAssistMemoryNodeID = nil
        lastSolveMemoryNodeID = nil
        quickAssistRecoveryPlan = nil
        refreshWorkstreamTimeline()
    }
    func toggleQuickAssistMemoryPin(_ snippetID: String) {
        let normalizedID = snippetID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else { return }
        guard let threadID = activeQuickAssistThreadID ?? quickAssistCoordinator.activeThreadId else { return }

        var pinned = pinnedMemoryNodeIDsByThread[threadID] ?? Set<String>()
        if pinned.contains(normalizedID) {
            pinned.remove(normalizedID)
        } else {
            pinned.insert(normalizedID)
        }
        pinnedMemoryNodeIDsByThread[threadID] = pinned
        self.logger.setQuickAssistThreadPin(
            threadId: threadID,
            memoryNodeId: normalizedID,
            pinned: pinned.contains(normalizedID)
        )

        quickAssistRelatedMemorySnippets = applyPinnedMemoryOrdering(
            snippets: quickAssistRelatedMemorySnippets,
            threadID: threadID
        )
        quickAssistMemorySnippets = quickAssistRelatedMemorySnippets.map(\.text)
        syncQuickAssistSelectedTurnMetadata()
    }
    func refreshQuickAssistRelatedMemoryContext(trigger: RelatedMemoryRefreshTrigger) {
        guard settings.hubMemoryEnabled else {
            quickAssistRelatedMemorySnippets = []
            quickAssistMemorySnippets = []
            syncQuickAssistSelectedTurnMetadata()
            return
        }

        let sourceTurn = selectedQuickAssistTurn ?? quickAssistTurns.last
        let normalizedQuestionInput = quickAssistQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let questionForQuery: String = {
            switch trigger {
            case .turnSelection, .threadNavigation:
                return sourceTurn?.question ?? normalizedQuestionInput
            case .quickAssistView:
                if !normalizedQuestionInput.isEmpty {
                    return normalizedQuestionInput
                }
                return sourceTurn?.question ?? ""
            }
        }()

        let inferredQuestionSource: QuickAssistQuestionSource = {
            if let sourceTurn {
                return sourceTurn.questionSource
            }
            return questionForQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .manual
        }()

        let result = retrieveRelatedMemoryResult(
            question: questionForQuery,
            questionSource: inferredQuestionSource,
            querySource: trigger.querySource,
            threadID: activeQuickAssistThreadID ?? quickAssistCoordinator.activeThreadId,
            turnID: sourceTurn?.id.uuidString,
            intent: nil,
            contextMode: sourceTurn?.contextMode,
            previousResponse: sourceTurn?.response,
            sourceTurn: sourceTurn,
            limit: 4
        )
        quickAssistRelatedMemorySnippets = result.snippets
        quickAssistMemorySnippets = result.snippets.map(\.text)
        syncQuickAssistSelectedTurnMetadata()
    }
    func resolveRelatedMemoryQuerySource(
        questionSource: QuickAssistQuestionSource,
        isFollowUp: Bool
    ) -> RelatedMemoryQuerySource {
        if questionSource == .auto {
            return .autoSideQuestion
        }
        if isFollowUp {
            return .followUp
        }
        return .manualQuestion
    }
    func retrieveRelatedMemoryResult(
        question: String,
        questionSource: QuickAssistQuestionSource,
        querySource: RelatedMemoryQuerySource,
        threadID: String?,
        turnID: String?,
        intent: QuickAssistIntent?,
        contextMode: QuickAssistContextMode?,
        previousResponse: String?,
        sourceTurn: QuickAssistThread.Turn?,
        limit: Int
    ) -> RelatedMemoryResult {
        guard settings.hubMemoryEnabled else { return .empty }

        let queryText = buildRelatedMemoryQueryText(
            question: question,
            questionSource: questionSource,
            previousResponse: previousResponse,
            sourceTurn: sourceTurn
        )
        guard !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }

        let query = RelatedMemoryQuery(
            text: queryText,
            querySource: querySource,
            sessionId: session.id.uuidString,
            threadId: threadID,
            turnId: turnID,
            questionSource: questionSource == .none ? nil : questionSource,
            intent: intent,
            contextMode: contextMode,
            excludedNodeIds: [],
            maxGraphHops: 1,
            anchorLimit: 16,
            expansionLimit: 28
        )
        let result = relatedMemoryService.retrieve(query: query, limit: limit)
        return RelatedMemoryResult(
            snippets: applyPinnedMemoryOrdering(snippets: result.snippets, threadID: threadID),
            queryTokens: result.queryTokens,
            confidence: result.confidence,
            latencyMs: result.latencyMs,
            diagnostics: result.diagnostics
        )
    }
    private func buildRelatedMemoryQueryText(
        question: String,
        questionSource: QuickAssistQuestionSource,
        previousResponse: String?,
        sourceTurn: QuickAssistThread.Turn?
    ) -> String {
        var parts: [String] = []
        let normalizedQuestion = normalizedRelatedMemoryQuestion(
            question,
            source: questionSource
        )
        if !normalizedQuestion.isEmpty {
            parts.append(normalizedQuestion)
        }

        if questionSource == .auto, normalizedQuestion.isEmpty,
           let sourceQuestion = sourceTurn?.question.trimmingCharacters(in: .whitespacesAndNewlines),
           !sourceQuestion.isEmpty {
            parts.append(trimMemoryQueryText(sourceQuestion, maxChars: 340, useTail: false))
        }

        if questionSource == .auto {
            let responseSeed = (previousResponse ?? sourceTurn?.response ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !responseSeed.isEmpty {
                parts.append(trimMemoryQueryText(responseSeed, maxChars: 420, useTail: false))
            }
        }

        let trimmedExtraContext = quickAssistExtraContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExtraContext.isEmpty {
            parts.append(trimMemoryQueryText(trimmedExtraContext, maxChars: 260, useTail: false))
        }

        let transcriptTail = trimMemoryQueryText(session.transcript, maxChars: 700, useTail: true)
        if !transcriptTail.isEmpty {
            parts.append(transcriptTail)
        }

        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
    private func normalizedRelatedMemoryQuestion(
        _ question: String,
        source: QuickAssistQuestionSource
    ) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard source == .auto else {
            return trimMemoryQueryText(trimmed, maxChars: 320, useTail: false)
        }

        if let inferred = extractInferredAutoSideQuestion(from: trimmed) {
            let normalizedInferred = inferred.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedInferred.isEmpty,
               normalizedInferred.lowercased() != "<question>" {
                return trimMemoryQueryText(normalizedInferred, maxChars: 320, useTail: false)
            }
        }

        let cleanedLines = trimmed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let lower = line.lowercased()
                if lower.hasPrefix("based on my latest transcript and current screen") {
                    return false
                }
                if lower.hasPrefix("start your response with exactly one line:") {
                    return false
                }
                if lower.hasPrefix("then continue with:") {
                    return false
                }
                if lower == "answer:" {
                    return false
                }
                if lower.hasPrefix("inferred side question:") {
                    let inferred = String(line.dropFirst("inferred side question:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return !inferred.isEmpty && inferred.lowercased() != "<question>"
                }
                return true
            }

        let normalized = cleanedLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }
        return trimMemoryQueryText(normalized, maxChars: 320, useTail: false)
    }
    private func trimMemoryQueryText(_ text: String, maxChars: Int, useTail: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard trimmed.count > maxChars else { return trimmed }
        if useTail {
            return String(trimmed.suffix(maxChars))
        }
        return String(trimmed.prefix(maxChars))
    }
    private func applyPinnedMemoryOrdering(
        snippets: [RelatedMemorySnippet],
        threadID: String?
    ) -> [RelatedMemorySnippet] {
        guard !snippets.isEmpty else { return [] }
        let pinned = threadID.flatMap { pinnedMemoryNodeIDsByThread[$0] } ?? Set<String>()
        let decorated = snippets.map { snippet in
            snippet.withPinned(pinned.contains(snippet.id))
        }
        return decorated
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.isPinned != rhs.element.isPinned {
                    return lhs.element.isPinned && !rhs.element.isPinned
                }
                if lhs.element.score != rhs.element.score {
                    return lhs.element.score > rhs.element.score
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

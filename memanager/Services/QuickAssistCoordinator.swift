import Foundation

struct QuickAssistPreparedRequest {
    let transcript: String
    let context: QuickAssistContext
    let requestTimestamp: Date
    let hasScreenshot: Bool
    let contextEnvelope: ContextEnvelope
}

final class QuickAssistCoordinator {
    let thread = QuickAssistThread()
    private(set) var activeThreadId: String?
    private var lastQuickAssistTimestamp: Date?

    func resetForNewSession() {
        thread.reset()
        activeThreadId = nil
        lastQuickAssistTimestamp = nil
    }

    func clearContinuationContext() {
        thread.resetContinuationContext()
    }

    func activateThread(id: String, turns: [QuickAssistThread.Turn]) {
        activeThreadId = id
        thread.replaceTurns(turns)
        lastQuickAssistTimestamp = turns.last?.timestamp
    }

    func buildRequest(
        session: Session,
        question: String,
        extraContext: String,
        realtimePrompt: String,
        interactionMode: QuickAssistInteractionMode = .technical,
        freshCaptureResult: ScreenshotService.FreshCaptureResult,
        stackedScreenshotBase64: [String],
        contextMode: QuickAssistContextMode = .conversation,
        isFollowUp: Bool,
        complexity: QuickAssistComplexity = .moderate,
        modelTier: QuickAssistModelTier = .fast,
        tokenBudget: Int? = nil,
        solveHistorySummary: String? = nil,
        previousResponseOverride: String? = nil,
        conversationHistoryOverride: [(role: String, content: String)]? = nil,
        outputContractOverride: QuickAssistOutputContract? = nil,
        hubIntent: QuickAssistIntent = .conversation,
        routeReason: String? = nil,
        intentManifest: String? = nil,
        routeOverrideIntent: QuickAssistIntent? = nil,
        evidencePackManifest: String? = nil,
        promptAddendum: String? = nil,
        answerPlaybookContract: String? = nil,
        retrievedMemorySnippets: [String] = []
    ) -> QuickAssistPreparedRequest? {
        let transcript = buildTranscriptSinceLastQuickAssist(from: session)
        let orderedImages = buildOrderedImages(
            freshCaptureResult: freshCaptureResult,
            stackedScreenshotBase64: stackedScreenshotBase64
        )
        let contextEnvelope = ContextEnvelope(
            images: orderedImages,
            freshCaptureStatus: freshCaptureResult.succeeded ? .success : .failed,
            freshCaptureFailureReason: freshCaptureResult.failureReason?.rawValue
        )
        let screenshots = orderedImages.map(\.base64)
        let trimmedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContext = extraContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty || !screenshots.isEmpty || !trimmedQuestion.isEmpty || !trimmedContext.isEmpty else {
            return nil
        }

        let outputContract = outputContractOverride ?? buildOutputContract(
            transcript: transcript,
            question: trimmedQuestion,
            extraContext: trimmedContext,
            hasImages: !screenshots.isEmpty,
            contextMode: contextMode
        )

        let conversationHistory = isFollowUp
            ? (conversationHistoryOverride ?? thread.buildConversationHistory())
            : []
        let previousResponse = isFollowUp
            ? (previousResponseOverride ?? thread.lastResponse)
            : nil

        let context = QuickAssistContext(
            transcript: transcript,
            screenshots: screenshots,
            question: question,
            extraContext: extraContext,
            realtimePrompt: realtimePrompt,
            interactionMode: interactionMode,
            previousResponse: previousResponse,
            contextMode: contextMode,
            outputContract: outputContract,
            contextEnvelope: contextEnvelope,
            conversationHistory: conversationHistory,
            complexity: complexity,
            modelTier: modelTier,
            tokenBudget: tokenBudget,
            solveHistorySummary: solveHistorySummary,
            hubIntent: hubIntent,
            routeReason: routeReason,
            intentManifest: intentManifest,
            routeOverrideIntent: routeOverrideIntent,
            evidencePackManifest: evidencePackManifest,
            capabilityPromptAddendum: promptAddendum,
            answerPlaybookContract: answerPlaybookContract,
            retrievedMemorySnippets: retrievedMemorySnippets
        )

        return QuickAssistPreparedRequest(
            transcript: transcript,
            context: context,
            requestTimestamp: Date(),
            hasScreenshot: !screenshots.isEmpty,
            contextEnvelope: contextEnvelope
        )
    }

    func markSuccessfulResponse(
        _ response: String?,
        rawResponse: String? = nil,
        guardedResponse: String? = nil,
        provider: AIProviderType = .claude,
        requestTimestamp: Date,
        turnId: String = UUID().uuidString,
        transcript: String = "",
        question: String = "",
        contextMode: QuickAssistContextMode = .conversation,
        modelTier: QuickAssistModelTier = .fast,
        questionSource: QuickAssistQuestionSource = .none
    ) {
        if let response, !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            thread.appendTurn(QuickAssistThread.Turn(
                id: UUID(uuidString: turnId) ?? UUID(),
                timestamp: requestTimestamp,
                transcriptDelta: transcript,
                question: question,
                response: response,
                provider: provider,
                rawResponse: rawResponse ?? response,
                guardedResponse: guardedResponse ?? response,
                contextMode: contextMode,
                modelTier: modelTier,
                questionSource: questionSource
            ))
        }
        lastQuickAssistTimestamp = requestTimestamp
    }

    private func buildTranscriptSinceLastQuickAssist(from session: Session) -> String {
        guard let cutoff = lastQuickAssistTimestamp else {
            if !session.transcriptEntries.isEmpty {
                return buildSpeakerTranscript(from: session.transcriptEntries)
            }
            return normalizeTranscriptText(session.transcript)
        }

        let newEntries = buildRecentEntries(from: session, cutoff: cutoff)
        guard !newEntries.isEmpty else {
            guard let lastEntry = session.transcriptEntries.last else {
                return normalizeTranscriptText(session.transcript)
            }
            return formatTranscriptEntry(lastEntry, fallbackSpeakerIndex: 1)
        }

        return buildSpeakerTranscript(from: newEntries)
    }

    private func buildRecentEntries(from session: Session, cutoff: Date) -> [TranscriptEntry] {
        return session.transcriptEntries
            .filter { $0.timestamp > cutoff }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func buildSpeakerTranscript(from entries: [TranscriptEntry]) -> String {
        return entries
            .enumerated()
            .compactMap { index, entry in
                let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return formatTranscriptEntry(entry, fallbackSpeakerIndex: index + 1)
            }
            .joined(separator: "\n")
    }

    private func formatTranscriptEntry(_ entry: TranscriptEntry, fallbackSpeakerIndex: Int) -> String {
        let trimmedText = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(speakerLabel(for: entry.speaker, fallbackSpeakerIndex: fallbackSpeakerIndex)): \(trimmedText)"
    }

    private func speakerLabel(for speaker: TranscriptSpeaker, fallbackSpeakerIndex: Int) -> String {
        switch speaker {
        case .me:
            return "Me"
        case .speaker(let id):
            return "Speaker \(id + 1)"
        case .unknown:
            return "Speaker \(fallbackSpeakerIndex)"
        }
    }

    private func normalizeTranscriptText(_ transcript: String) -> String {
        var fallbackIndex = 1
        return transcript
            .components(separatedBy: .newlines)
            .compactMap { line in
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty else { return nil }

                if hasSpeakerPrefix(trimmedLine) {
                    return trimmedLine
                }

                let labeled = "Speaker \(fallbackIndex): \(trimmedLine)"
                fallbackIndex += 1
                return labeled
            }
            .joined(separator: "\n")
    }

    private func hasSpeakerPrefix(_ line: String) -> Bool {
        if line.range(of: #"^\s*Me\s*:"#, options: .regularExpression) != nil {
            return true
        }

        let speakerPrefix = #"^\s*Speaker\s+[0-9]+\s*:"#
        return line.range(of: speakerPrefix, options: .regularExpression) != nil
    }

    private func buildOrderedImages(
        freshCaptureResult: ScreenshotService.FreshCaptureResult,
        stackedScreenshotBase64: [String]
    ) -> [ContextImage] {
        var images: [ContextImage] = []

        if let freshBase64 = freshCaptureResult.base64 {
            images.append(ContextImage(source: .freshScreen, base64: freshBase64))
        }

        for base64 in stackedScreenshotBase64 where !base64.isEmpty {
            images.append(ContextImage(source: .capturedStack, base64: base64))
        }

        return images
    }

    private func buildOutputContract(
        transcript: String,
        question: String,
        extraContext: String,
        hasImages: Bool,
        contextMode: QuickAssistContextMode
    ) -> QuickAssistOutputContract {
        let hasTextEvidence = [transcript, question, extraContext].contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if hasImages && !hasTextEvidence {
            return QuickAssistOutputContract(
                detailLevel: .detailed,
                enforceFirstPerson: true,
                responseShape: .structured,
                requiredElements: ["problem_restatement", "inferred_question", "concrete_solution", "code_if_applicable"]
            )
        }

        let combinedContext = [transcript, question, extraContext]
            .joined(separator: "\n")
            .lowercased()

        let prefersConcise = containsAny(
            in: combinedContext,
            terms: ["quick", "quickly", "brief", "short", "concise", "tl;dr", "tldr"]
        )
        let prefersDetailed = containsAny(
            in: combinedContext,
            terms: [
                "walk through", "walk me through", "detailed", "detail",
                "deep dive", "step by step", "explain thoroughly", "in depth"
            ]
        )

        let detailLevel: QuickAssistDetailLevel
        if prefersConcise && !prefersDetailed {
            detailLevel = .concise
        } else if prefersDetailed && !prefersConcise {
            detailLevel = .detailed
        } else {
            switch contextMode {
            case .conversation:
                detailLevel = .concise
            case .implementationContext, .systemDesignContext, .allSectionsContext:
                detailLevel = .detailed
            }
        }

        return QuickAssistOutputContract(
            detailLevel: detailLevel,
            enforceFirstPerson: true,
            responseShape: responseShape(for: contextMode),
            requiredElements: requiredElements(for: contextMode)
        )
    }

    private func responseShape(for mode: QuickAssistContextMode) -> QuickAssistResponseShape {
        switch mode {
        case .conversation:
            return .conversational
        case .implementationContext:
            return .implementation
        case .systemDesignContext:
            return .architecture
        case .allSectionsContext:
            return .structured
        }
    }

    private func requiredElements(for mode: QuickAssistContextMode) -> [String] {
        switch mode {
        case .conversation:
            return []
        case .implementationContext:
            return ["code_fence", "edge_case"]
        case .systemDesignContext:
            return ["trade_off", "scalability"]
        case .allSectionsContext:
            return ["problem_restatement", "next_step"]
        }
    }

    private func containsAny(in source: String, terms: [String]) -> Bool {
        terms.contains { source.contains($0) }
    }
}

import Foundation

extension PromptBuilder {
    static func buildQuickAssistSystemPrompt(
        language: ProgrammingLanguage = .cpp,
        contextMode: QuickAssistContextMode = .conversation,
        interactionMode: QuickAssistInteractionMode = .technical
    ) -> String {
        let langName = language.rawValue

        let modeInstructions: String
        switch contextMode {
        case .conversation:
            modeInstructions = """

            In conversation mode:
            - Focus on what I can say next in the interview.
            - Answer thoroughly but stay speakable -- use natural spoken phrasing, not clipped bullet points.
            - Let the complexity of the question determine answer length.
            - Assess the question and respond with whatever is needed: code, diagrams, or plain speech.
            """
        case .implementationContext:
            modeInstructions = """

            In implementation-context mode:
            - Connect the requested answer directly to the referenced implementation details.
            - Use fenced code blocks for key logic snippets with a short explanation before/after.
            - Add brief complexity and edge-case notes as separate speakable chunks.
            - Include Mermaid only when it helps clarify flow.
            """
        case .systemDesignContext:
            modeInstructions = """

            In system-design context mode:
            - Prioritize architecture clarity and trade-off thinking.
            - Prefer Mermaid for topology, request flow, and scaling bottlenecks.
            - Avoid code unless the interviewer explicitly asks for code-level detail.
            - Keep each chunk brief and verbal, with concrete design rationale.
            """
        case .allSectionsContext:
            modeInstructions = """

            In all-sections context mode:
            - Synthesize relevant details from problem, questions, implementation, tests, complexity, and system design context.
            - Keep the response focused on what helps the next spoken answer most.
            - Use code or Mermaid only when they provide clear value.
            """
        }

        let interactionModeInstructions: String
        switch interactionMode {
        case .technical:
            interactionModeInstructions = """

            Interaction mode: Technical
            - Keep full technical depth.
            - Use structured formatting, code, and Mermaid whenever they add clear value.
            """
        case .behavioural:
            interactionModeInstructions = """

            Interaction mode: Behavioural
            - Keep this conversational and interview-speakable.
            - Avoid structured technical formatting by default.
            - Do NOT include code or Mermaid unless the question explicitly asks for code, architecture, or a diagram.
            """
        }
        
        return """
        You are helping a candidate answer an interviewer's question. Write the response AS IF YOU ARE THE CANDIDATE \
        speaking directly to the interviewer. Do NOT talk TO the candidate - BE the candidate.

        \(VoiceCore.preamble(for: .quickAssist))

        \(VoiceCore.fewShotBlock(for: .quickAssist))

        ### CRITICAL: You ARE the Candidate
        
        - Write in first person as if YOU are the one being interviewed
        - Speak directly to the interviewer: "So what I'm thinking is...", "My approach would be..."
        - NEVER coach the candidate. Do NOT use phrases like "here's what you say", "you can say", "say this", or "you should say"
        - If you accidentally produce coaching language, rewrite it into direct first-person before final output
        - This is YOUR answer to give to the interviewer, not advice for someone else

        ### CRITICAL: Language Preference
        
        If code is requested or genuinely needed, use \(langName) unless the screenshot clearly shows a different language.
        When you do provide code, write idiomatic \(langName) with proper syntax.

        ### CRITICAL: Abbreviation Clarity Policy (strict)

        - On first mention, define abbreviations as `Full Term (ABBR)`.
        - If you cannot confidently expand an abbreviation, do not use it. Use the full term instead.
        - Apply this rule in prose and Mermaid labels.
        - Avoid unexplained shorthand labels in Mermaid nodes.

        ### Answer Flow

        Let the answer flow as natural paragraphs. Break into shorter lines only when you're switching thought. Be thorough when the question requires depth; be brief when it does not.

        **When explaining code:**
        - Add comments that explain your reasoning (as you would verbally in an interview)
        - Reference specific variable names and why you chose them
        - Briefly mention an alternative you considered

        **Formatting requirements:**
        - If you include code, format it in markdown fenced code blocks.
        - If a compact diagram would clarify the explanation, include it in a fenced mermaid block.
        - Use Mermaid only when helpful unless the output contract requires it.
        - \(bannedPhrasesLine)

        **Context priority:**
        - Treat transcript, screenshots, and mode-specific section context as primary evidence.
        - Treat the real-time prompt as supporting guidance only.
        - Use the real-time prompt only when it is directly relevant to the primary evidence.
        - If it conflicts with transcript/screenshot/section context, ignore it.

        Be fast and direct - this is a live interview.
        \(interactionModeInstructions)
        \(modeInstructions)
        """
    }

    /// Convenience overload that reads the full parameter list straight from the
    /// Quick Assist DTO the providers already hold. Delegates to the explicit
    /// parameter overload so the produced prompt stays byte-identical.
    static func buildQuickAssistPrompt(context: QuickAssistContext) -> String {
        buildQuickAssistPrompt(
            transcript: context.transcript,
            question: context.question,
            extraContext: context.extraContext,
            realtimePrompt: context.realtimePrompt,
            hasImages: !context.screenshots.isEmpty,
            interactionMode: context.interactionMode,
            previousResponse: context.previousResponse,
            contextManifest: context.contextEnvelope?.manifest,
            contextMode: context.contextMode,
            outputContract: context.outputContract,
            conversationHistory: context.conversationHistory,
            solveContextSummary: context.solveHistorySummary,
            complexity: context.complexity,
            intent: context.hubIntent,
            routeReason: context.routeReason,
            intentManifest: context.intentManifest,
            routeOverrideIntent: context.routeOverrideIntent,
            evidencePackManifest: context.evidencePackManifest,
            capabilityPromptAddendum: context.capabilityPromptAddendum,
            answerPlaybookContract: context.answerPlaybookContract,
            retrievedMemorySnippets: context.retrievedMemorySnippets
        )
    }

    static func buildQuickAssistPrompt(
        transcript: String,
        question: String,
        extraContext: String,
        realtimePrompt: String,
        hasImages: Bool,
        interactionMode: QuickAssistInteractionMode = .technical,
        previousResponse: String? = nil,
        contextManifest: String? = nil,
        contextMode: QuickAssistContextMode = .conversation,
        outputContract: QuickAssistOutputContract = .default,
        conversationHistory: [(role: String, content: String)] = [],
        solveContextSummary: String? = nil,
        complexity: QuickAssistComplexity = .moderate,
        intent: QuickAssistIntent = .conversation,
        routeReason: String? = nil,
        intentManifest: String? = nil,
        routeOverrideIntent: QuickAssistIntent? = nil,
        evidencePackManifest: String? = nil,
        capabilityPromptAddendum: String? = nil,
        answerPlaybookContract: String? = nil,
        retrievedMemorySnippets: [String] = []
    ) -> String {
        var prompt = ""
        let hasPrimaryTextEvidence = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasImages {
            prompt += "A screenshot is attached. "
        }

        // Conversation history (multi-turn memory)
        if !conversationHistory.isEmpty {
            prompt += "Previous conversation:\n"
            for turn in conversationHistory {
                prompt += "[\(turn.role)]: \(turn.content)\n"
            }
            prompt += "\n"
        }

        // Compact solve summary (not the full solve)
        if let summary = solveContextSummary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "Solve context summary:\n\(summary)\n\n"
        }

        if !retrievedMemorySnippets.isEmpty {
            prompt += "Relevant prior memory:\n"
            for (index, snippet) in retrievedMemorySnippets.enumerated() {
                prompt += "\(index + 1). \(snippet)\n"
            }
            prompt += "\n"
        }

        if !transcript.isEmpty {
            prompt += "Transcript:\n\(transcript)\n\n"
        }

        if !extraContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let sectionLabel: String
            switch contextMode {
            case .conversation:
                sectionLabel = "Additional context/documents"
            case .implementationContext:
                sectionLabel = "IMPLEMENTATION CONTEXT"
            case .systemDesignContext:
                sectionLabel = "SYSTEM DESIGN CONTEXT"
            case .allSectionsContext:
                sectionLabel = "ALL SECTIONS CONTEXT"
            }
            prompt += "\(sectionLabel):\n\(extraContext)\n\n"
        }

        if !realtimePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "Real-time prompt (supporting context only; use only if directly relevant):\n\(realtimePrompt)\n\n"
        }

        if !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "Question hint (optional):\n\(question)\n\n"
        }

        if hasImages && !hasPrimaryTextEvidence {
            prompt += """
            Visual-inference mode:
            - No transcript or typed question is available.
            - Infer the most likely interview question from the screenshot and answer it directly.
            - Provide a concrete solution, not coaching advice.
            - Include code when the inferred question is implementation-oriented.

            """
        }

        if let contextManifest, !contextManifest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "Context manifest:\n\(contextManifest)\n\n"
        }

        if let intentManifest, !intentManifest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "Intent manifest:\n\(intentManifest)\n\n"
        }

        if let routeReason, !routeReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "Route reason:\n\(routeReason)\n\n"
        }

        if let routeOverrideIntent {
            prompt += "Route override intent:\n\(routeOverrideIntent.rawValue)\n\n"
        }

        if let evidencePackManifest, !evidencePackManifest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "Evidence manifest:\n\(evidencePackManifest)\n\n"
        }

        if let capabilityPromptAddendum, !capabilityPromptAddendum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "Capability guidance:\n\(capabilityPromptAddendum)\n\n"
        }

        if let answerPlaybookContract, !answerPlaybookContract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "Answer playbook (follow this response format exactly):\n\(answerPlaybookContract)\n\n"
        }

        prompt += """
        Output contract:
        - intent: \(intent.rawValue)
        - interaction_mode: \(interactionMode.rawValue)
        - first_person_required: \(outputContract.enforceFirstPerson ? "yes" : "no")
        - detail_level: \(outputContract.detailLevel.rawValue)
        - response_shape: \(outputContract.responseShape.rawValue)
        - required_elements: \(outputContract.requiredElements.isEmpty ? "none" : outputContract.requiredElements.joined(separator: ","))

        Formatting rules:
        - Use fenced code blocks for ALL code (no inline code for multi-line snippets)
        - Use fenced mermaid blocks for ALL diagrams
        - Define abbreviations on first use as `Full Term (ABBR)` in prose and Mermaid labels
        - If the full term is unknown, do not introduce the abbreviation
        - Assess the question yourself and decide what the answer needs: code, diagrams, plain explanation, or a combination
        - Do not hold back code if the question is about implementation
        - Do not hold back diagrams if the question is about architecture
        - Prefer clear section headers (## / ###) when the answer has multiple parts
        - If a diagram is large, break it into multiple labeled Mermaid blocks (for example: "### Diagram Step 1")

        """

        if interactionMode == .behavioural {
            let starRequiredElements: Set<String> = [
                "star_situation",
                "star_task",
                "star_action",
                "star_result",
                "star_reflection"
            ]
            let requiredElements = Set(outputContract.requiredElements.map { $0.lowercased() })
            let shouldUseStarPlus = starRequiredElements.isSubset(of: requiredElements)
            prompt += """
            Behavioural mode constraints:
            - Respond as natural spoken interview language first.
            - Avoid rigid technical sections unless explicitly asked for structure.
            - Only include code when the user explicitly asks for code.
            - Only include Mermaid when the user explicitly asks for a diagram or architecture.

            """
            if shouldUseStarPlus {
                prompt += """
                Behavioural STAR+ response contract:
                - Use light section labels in this exact order: Situation, Task, Action, Result, Reflection.
                - Keep each section to 1-3 speakable sentences.
                - Reflection must include what I learned and how I'd apply it next time.
                - Keep this first-person and conversational; do not switch to rigid bullet templates.

                """
            }
        }

        // Adaptive structure directive based on complexity
        switch complexity {
        case .deep:
            prompt += """
            Response format: This is a substantive question -- answer with depth.
            Structure your response with clear section headers (## ), code blocks with explanations,
            and Mermaid diagrams where they clarify architecture. Use the step-by-step format
            with speakable chunks between code blocks.

            """
        case .moderate:
            prompt += """
            Response format: Answer thoroughly and clearly. Let the question's complexity determine how much detail you provide.
            Use code or diagrams if they help.

            """
        case .light:
            prompt += """
            Response format: Keep this conversational. Answer the question fully but do not over-elaborate.

            """
        }

        // Include previous response for follow-up continuations. When the
        // identical text already rides in the conversation history above,
        // reference it instead of shipping the full answer a second time.
        let trimmedPreviousResponse = previousResponse?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedPreviousResponse.isEmpty {
            let historyCarriesPrevious = conversationHistory.contains { turn in
                turn.role.caseInsensitiveCompare("assistant") == .orderedSame
                    && turn.content.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedPreviousResponse
            }
            if historyCarriesPrevious {
                prompt += "Your previous Quick Assist response is the last assistant turn in the conversation above.\n\n"
            } else {
                prompt += "Your previous Quick Assist response:\n\(trimmedPreviousResponse)\n\n"
            }
            prompt += "Continue from where you left off or answer the follow-up question based on the latest transcript. Respond directly in first person as the candidate."
        } else {
            prompt += "Use the context above to infer the question and provide a direct first-person candidate response I can speak out loud."
        }

        switch outputContract.detailLevel {
        case .concise:
            prompt += "\n\nKeep the response speakable and well-paced. Do not pad, but do not truncate a complete thought."
        case .detailed:
            prompt += "\n\nGo deeper with clear trade-offs and reasoning. Stay speakable but thorough."
        }

        return prompt
    }
}

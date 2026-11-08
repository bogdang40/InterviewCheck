import XCTest
@testable import memanager

/// Contract tests that freeze stable landmarks of PromptBuilder output before
/// refactoring: key instruction phrases, section ordering, and interpolated
/// context values. Deliberately NOT full-string snapshots, so cosmetic
/// whitespace changes do not break them.
final class PromptBuilderContractTests: XCTestCase {

    // MARK: - Helpers

    private func assertContainsAll(
        _ landmarks: [String],
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for landmark in landmarks where !text.contains(landmark) {
            XCTFail("Missing landmark: \(landmark)", file: file, line: line)
        }
    }

    private func assertOrdered(
        _ landmarks: [String],
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var searchStart = text.startIndex
        for landmark in landmarks {
            guard let range = text.range(of: landmark, range: searchStart..<text.endIndex) else {
                XCTFail("Missing or out-of-order landmark: \(landmark)", file: file, line: line)
                return
            }
            searchStart = range.upperBound
        }
    }

    // MARK: - Solve system prompt

    func testSolveSystemPromptSectionHeadersAppearInOrder() {
        let prompt = PromptBuilder.buildSystemPrompt(language: .cpp)

        assertOrdered([
            "You are a senior software engineer",
            "Structure your response with these exact section headers:",
            "## Problem",
            "**Restating the problem:**",
            "**Key constraints:**",
            "**The real insight here:**",
            "**Why this approach is correct:**",
            "## Clarifying Questions",
            "**Edge cases to clarify:**",
            "**Constraints to confirm:**",
            "**Input validation:**",
            "## Implementation",
            "### CRITICAL: Code Comments Required",
            "## Tests",
            "**Base cases:**",
            "**Edge cases:**",
            "**Error cases:**",
            "## Complexity",
            "**Trade-off:**"
        ], in: prompt)

        assertContainsAll([
            "### Optional Canvas Protocol",
            "canvas:array",
            "# NEW: lines X-Y"
        ], in: prompt)
    }

    func testSolveSystemPromptInterpolatesSelectedLanguage() {
        let cpp = PromptBuilder.buildSystemPrompt(language: .cpp)
        assertContainsAll([
            "YOU MUST use C++ syntax in your actual response",
            "IMPORTANT: Use C++ for ALL code examples. Write idiomatic C++ code."
        ], in: cpp)

        let python = PromptBuilder.buildSystemPrompt(language: .python)
        assertContainsAll([
            "IMPORTANT: Use Python for ALL code examples. Write idiomatic Python code."
        ], in: python)
    }

    // MARK: - Solve user prompt

    func testSolveUserPromptComposesImageAndTranscriptLandmarks() {
        let prompt = PromptBuilder.buildUserPrompt(
            transcript: "We discussed the two sum problem",
            hasImages: true
        )

        XCTAssertTrue(prompt.hasPrefix("I've shared screenshots of the coding problem."))
        assertOrdered([
            "Here's what was discussed:",
            "We discussed the two sum problem",
            "Please analyze this and walk me through the solution like a senior engineer would think through it."
        ], in: prompt)
    }

    func testSolveUserPromptDegeneratesToBareInstruction() {
        let prompt = PromptBuilder.buildUserPrompt(transcript: "", hasImages: false)
        XCTAssertEqual(
            prompt,
            "Please analyze this and walk me through the solution like a senior engineer would think through it."
        )
    }

    // MARK: - Quick Assist system prompt

    func testQuickAssistSystemPromptTechnicalConversationLandmarks() {
        let prompt = PromptBuilder.buildQuickAssistSystemPrompt(
            language: .python,
            contextMode: .conversation,
            interactionMode: .technical
        )

        assertOrdered([
            "You are helping a candidate answer an interviewer's question",
            "### CRITICAL: You ARE the Candidate",
            "### CRITICAL: Language Preference",
            "use Python unless the screenshot clearly shows a different language",
            "### CRITICAL: Abbreviation Clarity Policy (strict)",
            "Do not open with any of these:",
            "Be fast and direct - this is a live interview.",
            "Interaction mode: Technical",
            "In conversation mode:"
        ], in: prompt)
    }

    func testQuickAssistSystemPromptBehaviouralSystemDesignLandmarks() {
        let prompt = PromptBuilder.buildQuickAssistSystemPrompt(
            language: .cpp,
            contextMode: .systemDesignContext,
            interactionMode: .behavioural
        )

        assertOrdered([
            "Interaction mode: Behavioural",
            "Do NOT include code or Mermaid unless the question explicitly asks for code, architecture, or a diagram.",
            "In system-design context mode:",
            "Prefer Mermaid for topology"
        ], in: prompt)

        XCTAssertFalse(prompt.contains("Interaction mode: Technical"))
        XCTAssertFalse(prompt.contains("In conversation mode:"))
    }

    // MARK: - Quick Assist user prompt

    func testQuickAssistPromptRichContextLandmarksInOrder() {
        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "Interviewer asked how to scale rate limiting",
            question: "How would you scale it globally?",
            extraContext: "Existing design notes for the gateway",
            realtimePrompt: "Mention token buckets",
            hasImages: true,
            interactionMode: .technical,
            previousResponse: nil,
            contextManifest: "images_attached: 2",
            contextMode: .systemDesignContext,
            outputContract: .default,
            conversationHistory: [
                (role: "user", content: "Earlier turn question"),
                (role: "assistant", content: "Earlier turn answer")
            ],
            solveContextSummary: "Solved the LRU cache problem",
            complexity: .deep,
            intent: .systemDesign,
            routeReason: "matched system design keywords",
            intentManifest: "signals: architecture",
            routeOverrideIntent: .walkthrough,
            evidencePackManifest: "evidence: transcript+screenshot",
            capabilityPromptAddendum: "Prefer compact Mermaid diagrams",
            retrievedMemorySnippets: ["Candidate prefers explicit trade-off talk"]
        )

        XCTAssertTrue(prompt.hasPrefix("A screenshot is attached."))

        assertOrdered([
            "Previous conversation:",
            "[user]: Earlier turn question",
            "[assistant]: Earlier turn answer",
            "Solve context summary:",
            "Solved the LRU cache problem",
            "Relevant prior memory:",
            "1. Candidate prefers explicit trade-off talk",
            "Transcript:",
            "Interviewer asked how to scale rate limiting",
            "SYSTEM DESIGN CONTEXT:",
            "Existing design notes for the gateway",
            "Real-time prompt (supporting context only; use only if directly relevant):",
            "Mention token buckets",
            "Question hint (optional):",
            "How would you scale it globally?",
            "Context manifest:",
            "images_attached: 2",
            "Intent manifest:",
            "signals: architecture",
            "Route reason:",
            "matched system design keywords",
            "Route override intent:",
            "walkthrough",
            "Evidence manifest:",
            "evidence: transcript+screenshot",
            "Capability guidance:",
            "Prefer compact Mermaid diagrams",
            "Output contract:",
            "- intent: systemDesign",
            "- interaction_mode: technical",
            "- first_person_required: yes",
            "- detail_level: concise",
            "- response_shape: conversational",
            "- required_elements: none",
            "Formatting rules:",
            "Response format: This is a substantive question",
            "Use the context above to infer the question"
        ], in: prompt)

        // Primary text evidence exists, so visual-inference mode is absent.
        XCTAssertFalse(prompt.contains("Visual-inference mode:"))
        // Concise detail level appends the speakable pacing suffix.
        XCTAssertTrue(prompt.contains("Keep the response speakable and well-paced."))
    }

    func testQuickAssistPromptVisualInferenceBehaviouralStarContract() {
        let starContract = QuickAssistOutputContract(
            detailLevel: .detailed,
            enforceFirstPerson: false,
            responseShape: .structured,
            requiredElements: [
                "star_situation",
                "star_task",
                "star_action",
                "star_result",
                "star_reflection"
            ]
        )

        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "",
            question: "",
            extraContext: "",
            realtimePrompt: "",
            hasImages: true,
            interactionMode: .behavioural,
            previousResponse: "I framed the trade-offs first.",
            outputContract: starContract,
            complexity: .light,
            intent: .conversation
        )

        assertContainsAll([
            "Visual-inference mode:",
            "Infer the most likely interview question from the screenshot",
            "- intent: conversation",
            "- interaction_mode: behavioural",
            "- first_person_required: no",
            "- detail_level: detailed",
            "- response_shape: structured",
            "- required_elements: star_situation,star_task,star_action,star_result,star_reflection",
            "Behavioural mode constraints:",
            "Behavioural STAR+ response contract:",
            "Situation, Task, Action, Result, Reflection",
            "Response format: Keep this conversational.",
            "Your previous Quick Assist response:",
            "I framed the trade-offs first.",
            "Continue from where you left off",
            "Go deeper with clear trade-offs and reasoning. Stay speakable but thorough."
        ], in: prompt)
    }

    func testQuickAssistFollowUpDoesNotDuplicatePreviousResponseCarriedInHistory() {
        let previous = "I framed the trade-offs first."
        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "Interviewer asked a follow-up",
            question: "And what about consistency?",
            extraContext: "",
            realtimePrompt: "",
            hasImages: false,
            interactionMode: .technical,
            previousResponse: previous,
            outputContract: .default,
            conversationHistory: [
                (role: "user", content: "Original question"),
                (role: "assistant", content: previous)
            ],
            complexity: .light,
            intent: .conversation
        )

        assertContainsAll([
            "[assistant]: \(previous)",
            "Your previous Quick Assist response is the last assistant turn in the conversation above.",
            "Continue from where you left off"
        ], in: prompt)

        // The full text must appear exactly once (inside the history), never
        // duplicated into a second block.
        let occurrences = prompt.components(separatedBy: previous).count - 1
        XCTAssertEqual(occurrences, 1, "Previous response should ride in history only")
        XCTAssertFalse(prompt.contains("Your previous Quick Assist response:\n"))
    }

    func testQuickAssistPromptAnswerPlaybookBlockPlacement() {
        guard let playbook = InterviewPlaybookCatalog.playbook(id: "self_intro") else {
            return XCTFail("self_intro playbook missing")
        }

        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "Interviewer: tell me about yourself",
            question: "",
            extraContext: "",
            realtimePrompt: "",
            hasImages: false,
            interactionMode: .behavioural,
            outputContract: playbook.outputContract,
            capabilityPromptAddendum: "Keep it warm and specific",
            answerPlaybookContract: playbook.promptContract
        )

        assertOrdered([
            "Capability guidance:",
            "Keep it warm and specific",
            "Answer playbook (follow this response format exactly):",
            "Answer playbook: Present Past Future for a Self introduction question.",
            "Target spoken length: 60 to 90 seconds.",
            "**Say first:**",
            "1. Thesis: one line identity claim that frames me for this exact role.",
            "Depth policy: natural spoken narrative only.",
            "Output contract:",
            "- required_elements: beat_thesis,beat_present,beat_past,beat_future"
        ], in: prompt)
    }

    func testQuickAssistPromptOmitsPlaybookBlockWhenAbsent() {
        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "Interviewer asked about caching",
            question: "What is a cache?",
            extraContext: "",
            realtimePrompt: "",
            hasImages: false
        )

        XCTAssertFalse(prompt.contains("Answer playbook"))
    }

    // MARK: - System design prompts

    func testSystemDesignSystemPromptLandmarks() {
        let prompt = PromptBuilder.buildSystemDesignSystemPrompt()

        // Deliberately updated for the v2 taxonomy (Estimation and Wrap-Up
        // activated, parseable formats demanded): sanctioned intentional
        // evolution, mirroring the schema v15 precedent.
        assertOrdered([
            "You are a principal software architect",
            "## System Design",
            "**Requirements:**",
            "Use exactly 2 progressive steps.",
            "**Estimation:**",
            "Use exactly 2 progressive steps.",
            "**High-Level Architecture:**",
            "Use exactly 4 progressive steps.",
            "**Wrap-Up:**",
            "Use exactly 1 progressive steps.",
            "### CRITICAL: Progressive Step Contract (mandatory for EVERY section above)",
            "### Step N: <short title>",
            "For Estimation, put each figure on its own line as \"Metric: value (formula)\".",
            "METHOD /path: purpose",
            "Bottleneck: ...",
            "COMPLETION_CHECKLIST: Requirements=2, Estimation=2, High-Level Architecture=4, Components=3, Data Flow=3, Database Design=3, API Design=3, Scalability=3, Trade-offs=2, Wrap-Up=1"
        ], in: prompt)
    }

    func testSystemDesignUserPromptIncludesManifestAndRecovery() {
        let prompt = PromptBuilder.buildSystemDesignUserPrompt(
            transcript: "Design a URL shortener for 100M users",
            hasImages: true,
            contextManifest: "images_attached: 1",
            recoveryRequest: "Regenerate the Components section with 3 steps"
        )

        XCTAssertTrue(prompt.hasPrefix("I've shared screenshots of the system design problem."))
        assertOrdered([
            "Here's what was discussed:",
            "Design a URL shortener for 100M users",
            "Context manifest:",
            "images_attached: 1",
            "Please design this system and walk me through your approach",
            "RECOVERY REQUEST (strict):",
            "Regenerate the Components section with 3 steps"
        ], in: prompt)
    }
}

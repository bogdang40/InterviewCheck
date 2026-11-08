import XCTest
@testable import memanager

final class PromptBuilderQuickAssistPromptTests: XCTestCase {
    func testQuickAssistPromptLabelsImplementationContext() {
        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "",
            question: "",
            extraContext: "IMPLEMENTATION CONTEXT FROM PREVIOUS SOLVE\nProblem: ...",
            realtimePrompt: "",
            hasImages: false,
            contextMode: .implementationContext
        )
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("IMPLEMENTATION CONTEXT"))
        XCTAssertTrue(prompt.contains("IMPLEMENTATION CONTEXT FROM PREVIOUS SOLVE"))
    }

    func testQuickAssistPromptLabelsSystemDesignContext() {
        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "",
            question: "",
            extraContext: "SYSTEM DESIGN CONTEXT FROM PREVIOUS SOLVE\nDesign: ...",
            realtimePrompt: "",
            hasImages: false,
            contextMode: .systemDesignContext
        )
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("SYSTEM DESIGN CONTEXT"))
        XCTAssertTrue(prompt.contains("SYSTEM DESIGN CONTEXT FROM PREVIOUS SOLVE"))
    }

    func testQuickAssistPromptMarksRealtimePromptAsSupportingContextOnly() {
        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "Speaker 1: question",
            question: "",
            extraContext: "",
            realtimePrompt: "Always mention X",
            hasImages: false
        )
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("supporting context only"))
    }

    func testQuickAssistPromptIncludesSimplifiedOutputContract() {
        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "Speaker 1: Please implement the function",
            question: "",
            extraContext: "",
            realtimePrompt: "",
            hasImages: false,
            outputContract: QuickAssistOutputContract(
                detailLevel: .detailed,
                enforceFirstPerson: true,
                responseShape: .structured,
                requiredElements: ["step_by_step"]
            )
        )

        XCTAssertTrue(prompt.contains("first_person_required: yes"))
        XCTAssertTrue(prompt.contains("detail_level: detailed"))
        XCTAssertTrue(prompt.contains("response_shape: structured"))
        XCTAssertTrue(prompt.contains("required_elements: step_by_step"))
        XCTAssertTrue(prompt.contains("Use fenced code blocks for ALL code"))
        XCTAssertTrue(prompt.contains("Use fenced mermaid blocks for ALL diagrams"))
    }

    func testQuickAssistPromptIncludesAdaptiveStructureForDeepComplexity() {
        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "Me: walk me through the caching layer",
            question: "",
            extraContext: "",
            realtimePrompt: "",
            hasImages: false,
            complexity: .deep
        )

        XCTAssertTrue(prompt.contains("Structure your response"))
    }

    func testQuickAssistPromptAsksForSectionHeadersAndStepwiseMermaidWhenLarge() {
        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "Me: design the architecture and explain it in stages",
            question: "",
            extraContext: "",
            realtimePrompt: "",
            hasImages: false
        )

        XCTAssertTrue(prompt.contains("Prefer clear section headers (## / ###)"))
        XCTAssertTrue(prompt.contains("### Diagram Step 1"))
    }

    func testQuickAssistPromptRequiresDefinedAbbreviationsInProseAndMermaid() {
        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "Me: design the architecture",
            question: "",
            extraContext: "",
            realtimePrompt: "",
            hasImages: false
        )

        XCTAssertTrue(prompt.contains("Define abbreviations on first use as `Full Term (ABBR)` in prose and Mermaid labels"))
        XCTAssertTrue(prompt.contains("If the full term is unknown, do not introduce the abbreviation"))
    }

    func testQuickAssistPromptIncludesConversationHistory() {
        let history: [(role: String, content: String)] = [
            (role: "user", content: "What is a hash map?"),
            (role: "assistant", content: "A hash map is a data structure...")
        ]

        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "Me: follow up question",
            question: "",
            extraContext: "",
            realtimePrompt: "",
            hasImages: false,
            conversationHistory: history
        )

        XCTAssertTrue(prompt.contains("Previous conversation"))
        XCTAssertTrue(prompt.contains("What is a hash map?"))
        XCTAssertTrue(prompt.contains("A hash map is a data structure..."))
    }

    func testQuickAssistPromptIncludesSolveContextSummary() {
        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "Me: explain",
            question: "",
            extraContext: "",
            realtimePrompt: "",
            hasImages: false,
            solveContextSummary: "Problem: Two Sum. Approach: Hash map. Complexity: O(n)."
        )

        XCTAssertTrue(prompt.contains("Solve context"))
        XCTAssertTrue(prompt.contains("Two Sum"))
    }

    func testQuickAssistPromptDoesNotUseWhatDoISayTail() {
        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "Me: solve this",
            question: "",
            extraContext: "",
            realtimePrompt: "",
            hasImages: false
        )

        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("what do i say"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("direct first-person candidate response"))
    }

    func testQuickAssistPromptAddsBehaviouralConstraintsWhenModeIsBehavioural() {
        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "Me: explain my approach",
            question: "How should I answer this clearly?",
            extraContext: "",
            realtimePrompt: "",
            hasImages: false,
            interactionMode: .behavioural
        )

        XCTAssertTrue(prompt.contains("interaction_mode: behavioural"))
        XCTAssertTrue(prompt.contains("Behavioural mode constraints"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("Only include code when the user explicitly asks for code"))
    }

    func testQuickAssistPromptAddsBehaviouralStarPlusContractWhenRequired() {
        let prompt = PromptBuilder.buildQuickAssistPrompt(
            transcript: "Me: tell me about a leadership challenge",
            question: "How should I explain this example?",
            extraContext: "",
            realtimePrompt: "",
            hasImages: false,
            interactionMode: .behavioural,
            outputContract: QuickAssistOutputContract(
                detailLevel: .concise,
                enforceFirstPerson: true,
                responseShape: .structured,
                requiredElements: [
                    "star_situation",
                    "star_task",
                    "star_action",
                    "star_result",
                    "star_reflection"
                ]
            )
        )

        XCTAssertTrue(prompt.contains("Behavioural STAR+ response contract"))
        XCTAssertTrue(prompt.contains("Situation, Task, Action, Result, Reflection"))
        XCTAssertTrue(prompt.contains("Reflection must include what I learned"))
    }
}

final class PromptBuilderMLGuidePromptTests: XCTestCase {
    func testMLGuideUserPromptAvoidsCoachingTail() {
        let prompt = PromptBuilder.buildMLGuideUserPrompt(
            transcript: "Me: continue",
            question: "How do I evaluate the baseline?",
            extraContext: "",
            realtimePrompt: "",
            hasImages: false,
            previousResponse: "## Step 1..."
        )

        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("what do i say"))
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("what should i say"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("respond directly in first person"))
    }
}

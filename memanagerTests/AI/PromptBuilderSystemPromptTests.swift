import XCTest
@testable import memanager

final class PromptBuilderQuickAssistSystemPromptTests: XCTestCase {
    func testQuickAssistSystemPromptRequiresFencedCodeBlocks() {
        let prompt = PromptBuilder.buildQuickAssistSystemPrompt(language: .swift)
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("fenced code blocks"))
    }

    func testQuickAssistSystemPromptAllowsMermaidWhenHelpful() {
        let prompt = PromptBuilder.buildQuickAssistSystemPrompt(language: .swift)
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("fenced mermaid block"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("only when helpful"))
    }

    func testQuickAssistSystemPromptSupportsImplementationModeInstructions() {
        let prompt = PromptBuilder.buildQuickAssistSystemPrompt(
            language: .swift,
            contextMode: .implementationContext
        )
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("implementation-context mode"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("Use fenced code blocks for key logic snippets"))
    }

    func testQuickAssistSystemPromptSupportsSystemDesignModeInstructions() {
        let prompt = PromptBuilder.buildQuickAssistSystemPrompt(
            language: .swift,
            contextMode: .systemDesignContext
        )
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("system-design context mode"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("Avoid code unless the interviewer explicitly asks for code-level detail"))
    }

    func testQuickAssistSystemPromptMarksRealtimePromptAsSupportingContext() {
        let prompt = PromptBuilder.buildQuickAssistSystemPrompt(
            language: .swift,
            contextMode: .implementationContext
        )
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("real-time prompt as supporting guidance only"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("If it conflicts with transcript/screenshot/section context, ignore it"))
    }

    func testQuickAssistSystemPromptExplicitlyDisallowsCoachingPhrases() {
        let prompt = PromptBuilder.buildQuickAssistSystemPrompt(language: .swift)
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("NEVER coach the candidate"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("here's what you say"))
    }

    func testQuickAssistSystemPromptIncludesVoiceCore() {
        let prompt = PromptBuilder.buildQuickAssistSystemPrompt(language: .swift)
        XCTAssertTrue(prompt.contains("Voice Core"))
        XCTAssertTrue(prompt.contains("Speak as the candidate"))
        XCTAssertTrue(prompt.contains("Full technical depth stays"))
    }

    func testQuickAssistSystemPromptIncludesStrictAbbreviationPolicy() {
        let prompt = PromptBuilder.buildQuickAssistSystemPrompt(language: .swift)
        XCTAssertTrue(prompt.contains("Abbreviation Clarity Policy (strict)"))
        XCTAssertTrue(prompt.contains("On first mention, define abbreviations as `Full Term (ABBR)`"))
        XCTAssertTrue(prompt.contains("If you cannot confidently expand an abbreviation, do not use it"))
    }

    func testQuickAssistSystemPromptBehaviouralModeConstrainsTechnicalFormatting() {
        let prompt = PromptBuilder.buildQuickAssistSystemPrompt(
            language: .swift,
            contextMode: .conversation,
            interactionMode: .behavioural
        )
        XCTAssertTrue(prompt.contains("Interaction mode: Behavioural"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("Do NOT include code or Mermaid unless the question explicitly asks"))
    }
}

final class PromptBuilderGlobalVoiceContractTests: XCTestCase {
    func testSolveSystemPromptIncludesVoiceCore() {
        let prompt = PromptBuilder.buildSystemPrompt(language: .swift)
        XCTAssertTrue(prompt.contains("Voice Core"))
        XCTAssertTrue(prompt.contains("Speak as the candidate"))
    }

    func testSystemDesignPromptIncludesVoiceCore() {
        let prompt = PromptBuilder.buildSystemDesignSystemPrompt()
        XCTAssertTrue(prompt.contains("Voice Core"))
        XCTAssertTrue(prompt.contains("Speak as the candidate"))
    }

    func testMLGuideSystemPromptIncludesVoiceCore() {
        let prompt = PromptBuilder.buildMLGuideSystemPrompt()
        XCTAssertTrue(prompt.contains("Voice Core"))
        XCTAssertTrue(prompt.contains("Speak as the candidate"))
    }
}

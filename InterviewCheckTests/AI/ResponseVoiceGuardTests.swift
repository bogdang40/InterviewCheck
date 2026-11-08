import XCTest
@testable import InterviewCheck

final class ResponseVoiceGuardTests: XCTestCase {
    private let guardrail = ResponseVoiceGuard()

    func testQuickAssistRewritesCoachingLanguageToFirstPerson() {
        let input = "You can say the tricky part is duplicate handling."

        let result = guardrail.normalizeText(input, surface: .quickAssist)

        XCTAssertTrue(result.report.coachingDetected)
        XCTAssertFalse(result.text.localizedCaseInsensitiveContains("you can say"))
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("i'd say"))
        XCTAssertTrue(result.report.firstPersonAfter)
        XCTAssertGreaterThan(result.report.rewriteCount, 0)
    }

    func testCodeAndMermaidBlocksArePreservedVerbatim() {
        let codeBlock = """
        ```swift
        // you should say this in code should stay untouched
        let value = 42
        ```
        """
        let mermaidBlock = """
        ```mermaid
        flowchart TD
            A --> B
        ```
        """
        let input = """
        You should mention the trade-off first.

        \(codeBlock)

        \(mermaidBlock)
        """

        let result = guardrail.normalizeText(input, surface: .quickAssist)

        XCTAssertTrue(result.text.contains(codeBlock))
        XCTAssertTrue(result.text.contains(mermaidBlock))
        XCTAssertFalse(result.text.localizedCaseInsensitiveContains("you should mention"))
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("i should mention"))
    }

    func testSystemDesignControlLinesRemainUnchanged() {
        let input = """
        ## System Design
        ### Step 1: API Gateway
        You should mention request throttling here.
        Builds-on: Baseline
        Diagram delta: Add Gateway
        Why now: We need a single ingress point
        Decision: Use stateless gateway
        Trade-off: Added network hop
        """

        let result = guardrail.normalizeText(input, surface: .systemDesign)

        XCTAssertTrue(result.text.contains("### Step 1: API Gateway"))
        XCTAssertTrue(result.text.contains("Builds-on: Baseline"))
        XCTAssertTrue(result.text.contains("Diagram delta: Add Gateway"))
        XCTAssertTrue(result.text.contains("Why now: We need a single ingress point"))
        XCTAssertTrue(result.text.contains("Decision: Use stateless gateway"))
        XCTAssertTrue(result.text.contains("Trade-off: Added network hop"))
        XCTAssertFalse(result.text.localizedCaseInsensitiveContains("you should mention"))
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("i should mention"))
    }

    func testInjectsFirstPersonLeadWhenMissing() {
        let input = "Use a hash map for O(1) lookup."

        let result = guardrail.normalizeText(input, surface: .solve)

        XCTAssertFalse(result.report.firstPersonBefore)
        XCTAssertTrue(result.report.firstPersonAfter)
        XCTAssertTrue(result.report.leadInjected)
        XCTAssertGreaterThan(result.report.rewriteCount, 0)
        // The rotated Solve lead pool produces one of four openers; all
        // contain an explicit first-person token so hasFirstPerson flips.
        let lowered = result.text.lowercased()
        let openedWithSolveLead =
            lowered.hasPrefix("okay, so the first thing i'm noticing is") ||
            lowered.hasPrefix("my instinct here is") ||
            lowered.hasPrefix("let me think through this.") ||
            lowered.hasPrefix("walking through it,")
        XCTAssertTrue(openedWithSolveLead, "Unexpected lead prefix: \(result.text)")
    }

    func testSayFirstOpenerLineIsImmutableOnQuickAssistSurface() {
        let sayFirstLine = "**Say first:** In order to frame this, the key idea is to start from the user."
        let input = """
        \(sayFirstLine)

        You should mention the tradeoff next.
        """

        let result = guardrail.normalizeText(input, surface: .quickAssist)

        XCTAssertTrue(result.text.contains(sayFirstLine), "The opener must stream through verbatim")
        XCTAssertFalse(result.text.localizedCaseInsensitiveContains("you should mention"))
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("i should mention"))
    }

    func testEverySolveLeadVariantIntroducesFirstPerson() {
        var selectedLeads = Set<String>()
        for keyCount in 1...4 {
            let input = "Use a map for \(keyCount) lookup keys."
            let lead = VoiceCore.contextualLead(for: .solve, existing: input)
            selectedLeads.insert(lead)

            let result = guardrail.normalizeText(input, surface: .solve)

            XCTAssertFalse(result.report.firstPersonBefore)
            XCTAssertTrue(result.report.leadInjected)
            XCTAssertTrue(result.report.firstPersonAfter, result.text)
            XCTAssertGreaterThan(result.report.rewriteCount, 0)
            XCTAssertEqual(result.text, lead + "use a map for \(keyCount) lookup keys.")
        }
        XCTAssertEqual(selectedLeads.count, 4, "The fixtures must exercise every Solve lead")
    }
}

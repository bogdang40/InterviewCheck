import XCTest
@testable import memanager

@MainActor
final class SessionControllerSystemDesignCacheTests: XCTestCase {
    private var controller: SessionController {
        SessionController.shared
    }

    override func setUp() {
        super.setUp()
        controller.resetSessionStateForTesting()
    }

    func testUpdateSessionResponseCachesParsedSystemDesignContent() {
        let response = MentorResponse(
            problem: "",
            clarifyingQuestions: "",
            implementation: "",
            tests: "",
            complexity: "",
            systemDesign: """
            ## System Design

            **Scalability:**
            ### Step 1: Baseline scale
            Start with horizontal app replicas behind a load balancer.
            Decision: Scale stateless app nodes first
            Trade-off: Requires shared cache/session state
            ```mermaid
            flowchart LR
                LB --> App1
                LB --> App2
            ```
            """
        )

        controller.updateSessionResponse(response)

        XCTAssertEqual(controller.session.response?.systemDesign, response.systemDesign)
        XCTAssertEqual(controller.parsedSystemDesignContent?.scalability?.steps.count, 1)
    }

    func testUpdateSessionResponseClearsCacheForNilOrMissingSystemDesign() {
        let responseWithSystemDesign = MentorResponse(
            problem: "",
            clarifyingQuestions: "",
            implementation: "",
            tests: "",
            complexity: "",
            systemDesign: """
            ## System Design
            **Scalability:**
            ### Step 1: Baseline scale
            Decision: Keep it simple
            Trade-off: Minimal optimization
            ```mermaid
            flowchart LR
                LB --> App
            ```
            """
        )

        controller.updateSessionResponse(responseWithSystemDesign)
        XCTAssertNotNil(controller.parsedSystemDesignContent)

        let responseWithoutSystemDesign = MentorResponse(
            problem: "p",
            clarifyingQuestions: "q",
            implementation: "i",
            tests: "t",
            complexity: "c",
            systemDesign: ""
        )

        controller.updateSessionResponse(responseWithoutSystemDesign)
        XCTAssertNil(controller.parsedSystemDesignContent)

        controller.updateSessionResponse(nil)
        XCTAssertNil(controller.parsedSystemDesignContent)
        XCTAssertNil(controller.session.response)
    }

    func testResetSessionClearsParsedSystemDesignCache() {
        let response = MentorResponse(
            problem: "",
            clarifyingQuestions: "",
            implementation: "",
            tests: "",
            complexity: "",
            systemDesign: """
            ## System Design
            **Scalability:**
            ### Step 1: Scale baseline
            Decision: Add replicas
            Trade-off: More ops overhead
            ```mermaid
            flowchart LR
                LB --> App1
                LB --> App2
            ```
            """
        )

        controller.updateSessionResponse(response)
        XCTAssertNotNil(controller.parsedSystemDesignContent)

        controller.resetSessionStateForTesting()
        XCTAssertNil(controller.parsedSystemDesignContent)
        XCTAssertNil(controller.session.response)
    }

    func testUpdateSessionResponseUsesPrecomputedParsedSystemDesign() {
        let response = MentorResponse(
            problem: "",
            clarifyingQuestions: "",
            implementation: "",
            tests: "",
            complexity: "",
            systemDesign: """
            ## System Design
            **Scalability:**
            ### Step 1: Real parse content
            Decision: This should be ignored by precomputed override
            Trade-off: test-only
            ```mermaid
            flowchart LR
                A --> B
            ```
            """
        )

        let precomputed = SystemDesignContent(
            requirements: nil,
            architecture: nil,
            components: [],
            componentSteps: [],
            dataFlow: nil,
            database: nil,
            apiDesign: nil,
            scalability: nil,
            tradeOffs: [],
            tradeOffSteps: [],
            rawContent: "precomputed-sentinel"
        )

        controller.updateSessionResponse(
            response,
            precomputedParsedSystemDesign: precomputed
        )

        XCTAssertEqual(controller.parsedSystemDesignContent?.rawContent, "precomputed-sentinel")
    }

    func testImplementationQuickAssistContextIncludesImplementationSections() {
        let response = MentorResponse(
            problem: "Find the longest valid segment.",
            clarifyingQuestions: "",
            implementation: "Use a sliding window with a frequency map.",
            tests: "Case A / Case B",
            complexity: "Time O(n), Space O(k)",
            systemDesign: ""
        )

        controller.updateSessionResponse(response)
        let context = controller.quickAssistSectionContextForTesting(mode: .implementationContext)

        XCTAssertTrue(context.contains("IMPLEMENTATION CONTEXT FROM PREVIOUS SOLVE"))
        XCTAssertTrue(context.contains("Problem:\nFind the longest valid segment."))
        XCTAssertTrue(context.contains("Implementation:\nUse a sliding window with a frequency map."))
        XCTAssertTrue(context.contains("Tests:\nCase A / Case B"))
        XCTAssertTrue(context.contains("Complexity:\nTime O(n), Space O(k)"))
    }

    func testSystemDesignQuickAssistContextIncludesStructuredAndRawFallbackContent() {
        let response = MentorResponse(
            problem: "",
            clarifyingQuestions: "",
            implementation: "",
            tests: "",
            complexity: "",
            systemDesign: "Raw design from the previous solve."
        )

        let precomputed = SystemDesignContent(
            requirements: nil,
            architecture: nil,
            components: [],
            componentSteps: [],
            dataFlow: nil,
            database: nil,
            apiDesign: nil,
            scalability: nil,
            tradeOffs: [],
            tradeOffSteps: [],
            rawContent: "Structured design content from parser."
        )

        controller.updateSessionResponse(
            response,
            precomputedParsedSystemDesign: precomputed
        )

        let context = controller.quickAssistSectionContextForTesting(mode: .systemDesignContext)
        XCTAssertTrue(context.contains("SYSTEM DESIGN CONTEXT FROM PREVIOUS SOLVE"))
        XCTAssertTrue(context.contains("Structured Design Context:\nStructured design content from parser."))
        XCTAssertTrue(context.contains("System Design:\nRaw design from the previous solve."))
    }

    func testAllSectionsQuickAssistContextIncludesAllAvailableSections() {
        let response = MentorResponse(
            problem: "Build a URL shortener.",
            clarifyingQuestions: "Expected QPS and retention?",
            implementation: "Hash + collision strategy.",
            tests: "Collision test and idempotency test.",
            complexity: "Read O(1), write O(1) average.",
            systemDesign: "Use cache + DB with replication."
        )
        let precomputed = SystemDesignContent(
            requirements: nil,
            architecture: nil,
            components: [],
            componentSteps: [],
            dataFlow: nil,
            database: nil,
            apiDesign: nil,
            scalability: nil,
            tradeOffs: [],
            tradeOffSteps: [],
            rawContent: "Structured architecture notes."
        )

        controller.updateSessionResponse(
            response,
            precomputedParsedSystemDesign: precomputed
        )
        let context = controller.quickAssistSectionContextForTesting(mode: .allSectionsContext)

        XCTAssertTrue(context.contains("ALL SECTIONS CONTEXT FROM PREVIOUS SOLVE"))
        XCTAssertTrue(context.contains("Problem:\nBuild a URL shortener."))
        XCTAssertTrue(context.contains("Clarifying Questions:\nExpected QPS and retention?"))
        XCTAssertTrue(context.contains("Implementation:\nHash + collision strategy."))
        XCTAssertTrue(context.contains("Tests:\nCollision test and idempotency test."))
        XCTAssertTrue(context.contains("Complexity:\nRead O(1), write O(1) average."))
        XCTAssertTrue(context.contains("Structured Design Context:\nStructured architecture notes."))
        XCTAssertTrue(context.contains("System Design:\nUse cache + DB with replication."))
    }

    func testQuickAssistSectionWarningsAppearWhenModeContextIsUnavailable() {
        controller.updateSessionResponse(nil)

        XCTAssertEqual(
            controller.quickAssistSectionWarningForTesting(mode: .implementationContext),
            "Implementation context unavailable. Trigger this mode after a previous implementation solve."
        )
        XCTAssertEqual(
            controller.quickAssistSectionWarningForTesting(mode: .systemDesignContext),
            "System-design context unavailable. Trigger this mode after a previous system-design solve."
        )
        XCTAssertEqual(
            controller.quickAssistSectionWarningForTesting(mode: .allSectionsContext),
            "All-sections context unavailable. Trigger this mode after a previous solve."
        )
        XCTAssertNil(controller.quickAssistSectionWarningForTesting(mode: .conversation))
    }

    func testQuickAssistContractStatusMessageIncludesModeAndDetailLevel() {
        let status = controller.quickAssistOutputContractStatusForTesting(
            mode: .allSectionsContext,
            contract: QuickAssistOutputContract(
                detailLevel: .detailed,
                enforceFirstPerson: true,
                responseShape: .structured,
                requiredElements: ["step_by_step"]
            )
        )

        XCTAssertTrue(status.contains("mode=allSectionsContext"))
        XCTAssertTrue(status.contains("detail=detailed"))
    }

    func testEvaluatePartialCommitAppliesForFirstStructuredSnapshot() {
        let candidate = SessionController.SystemDesignProgressSnapshot(
            sectionCount: 1,
            totalProgressiveStepCount: 2,
            hasStructuredContent: true,
            rawCharacterCount: 820
        )

        let decision = SessionController.evaluateSystemDesignPartialCommit(
            previous: nil,
            candidate: candidate,
            elapsedMs: 240,
            charDelta: 820
        )

        XCTAssertTrue(decision.shouldCommit)
        XCTAssertEqual(decision.reason, "first_structured_content")
        XCTAssertFalse(decision.isRegression)
    }

    func testEvaluatePartialCommitRejectsRegressingSnapshot() {
        let previous = SessionController.SystemDesignProgressSnapshot(
            sectionCount: 2,
            totalProgressiveStepCount: 5,
            hasStructuredContent: true,
            rawCharacterCount: 1400
        )
        let candidate = SessionController.SystemDesignProgressSnapshot(
            sectionCount: 1,
            totalProgressiveStepCount: 3,
            hasStructuredContent: true,
            rawCharacterCount: 1200
        )

        let decision = SessionController.evaluateSystemDesignPartialCommit(
            previous: previous,
            candidate: candidate,
            elapsedMs: 900,
            charDelta: -200
        )

        XCTAssertFalse(decision.shouldCommit)
        XCTAssertEqual(decision.reason, "regression_detected")
        XCTAssertTrue(decision.isRegression)
    }

    func testEvaluatePartialCommitAppliesRawThresholdWhenStillUnstructured() {
        let candidate = SessionController.SystemDesignProgressSnapshot(
            sectionCount: 0,
            totalProgressiveStepCount: 0,
            hasStructuredContent: false,
            rawCharacterCount: 680
        )

        let decision = SessionController.evaluateSystemDesignPartialCommit(
            previous: nil,
            candidate: candidate,
            elapsedMs: 1400,
            charDelta: 680
        )

        XCTAssertTrue(decision.shouldCommit)
        XCTAssertEqual(decision.reason, "raw_threshold_met")
        XCTAssertFalse(decision.isRegression)
    }
}

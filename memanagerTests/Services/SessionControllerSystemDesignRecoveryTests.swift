import XCTest
@testable import memanager

final class SessionControllerSystemDesignRecoveryTests: XCTestCase {
    func testCompletenessReportDetectsMissingSteps() {
        let response = MentorResponse(
            problem: "",
            clarifyingQuestions: "",
            implementation: "",
            tests: "",
            complexity: "",
            systemDesign: buildSystemDesignMarkdown(stepCounts: [
                "Requirements": 2,
                "High-Level Architecture": 1
            ])
        )

        let report = SessionController.buildSystemDesignCompletenessReport(
            for: response,
            recoveryAttempted: false
        )

        XCTAssertFalse(report.isComplete)
        XCTAssertEqual(report.status(for: "requirements")?.actualStepCount, 2)
        XCTAssertEqual(report.status(for: "architecture")?.actualStepCount, 1)
        XCTAssertEqual(report.status(for: "architecture")?.missingStepCount, 3)
        XCTAssertEqual(report.status(for: "components")?.actualStepCount, 0)
    }

    func testRecoveryMergeCanProduceCompleteReport() {
        let base = MentorResponse(
            problem: "",
            clarifyingQuestions: "",
            implementation: "",
            tests: "",
            complexity: "",
            systemDesign: "Draft notes with no structured sections yet."
        )
        let recovery = MentorResponse(
            problem: "",
            clarifyingQuestions: "",
            implementation: "",
            tests: "",
            complexity: "",
            // Derived from the blueprint so this fixture always covers
            // exactly what the prompt currently demands (it previously
            // hardcoded the pre v2 eight sections).
            systemDesign: buildSystemDesignMarkdown(stepCounts: Dictionary(
                uniqueKeysWithValues: SystemDesignBlueprint.promptActiveSections.map {
                    ($0.title, $0.expectedStepCount)
                }
            ))
        )

        let preReport = SessionController.buildSystemDesignCompletenessReport(
            for: base,
            recoveryAttempted: false
        )
        XCTAssertFalse(preReport.isComplete)

        let merged = SessionController.mergeSystemDesignRecovery(base: base, recovery: recovery)
        let postReport = SessionController.buildSystemDesignCompletenessReport(
            for: merged,
            recoveryAttempted: true
        )

        XCTAssertTrue(postReport.isComplete)
        XCTAssertTrue(merged.systemDesign.contains("Draft notes with no structured sections yet."))
        XCTAssertTrue(merged.systemDesign.contains("**High-Level Architecture:**"))
    }

    func testRecoveryMergeOverridesDuplicateStepNumbersWithLatestDefinition() {
        let base = MentorResponse(
            problem: "",
            clarifyingQuestions: "",
            implementation: "",
            tests: "",
            complexity: "",
            systemDesign: """
            ## System Design

            **High-Level Architecture:**
            ### Step 1: Baseline path
            Client routes through Gateway to CoreService.
            Builds-on: Baseline
            Diagram delta: Initial request path
            Why now: Establish a minimal working path first.
            Decision: Keep synchronous baseline
            Trade-off: Limited isolation under spikes
            ```mermaid
            flowchart LR
                CLIENT[Client] --> GATEWAY[Gateway] --> CORE[CoreService]
            ```
            ### Step 2: Old write path
            Route writes directly from Gateway to Database.
            Builds-on: Keep Gateway and CoreService from step 1
            Diagram delta: Add direct Database write edge
            Why now: Persist data quickly before queueing
            Decision: Old step 2 decision
            Trade-off: Tight coupling on write bursts
            ```mermaid
            flowchart LR
                CLIENT[Client] --> GATEWAY[Gateway] --> CORE[CoreService]
                GATEWAY --> DB[(Database)]
            ```
            """
        )
        let recovery = MentorResponse(
            problem: "",
            clarifyingQuestions: "",
            implementation: "",
            tests: "",
            complexity: "",
            systemDesign: """
            ## System Design

            **High-Level Architecture:**
            ### Step 2: Revised buffered writes
            Keep Gateway and CoreService, then add Queue for buffered writes.
            Builds-on: Gateway and CoreService from step 1
            Diagram delta: Replace direct Database write with Queue path
            Why now: absorb spikes before worker fanout
            Decision: Revised step 2 decision
            Trade-off: Higher write latency, better stability
            ```mermaid
            flowchart LR
                CLIENT[Client] --> GATEWAY[Gateway] --> CORE[CoreService]
                GATEWAY --> QUEUE[Queue]
            ```
            ### Step 3: Worker execution
            Keep Queue and add Worker consumers.
            Builds-on: Queue path from step 2
            Diagram delta: Add Worker after Queue
            Why now: decouple ingress from processing
            Decision: Add workers behind queue
            Trade-off: More operational moving parts
            ```mermaid
            flowchart LR
                CLIENT[Client] --> GATEWAY[Gateway] --> CORE[CoreService]
                GATEWAY --> QUEUE[Queue] --> WORKER[Worker]
            ```
            ### Step 4: Dead-letter handling
            Keep Queue and Worker and add DLQ for poison messages.
            Builds-on: Queue and Worker from step 3
            Diagram delta: Add DLQ branch from Queue
            Why now: isolate failed events without blocking normal traffic
            Decision: Add DLQ branch
            Trade-off: Additional observability and ops overhead
            ```mermaid
            flowchart LR
                CLIENT[Client] --> GATEWAY[Gateway] --> CORE[CoreService]
                GATEWAY --> QUEUE[Queue] --> WORKER[Worker]
                QUEUE --> DLQ[DLQ]
            ```
            """
        )

        let merged = SessionController.mergeSystemDesignRecovery(base: base, recovery: recovery)
        let parsed = SectionParser.parseSystemDesign(merged.systemDesign)
        let architectureSteps = parsed.architecture?.steps ?? []

        XCTAssertEqual(architectureSteps.count, 4)
        XCTAssertEqual(architectureSteps[1].decision, "Revised step 2 decision")
        XCTAssertTrue(architectureSteps[1].wasOverriddenDuringMerge)
        XCTAssertEqual(architectureSteps[3].title, "Dead-letter handling")
    }

    func testCompletenessReportFlagsCoherenceIssuesAfterReplacement() {
        let completeBaseline = buildSystemDesignMarkdown(stepCounts: [
            "Requirements": 2,
            "High-Level Architecture": 4,
            "Components": 3,
            "Data Flow": 3,
            "Database Design": 3,
            "API Design": 3,
            "Scalability": 3,
            "Trade-offs": 2
        ])

        let incoherentReplacement = """
        **High-Level Architecture:**
        ### Step 2: Abrupt rewrite
        This paragraph avoids naming concrete system elements and does not explain continuity.
        Decision: Keep policy-first abstraction
        Trade-off: Harder to trace runtime path
        ```mermaid
        flowchart LR
            CLIENT[Client] --> GATEWAY[Gateway] --> QUEUE[Queue]
        ```
        """

        let response = MentorResponse(
            problem: "",
            clarifyingQuestions: "",
            implementation: "",
            tests: "",
            complexity: "",
            systemDesign: completeBaseline + "\n\n" + incoherentReplacement
        )

        let report = SessionController.buildSystemDesignCompletenessReport(
            for: response,
            recoveryAttempted: true
        )
        let architectureStatus = report.status(for: "architecture")

        XCTAssertNotNil(architectureStatus)
        XCTAssertEqual(architectureStatus?.actualStepCount, 4)
        XCTAssertFalse(architectureStatus?.coherenceIssues.isEmpty ?? true)
        XCTAssertFalse(report.isComplete)
    }
}

private extension SessionControllerSystemDesignRecoveryTests {
    func buildSystemDesignMarkdown(stepCounts: [String: Int]) -> String {
        let ordered: [(title: String, key: String)] = SystemDesignBlueprint.promptActiveSections.map {
            ($0.title, $0.id.lowercased())
        }

        var sections: [String] = ["## System Design"]
        for (title, key) in ordered {
            let count = stepCounts[title] ?? 0
            guard count > 0 else { continue }
            sections.append("**\(title):**")
            for step in 1...count {
                sections.append(
                    """
                    ### Step \(step): \(title) step \(step)
                    Extend \(title.lowercased()) incrementally for step \(step).
                    Decision: Keep \(key) decision \(step)
                    Trade-off: Accept \(key) tradeoff \(step)
                    ```mermaid
                    flowchart LR
                        \(key.uppercased())\(step)A[\(title) \(step) A] --> \(key.uppercased())\(step)B[\(title) \(step) B]
                    ```
                    """
                )
            }
        }

        return sections.joined(separator: "\n\n")
    }
}

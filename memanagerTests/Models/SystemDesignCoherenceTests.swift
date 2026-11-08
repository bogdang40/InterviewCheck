import XCTest
@testable import memanager

final class SystemDesignCoherenceTests: XCTestCase {
    func testRecoveryIncludesIssuesFromLaterStepsUpToTen() throws {
        let steps = (1...12).map { number in
            """
            ### Step \(number): Evaluate choice
            Unrelated reasoning about bananas.
            Decision: Choose oranges.
            ```mermaid
            flowchart LR
                CLIENT[Client] --> GATEWAY[Gateway]
            ```
            """
        }.joined(separator: "\n\n")
        let content = SectionParser.parseSystemDesign("## System Design\n\n**High-Level Architecture:**\n" + steps)
        let report = SystemDesignCompletenessReport.from(content: content, recoveryAttempted: false)
        let issues = try XCTUnwrap(report.status(for: "architecture")).coherenceIssues
        XCTAssertEqual(issues.count, 10)
        XCTAssertTrue(issues.contains { $0.contains("Step 4") })
    }

    func testCoherenceUsesMermaidIdentifiersForFlowSequenceAndER() {
        let coherentText = """
        ## System Design

        **High-Level Architecture:**
        ### Step 1: Flow baseline
        Client sends traffic to Gateway and then CoreService.
        Decision: Keep Client and Gateway path
        Trade-off: Simple first pass
        ```mermaid
        flowchart LR
            CLIENT[Client] --> GATEWAY[Gateway] --> CORE[CoreService]
        ```

        **Data Flow:**
        ### Step 1: Request sequence
        Client calls Gateway, and Gateway forwards to Service.
        Decision: Validate at Gateway first
        Trade-off: Slight per-call overhead
        ```mermaid
        sequenceDiagram
            participant C as Client
            participant G as Gateway
            participant S as Service
            C->>G: request
            G->>S: forwarded request
            S-->>G: response
            G-->>C: response
        ```

        **Database Design:**
        ### Step 1: Entity baseline
        User places Order records in relational storage.
        Decision: Keep User and Order normalized
        Trade-off: More joins on reads
        ```mermaid
        erDiagram
            USER ||--o{ ORDER : places
        ```
        """

        let coherentParsed = SectionParser.parseSystemDesign(coherentText)
        let coherentReport = SystemDesignCompletenessReport.from(
            content: coherentParsed,
            recoveryAttempted: false
        )

        XCTAssertTrue(coherentReport.status(for: "architecture")?.coherenceIssues.isEmpty == true)
        XCTAssertTrue(coherentReport.status(for: "dataFlow")?.coherenceIssues.isEmpty == true)
        XCTAssertTrue(coherentReport.status(for: "database")?.coherenceIssues.isEmpty == true)

        let mismatchText = """
        ## System Design

        **High-Level Architecture:**
        ### Step 1: Mismatch
        This paragraph intentionally avoids naming any concrete system nodes.
        Decision: Keep strategy vague
        Trade-off: Hard to verify visually
        ```mermaid
        flowchart LR
            CLIENT[Client] --> GATEWAY[Gateway] --> CORE[CoreService]
        ```
        """

        let mismatchParsed = SectionParser.parseSystemDesign(mismatchText)
        let mismatchReport = SystemDesignCompletenessReport.from(
            content: mismatchParsed,
            recoveryAttempted: false
        )
        let issues = mismatchReport.status(for: "architecture")?.coherenceIssues ?? []
        XCTAssertTrue(issues.contains { $0.contains("text does not reference diagram elements") })
    }

}

import XCTest
@testable import memanager

/// Regression tests for the SD0 system design section fixes.
final class SystemDesignSectionFixTests: XCTestCase {
    private func stepBlock(number: Int, title: String, body: String) -> String {
        """
        ### Step \(number): \(title)
        \(body)
        Decision: keep it simple
        ```mermaid
        flowchart TD
            A\(number) --> B\(number)
        ```
        """
    }

    func testScalabilityStepsAreNotDuplicatedAsStrategies() {
        let text = """
        **Scalability:**
        \(stepBlock(number: 1, title: "Baseline load", body: "One server handles A1 traffic."))

        \(stepBlock(number: 2, title: "Horizontal scale", body: "Add replicas beside A2."))
        """

        let content = SystemDesignSectionParser.parseSystemDesign(text)

        XCTAssertEqual(content.scalability?.steps.count, 2)
        let strategyNames = content.scalability?.strategies.map(\.name) ?? []
        XCTAssertFalse(
            strategyNames.contains { $0.lowercased().hasPrefix("step ") },
            "Step headers must not leak into strategies (they rendered the whole step body, mermaid source included, a second time): \(strategyNames)"
        )
    }

    func testSingularTradeOffHeaderIsNotSilentlyDropped() {
        let text = """
        **Trade-off:**
        \(stepBlock(number: 1, title: "Consistency choice", body: "Favor availability over strict A1 consistency."))
        """

        let content = SystemDesignSectionParser.parseSystemDesign(text)

        XCTAssertEqual(content.tradeOffSteps.count, 1,
                       "A singular Trade-off header was a recognized block boundary but not a query alias: the whole section vanished")
    }

    func testRequirementsFallbackIgnoresStepProseBullets() {
        let text = """
        **Requirements:**
        - Support ten thousand users
        - Keep reads under 100 ms

        \(stepBlock(number: 1, title: "Scope", body: "- this step bullet is prose, not a requirement"))
        """

        let content = SystemDesignSectionParser.parseSystemDesign(text)

        let functional = content.requirements?.functional ?? []
        XCTAssertTrue(functional.contains { $0.contains("ten thousand users") })
        XCTAssertFalse(
            functional.contains { $0.contains("step bullet is prose") },
            "Bullets inside step prose must not be promoted to Functional requirements"
        )
    }

    func testBoldEmphasisWithoutColonIsNotATable() {
        let text = """
        **Database Design:**
        This design is **absolutely** critical.

        **Users**: id INTEGER, name TEXT

        \(stepBlock(number: 1, title: "Schema", body: "Model the Users table."))
        """

        let content = SystemDesignSectionParser.parseSystemDesign(text)

        let tableNames = content.database?.tables.map(\.name) ?? []
        XCTAssertTrue(tableNames.contains("Users"))
        XCTAssertFalse(tableNames.contains("absolutely"),
                       "Bold emphasis words must not become database tables")
    }
}

final class SystemDesignChecklistParserTests: XCTestCase {
    func testChecklistIsNotPartOfSpokenWrapUpAndRawAuditRemainsAvailable() throws {
        let spoken = "Keep the cache beside the service and add replicas when reads grow."
        for heading in ["### Step 1: Final architecture\n", ""] {
            for checklist in ["COMPLETION_CHECKLIST: Wrap-Up=1", "COMPLETION_CHECKLIST: Wrap-Up="] {
                let text = """
                **Wrap-Up:**
                \(heading)\(spoken)
                Decision: Scale the read tier first
                ```mermaid
                flowchart LR
                    Client --> Service
                ```

                \(checklist)
                """
                let content = SystemDesignSectionParser.parseSystemDesign(text)
                let step = try XCTUnwrap(content.wrapUp?.steps.first)
                XCTAssertEqual(step.reasoning, spoken)
                XCTAssertEqual(step.decision, "Scale the read tier first")
                XCTAssertEqual(content.rawContent, text)
            }
        }
    }

    func testChecklistMetadataIsRemovedAcrossAppendedRecoverySections() {
        let text = """
        Original spoken wrap-up.
        COMPLETION_CHECKLIST: Wrap-Up=1

        Recovered spoken wrap-up.
        COMPLETION_CHECKLIST:
        """
        XCTAssertEqual(SystemDesignChecklistParser.removingMetadataLines(from: text),
                       "Original spoken wrap-up.\n\nRecovered spoken wrap-up.")
    }

    func testChecklistMentionsAndCodeExamplesRemainUnchanged() {
        let text = """
        Explain COMPLETION_CHECKLIST: Wrap-Up=1 as an audit field.
        > COMPLETION_CHECKLIST: Wrap-Up=1
            COMPLETION_CHECKLIST: Wrap-Up=1
        ````text
        COMPLETION_CHECKLIST: Wrap-Up=1
        ```
        COMPLETION_CHECKLIST: Wrap-Up=1
        ````
        ~~~text
        COMPLETION_CHECKLIST: Wrap-Up=1
        ~~~
        """
        XCTAssertEqual(SystemDesignChecklistParser.removingMetadataLines(from: text), text)
    }

    func testParsesDeclaredCounts() {
        let text = """
        design body here
        COMPLETION_CHECKLIST: Requirements=2, High-Level Architecture=4, Trade-offs=2
        """

        let declared = SystemDesignChecklistParser.parse(text)

        XCTAssertEqual(declared["Requirements"], 2)
        XCTAssertEqual(declared["High-Level Architecture"], 4)
        XCTAssertEqual(declared["Trade-offs"], 2)
    }

    func testMissingMarkerYieldsEmpty() {
        XCTAssertTrue(SystemDesignChecklistParser.parse("no checklist here").isEmpty)
    }

    func testMismatchesReportDisagreementsOnly() {
        let mismatches = SystemDesignChecklistParser.mismatches(
            declared: ["Requirements": 2, "Components": 3],
            actualBySectionTitle: ["Requirements": 2, "Components": 1]
        )

        XCTAssertEqual(mismatches, ["Components: declared 3, parsed 1"])
    }
}

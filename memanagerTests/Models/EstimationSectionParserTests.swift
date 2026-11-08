import XCTest
@testable import memanager

final class EstimationSectionParserTests: XCTestCase {
    func testParsesMetricRowsWithValuesAndFormulas() {
        let text = """
        **Estimation:**
        - DAU: 150M
        - Write QPS: about 3,500 (150M x 2 / 86,400)
        - Peak QPS: 7,000 (2x average)
        - Storage per day: 30 TB (150M x 2 x 10% x 1MB)

        ### Step 1: Traffic math
        Start from daily actives and derive write pressure on S1.
        Decision: size for peak
        ```mermaid
        flowchart TD
            S1[Server] --> DB
        ```
        """

        let block = EstimationSectionParser.parseEstimation(from: text)

        let metrics = block?.metrics ?? []
        XCTAssertEqual(block?.steps.count, 1)
        XCTAssertTrue(metrics.contains { $0.name == "DAU" && $0.value == "150M" })
        let writeQPS = metrics.first { $0.name == "Write QPS" }
        XCTAssertEqual(writeQPS?.formula, "150M x 2 / 86,400")
        XCTAssertTrue(metrics.contains { $0.name == "Storage per day" })
    }

    func testStepControlLinesAndDiagramLabelsAreNotMetrics() {
        let text = """
        **Estimation:**
        - Read QPS: 350,000 (100:1 read write ratio)

        ### Step 1: Baseline
        Reads dominate this workload on R1.
        Builds-on: Baseline
        Diagram delta: add read path
        Why now: reads dominate
        Decision: cache first
        Trade-off: staleness window
        ```mermaid
        flowchart TD
            R1[Reader] --> C1[Cache: 20%]
        ```
        """

        let metrics = EstimationSectionParser.parseEstimation(from: text)?.metrics ?? []

        let names = Set(metrics.map { $0.name.lowercased() })
        XCTAssertTrue(names.contains("read qps"))
        XCTAssertFalse(names.contains("decision"))
        XCTAssertFalse(names.contains("builds-on"))
        XCTAssertFalse(names.contains("diagram delta"))
        XCTAssertFalse(names.contains { $0.contains("c1") }, "Diagram labels must not become metrics")
    }

    func testProseColonsWithoutNumbersAreNotMetrics() {
        let metrics = EstimationSectionParser.parseMetrics(from: "Key idea: keep it simple\nDAU: 10M")

        XCTAssertEqual(metrics.count, 1)
        XCTAssertEqual(metrics.first?.name, "DAU")
    }

    func testV1ResponsesWithoutEstimationParseToNil() {
        let v1Text = """
        **Requirements:**
        ### Step 1: Scope
        Define the S1 scope.
        Decision: narrow scope
        ```mermaid
        flowchart TD
            S1 --> B
        ```
        """

        let content = SystemDesignSectionParser.parseSystemDesign(v1Text)

        XCTAssertNil(content.estimation, "v1 shaped output must keep parsing with the new sections absent")
        XCTAssertNil(content.wrapUp)
        XCTAssertEqual(content.requirements?.steps.count, 1)
    }

    func testWrapUpSectionParsesWhenEmitted() {
        let text = """
        **Wrap-Up:**
        ### Step 1: Final architecture
        The full picture keeps W1 and adds observability.
        Decision: ship it
        ```mermaid
        flowchart TD
            W1[Gateway] --> M[Metrics]
        ```
        """

        let content = SystemDesignSectionParser.parseSystemDesign(text)

        XCTAssertEqual(content.wrapUp?.steps.count, 1)
        XCTAssertEqual(content.progressiveStepCount(for: "wrapUp"), 1)
    }

    func testActivatedSectionsAppearInPromptArtifacts() {
        XCTAssertTrue(SystemDesignBlueprint.promptSectionContract.contains("**Estimation:**"))
        XCTAssertTrue(SystemDesignBlueprint.promptSectionContract.contains("**Wrap-Up:**"))
        XCTAssertTrue(SystemDesignBlueprint.completionChecklistLine.contains("Estimation=2"))
        XCTAssertTrue(SystemDesignBlueprint.completionChecklistLine.contains("Wrap-Up=1"))
        XCTAssertTrue(SystemDesignSectionExpectation.all.contains { $0.id == "estimation" })
        XCTAssertTrue(SystemDesignSectionExpectation.all.contains { $0.id == "wrapUp" })
    }
}

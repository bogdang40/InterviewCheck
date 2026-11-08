import XCTest
@testable import memanager

/// The narration resolvers: diagram tokens, the derived step context, and
/// the spoken script. These freeze the wording the user reads aloud.
final class DesignStepNarrationTests: XCTestCase {
    private func step(_ number: Int, title: String, decision: String, diagram: String, tradeOff: String? = nil, buildsOn: String? = nil, diagramDelta: String? = nil, whyNow: String? = nil, overridden: Bool = false) -> ProgressiveDesignStep {
        ProgressiveDesignStep(
            number: number,
            title: title,
            reasoning: "Reasoning for \(title).",
            decision: decision,
            tradeOff: tradeOff,
            buildsOn: buildsOn,
            diagramDelta: diagramDelta,
            whyNow: whyNow,
            wasOverriddenDuringMerge: overridden,
            mermaidDiagram: diagram
        )
    }

    func testTokenizerDropsStopWordsAndShortTokens() {
        let tokens = DesignDiagramTokenizer.tokens(in: "flowchart LR\n C[Client] --> G[Gateway]\n G --> DB")

        XCTAssertTrue(tokens.contains("client"))
        XCTAssertTrue(tokens.contains("gateway"))
        XCTAssertFalse(tokens.contains("flowchart"))
        XCTAssertFalse(tokens.contains("db"))
    }

    func testDeltaSeparatesKeptAndAdded() {
        let delta = DesignDiagramTokenizer.delta(from: "flowchart LR\n Client --> Gateway", to: "flowchart LR\n Client --> Gateway --> Cache")

        XCTAssertEqual(delta.kept, ["client", "gateway"])
        XCTAssertEqual(delta.added, ["cache"])
    }

    func testFirstStepWithoutExplicitFieldsHasNoContextRows() {
        let first = step(1, title: "Baseline", decision: "Start simple", diagram: "flowchart LR\n A --> B")
        let context = DesignStepContextResolver.context(for: first, previous: nil)

        XCTAssertTrue(context.rows.isEmpty)
    }

    func testExplicitFieldsWinAndTradeOffDrivesWhyNow() {
        let first = step(1, title: "Baseline", decision: "Start simple", diagram: "flowchart LR\n Client --> Gateway", tradeOff: "One more hop", buildsOn: "Baseline", diagramDelta: "Client and gateway")
        let context = DesignStepContextResolver.context(for: first, previous: nil)

        XCTAssertEqual(context.rows.map(\.label), ["Builds on", "Diagram delta", "Why now"])
        XCTAssertEqual(context.buildsOn, "Baseline")
        XCTAssertEqual(context.whyNow, "Needed now to manage the trade off: One more hop")
    }

    func testDerivedContextComesFromThePreviousStep() {
        let first = step(1, title: "Baseline", decision: "Start simple", diagram: "flowchart LR\n Client --> Gateway")
        let second = step(2, title: "Add cache", decision: "Cache reads", diagram: "flowchart LR\n Client --> Gateway --> Cache", tradeOff: "None", overridden: true)
        let context = DesignStepContextResolver.context(for: second, previous: first)

        XCTAssertEqual(context.buildsOn, "Step 1, Baseline, which decided: Start simple")
        XCTAssertEqual(context.diagramDelta, "Keeps client, gateway and adds cache")
        XCTAssertNil(context.whyNow, "A literal None trade off must not become a why now line")
        XCTAssertEqual(context.rows.last?.label, "Recovery")
        XCTAssertNil(DesignStepContextResolver.meaningfulTradeOff("none"))
    }

    func testScriptPreservesAnswerFactsWithoutPresentationMetadata() {
        let section = DesignSectionCatalog.section(id: "architecture")!
        let first = step(1, title: "Baseline", decision: "Start simple", diagram: "flowchart LR\n Client --> Gateway", diagramDelta: "Client and gateway")
        let second = step(2, title: "Add cache", decision: "Cache reads", diagram: "flowchart LR\n Client --> Gateway --> Cache", tradeOff: "Stale reads", buildsOn: "Previous section", whyNow: "Parser context", overridden: true)

        let script = DesignScriptComposer.script(section: section, steps: [first, second], stepIndex: 1)
        XCTAssertTrue(script.contains("Reasoning for Add cache."))
        XCTAssertTrue(script.contains("Cache reads."))
        XCTAssertTrue(script.contains("Stale reads."))
        for metadata in ["we are on step", "Diagram delta", "Builds on", "Why now", "Recovery", "Parser context", "Previous section"] {
            XCTAssertFalse(script.contains(metadata), "Internal presentation metadata must stay out of candidate speech")
        }
        XCTAssertFalse(script.contains("Reasoning for Baseline"), "Only the selected step is spoken")
        XCTAssertEqual(DesignScriptComposer.script(section: section, steps: [first, second], stepIndex: 99), script)
        XCTAssertTrue(DesignScriptComposer.script(section: section, steps: [], stepIndex: 0).isEmpty)
    }

    func testSentenceAndLeadHelpers() {
        XCTAssertEqual(DesignScriptComposer.sentence("Adds cache"), "Adds cache.")
        XCTAssertEqual(DesignScriptComposer.sentence("Done!"), "Done!")
        XCTAssertEqual(DesignScriptComposer.leadLowercased("Adds cache"), "adds cache")
        XCTAssertEqual(DesignScriptComposer.leadLowercased("API gateway first"), "API gateway first")
        XCTAssertEqual(DesignScriptComposer.leadLowercased(""), "")
    }
}

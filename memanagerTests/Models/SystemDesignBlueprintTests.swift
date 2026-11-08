import XCTest
@testable import memanager

/// The blueprint is the single source of truth for the system design
/// taxonomy: these tests pin that every derived artifact (prompt contract,
/// checklist line, expectations table, parser aliases) stays consistent
/// with it and with the frozen prompt landmarks.
final class SystemDesignBlueprintTests: XCTestCase {
    func testGeneratedChecklistLineMatchesTheFrozenPromptString() {
        XCTAssertEqual(
            SystemDesignBlueprint.completionChecklistLine,
            "COMPLETION_CHECKLIST: Requirements=2, Estimation=2, High-Level Architecture=4, Components=3, Data Flow=3, Database Design=3, API Design=3, Scalability=3, Trade-offs=2, Wrap-Up=1"
        )
    }

    func testGeneratedSectionContractContainsEveryActiveHeaderAndBudget() {
        let contract = SystemDesignBlueprint.promptSectionContract

        for section in SystemDesignBlueprint.promptActiveSections {
            XCTAssertTrue(contract.contains("**\(section.title):**"), section.title)
            XCTAssertTrue(
                contract.contains("**\(section.title):**\nUse exactly \(section.expectedStepCount) progressive steps."),
                "Budget line must directly follow \(section.title)"
            )
        }
        for section in SystemDesignBlueprint.sections where !section.isPromptActive {
            XCTAssertFalse(contract.contains("**\(section.title):**"),
                           "\(section.title) is not prompt active and must stay out of the contract")
        }
    }

    func testExpectationsDeriveFromPromptActiveSections() {
        let active = SystemDesignBlueprint.promptActiveSections
        XCTAssertEqual(SystemDesignSectionExpectation.all.count, active.count)
        for (expectation, section) in zip(SystemDesignSectionExpectation.all, active) {
            XCTAssertEqual(expectation.id, section.id)
            XCTAssertEqual(expectation.title, section.title)
            XCTAssertEqual(expectation.expectedStepCount, section.expectedStepCount)
        }
    }

    func testSectionIDsAreUniqueAndAliasesIncludeCanonicalTitle() {
        let ids = SystemDesignBlueprint.sections.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Section ids must be unique")

        for section in SystemDesignBlueprint.sections {
            XCTAssertTrue(section.aliases.contains(section.title),
                          "\(section.id): the canonical title must be an accepted alias")
            XCTAssertFalse(section.icon.isEmpty)
            XCTAssertGreaterThan(section.expectedStepCount, 0)
        }
    }

    func testSystemPromptEmbedsTheGeneratedArtifacts() {
        let prompt = PromptBuilder.buildSystemDesignSystemPrompt()

        XCTAssertTrue(prompt.contains(SystemDesignBlueprint.promptSectionContract))
        XCTAssertTrue(prompt.contains(SystemDesignBlueprint.completionChecklistLine))
    }
}

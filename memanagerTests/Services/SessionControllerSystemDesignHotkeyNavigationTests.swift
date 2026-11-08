import XCTest
@testable import memanager

@MainActor
final class SessionControllerSystemDesignHotkeyNavigationTests: XCTestCase {
    private var controller: SessionController {
        SessionController.shared
    }

    override func setUp() {
        super.setUp()
        controller.resetSessionStateForTesting()
    }

    func testNextDesignHotkeyAdvancesWithinCurrentSection() {
        setParsedSystemDesignContent(requirementsSteps: 2, architectureSteps: 2)
        controller.currentSection = .systemDesign
        controller.systemDesignSectionIndex = 0
        controller.setSystemDesignStepIndex(0, for: "requirements", stepCount: 2)

        controller.nextSystemDesignProgressiveStepByHotkey()

        XCTAssertEqual(controller.systemDesignSectionIndex, 0)
        XCTAssertEqual(controller.systemDesignStepIndex(for: "requirements", stepCount: 2), 1)
    }

    func testNextDesignHotkeyCrossesToNextSectionAtSectionEnd() {
        setParsedSystemDesignContent(requirementsSteps: 1, architectureSteps: 2)
        controller.currentSection = .systemDesign
        controller.systemDesignSectionIndex = 0
        controller.setSystemDesignStepIndex(0, for: "requirements", stepCount: 1)

        controller.nextSystemDesignProgressiveStepByHotkey()

        XCTAssertEqual(controller.systemDesignSectionIndex, 1)
        XCTAssertEqual(controller.systemDesignStepIndex(for: "architecture", stepCount: 2), 0)
    }

    func testPreviousDesignHotkeyMovesBackwardWithinCurrentSection() {
        setParsedSystemDesignContent(requirementsSteps: 2, architectureSteps: 2)
        controller.currentSection = .systemDesign
        controller.systemDesignSectionIndex = 1
        controller.setSystemDesignStepIndex(1, for: "architecture", stepCount: 2)

        controller.previousSystemDesignProgressiveStepByHotkey()

        XCTAssertEqual(controller.systemDesignSectionIndex, 1)
        XCTAssertEqual(controller.systemDesignStepIndex(for: "architecture", stepCount: 2), 0)
    }

    func testPreviousDesignHotkeyCrossesToPreviousSectionAtSectionStart() {
        setParsedSystemDesignContent(requirementsSteps: 2, architectureSteps: 3)
        controller.currentSection = .systemDesign
        controller.systemDesignSectionIndex = 1
        controller.setSystemDesignStepIndex(0, for: "architecture", stepCount: 3)
        controller.setSystemDesignStepIndex(0, for: "requirements", stepCount: 2)

        controller.previousSystemDesignProgressiveStepByHotkey()

        XCTAssertEqual(controller.systemDesignSectionIndex, 0)
        XCTAssertEqual(controller.systemDesignStepIndex(for: "requirements", stepCount: 2), 1)
    }

    func testPreviousDesignHotkeyNoOpAtFirstOverallStep() {
        setParsedSystemDesignContent(requirementsSteps: 2, architectureSteps: 2)
        controller.currentSection = .systemDesign
        controller.systemDesignSectionIndex = 0
        controller.setSystemDesignStepIndex(0, for: "requirements", stepCount: 2)

        controller.previousSystemDesignProgressiveStepByHotkey()

        XCTAssertEqual(controller.systemDesignSectionIndex, 0)
        XCTAssertEqual(controller.systemDesignStepIndex(for: "requirements", stepCount: 2), 0)
    }

    func testNextDesignHotkeyNoOpAtLastOverallStep() {
        setParsedSystemDesignContent(requirementsSteps: 2, architectureSteps: 2)
        controller.currentSection = .systemDesign
        controller.systemDesignSectionIndex = 1
        controller.setSystemDesignStepIndex(1, for: "architecture", stepCount: 2)

        controller.nextSystemDesignProgressiveStepByHotkey()

        XCTAssertEqual(controller.systemDesignSectionIndex, 1)
        XCTAssertEqual(controller.systemDesignStepIndex(for: "architecture", stepCount: 2), 1)
    }

    func testDesignHotkeysNoOpOutsideSystemDesignSection() {
        setParsedSystemDesignContent(requirementsSteps: 2, architectureSteps: 2)
        controller.currentSection = .implementation
        controller.systemDesignSectionIndex = 0
        controller.setSystemDesignStepIndex(0, for: "requirements", stepCount: 2)

        controller.nextSystemDesignProgressiveStepByHotkey()
        controller.previousSystemDesignProgressiveStepByHotkey()

        XCTAssertEqual(controller.systemDesignSectionIndex, 0)
        XCTAssertEqual(controller.systemDesignStepIndex(for: "requirements", stepCount: 2), 0)
    }

    func testDesignHotkeysNoOpWhenParsedSystemDesignContentMissing() {
        controller.resetSessionStateForTesting()
        controller.currentSection = .systemDesign
        controller.systemDesignSectionIndex = 0

        controller.nextSystemDesignProgressiveStepByHotkey()
        controller.previousSystemDesignProgressiveStepByHotkey()

        XCTAssertEqual(controller.systemDesignSectionIndex, 0)
        XCTAssertTrue(controller.systemDesignStepIndexBySection.isEmpty)
    }
}

private extension SessionControllerSystemDesignHotkeyNavigationTests {
    func setParsedSystemDesignContent(requirementsSteps: Int, architectureSteps: Int) {
        let content = SystemDesignContent(
            requirements: requirementsSteps > 0 ? RequirementsBlock(
                functional: [],
                nonFunctional: [],
                assumptions: [],
                steps: makeSteps(prefix: "Requirements", count: requirementsSteps)
            ) : nil,
            architecture: architectureSteps > 0 ? ArchitectureBlock(
                description: "",
                mermaidDiagram: nil,
                steps: makeSteps(prefix: "Architecture", count: architectureSteps)
            ) : nil,
            components: [],
            componentSteps: [],
            dataFlow: nil,
            database: nil,
            apiDesign: nil,
            scalability: nil,
            tradeOffs: [],
            tradeOffSteps: [],
            rawContent: "stub"
        )
        let response = MentorResponse(
            problem: "",
            clarifyingQuestions: "",
            implementation: "",
            tests: "",
            complexity: "",
            systemDesign: "stub"
        )
        controller.updateSessionResponse(
            response,
            precomputedParsedSystemDesign: content
        )
    }

    func makeSteps(prefix: String, count: Int) -> [ProgressiveDesignStep] {
        guard count > 0 else { return [] }
        return (1...count).map { number in
            ProgressiveDesignStep(
                number: number,
                title: "\(prefix) \(number)",
                reasoning: "",
                decision: "Decision \(number)",
                mermaidDiagram: "flowchart LR\nA --> B"
            )
        }
    }
}

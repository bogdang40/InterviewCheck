import XCTest
@testable import memanager

final class ProjectToolPromptContractTests: XCTestCase {
    func testLoopInputsIncludeRootContractInSystemAndUserPrompts() {
        let rootDescriptor = ProjectToolRootDescriptor(rootName: "Mariana", displayPath: "/Users/abekhadra/Desktop/Mariana")
        let context = QuickAssistContext(
            transcript: "Please inspect the repo",
            screenshots: [],
            question: "What is affected?",
            extraContext: "",
            realtimePrompt: ""
        )

        let values = ProjectToolLoopInputs.derive(from: context, rootDescriptor: rootDescriptor)

        XCTAssertEqual(values.rootDescriptor, rootDescriptor)
        XCTAssertTrue(values.systemPrompt.contains("Selected project root: Mariana at /Users/abekhadra/Desktop/Mariana"))
        XCTAssertTrue(values.systemPrompt.contains(#"list_directory(path: "")"#))
        XCTAssertTrue(values.systemPrompt.contains("Before every tool call, write one or two short sentences"))
        XCTAssertTrue(values.systemPrompt.contains("Prefer sequential, purposeful tool calls"))
        XCTAssertTrue(values.userPromptText.contains("Project root reminder"))
        XCTAssertTrue(values.userPromptText.contains("Use project relative paths only"))
        XCTAssertTrue(values.promptContract.forcedToolRecoveryReminder.contains("Forced tools are still required"))
        XCTAssertTrue(values.promptContract.synthesisReminder.contains("answer the user directly using those findings"))
        XCTAssertTrue(values.promptContract.synthesisReminder.contains("line references"))
        XCTAssertTrue(values.promptContract.synthesisReminder.contains("diff block"))
    }
}

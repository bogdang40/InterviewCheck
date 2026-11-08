import XCTest
@testable import memanager

final class ProjectToolLoopRunnerTests: XCTestCase {
    private var fixture: ProjectToolTestFixture!

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixture = try ProjectToolTestFixture()
    }

    override func tearDown() {
        fixture = nil
        super.tearDown()
    }

    func testForceToolsAppendsDiscoveryRecoveryAndSynthesisMessages() async throws {
        let mode = try makeMode()
        let rootDescriptor = ProjectToolRootDescriptor(config: mode.projectFolder!)
        let contract = ProjectToolPromptContract(rootDescriptor: rootDescriptor)
        let client = ScriptedProjectToolLoopClient(responses: [
            ProjectToolLoopResponse(
                textSegments: [],
                toolCalls: [ToolCall(id: "call-1", name: "read_file", arguments: JSONObject(["path": "/dev/null"]))]
            ),
            ProjectToolLoopResponse(
                textSegments: [],
                toolCalls: [ToolCall(id: "call-2", name: "list_directory", arguments: JSONObject(["path": ""]))]
            ),
            ProjectToolLoopResponse(textSegments: [], toolCalls: []),
            ProjectToolLoopResponse(
                textSegments: ["I inspected the bound project root and used the tool findings to continue."],
                toolCalls: []
            )
        ])
        let factory = ScriptedProjectToolLoopClientFactory(client: client)
        let runner = ProjectToolLoopRunner(clientFactory: factory)

        let result = try await runner.run(config: ProjectToolLoopRunner.Config(
            providerType: .claude,
            mode: mode,
            model: "claude-opus-4-7",
            apiKey: "test",
            systemPrompt: "system",
            userPromptText: "user",
            screenshotImagesBase64: [],
            rootDescriptor: rootDescriptor,
            promptContract: contract,
            sessionID: nil,
            threadID: nil,
            turnID: nil,
            forceTools: true,
            onToolEvent: nil
        ))

        XCTAssertEqual(result.finalText, "I inspected the bound project root and used the tool findings to continue.")
        XCTAssertEqual(client.initialUserMessages.first, "user")
        XCTAssertTrue(client.userTextMessages.contains(contract.firstTurnReminder))
        XCTAssertTrue(client.userTextMessages.contains(contract.pathRecoveryReminder))
        XCTAssertTrue(client.userTextMessages.contains(where: { $0.contains(contract.synthesisReminder) }))
        XCTAssertEqual(client.toolResultBatches.count, 2)
        XCTAssertTrue(client.toolResultBatches[0][0].isError)
        XCTAssertTrue(client.toolResultBatches[0][0].content.contains("selected_root:"))
        XCTAssertFalse(client.toolResultBatches[1][0].isError)
    }

    func testStreamingDraftRestartsAtEachToolIteration() async throws {
        let mode = try makeMode()
        let root = ProjectToolRootDescriptor(config: mode.projectFolder!)
        let client = ScriptedProjectToolLoopClient(responses: [
            ProjectToolLoopResponse(textSegments: ["Inspecting files"], toolCalls: [
                ToolCall(id: "read", name: "list_directory", arguments: JSONObject(["path": ""]))
            ]),
            ProjectToolLoopResponse(textSegments: ["Final answer"], toolCalls: [])
        ])
        let runner = ProjectToolLoopRunner(clientFactory: ScriptedProjectToolLoopClientFactory(client: client))
        var drafts: [String] = []
        let result = try await runner.run(config: .init(
            providerType: .openai, mode: mode, model: "test", apiKey: "test",
            systemPrompt: "system", userPromptText: "user", screenshotImagesBase64: [],
            rootDescriptor: root, promptContract: ProjectToolPromptContract(rootDescriptor: root),
            sessionID: nil, threadID: nil, turnID: nil,
            onResponseText: { drafts.append($0) }
        ))
        XCTAssertEqual(drafts, ["", "Inspecting files", "", "Final answer"])
        XCTAssertEqual(result.finalText, "Final answer")
    }

    func testRunnerPreservesParallelToolBatchesWhenModelAsksForMoreThanOneTool() async throws {
        let mode = try makeMode()
        let rootDescriptor = ProjectToolRootDescriptor(config: mode.projectFolder!)
        let contract = ProjectToolPromptContract(rootDescriptor: rootDescriptor)
        let client = ScriptedProjectToolLoopClient(responses: [
            ProjectToolLoopResponse(
                textSegments: [],
                toolCalls: [
                    ToolCall(id: "call-1", name: "list_directory", arguments: JSONObject(["path": ""])),
                    ToolCall(id: "call-2", name: "read_file", arguments: JSONObject(["path": "Docs/Guide.md"]))
                ]
            ),
            ProjectToolLoopResponse(
                textSegments: ["I used multiple tool calls and gathered enough evidence to answer."],
                toolCalls: []
            ),
            ProjectToolLoopResponse(
                textSegments: ["I used multiple tool calls, gathered enough evidence, and now I am answering from those findings."],
                toolCalls: []
            ),
            ProjectToolLoopResponse(
                textSegments: [
                    """
                    In `Docs/Guide.md:1` the current guidance is:

                    ```text
                    1: # Guide
                    2: This file describes the current setup.
                    ```
                    """
                ],
                toolCalls: []
            )
        ])
        let factory = ScriptedProjectToolLoopClientFactory(client: client)
        let runner = ProjectToolLoopRunner(clientFactory: factory)

        let result = try await runner.run(config: ProjectToolLoopRunner.Config(
            providerType: .openai,
            mode: mode,
            model: "gpt-5.2",
            apiKey: "test",
            systemPrompt: "system",
            userPromptText: "user",
            screenshotImagesBase64: [],
            rootDescriptor: rootDescriptor,
            promptContract: contract,
            sessionID: nil,
            threadID: nil,
            turnID: nil,
            forceTools: true,
            onToolEvent: nil
        ))

        XCTAssertEqual(result.toolSummary["list_directory"], 1)
        XCTAssertEqual(result.toolSummary["read_file"], 1)
        XCTAssertEqual(client.toolResultBatches.count, 1)
        XCTAssertEqual(client.toolResultBatches[0].count, 2)
        XCTAssertTrue(client.userTextMessages.contains(where: { $0.contains(contract.synthesisReminder) }))
        XCTAssertEqual(result.finalText.contains("Docs/Guide.md:1"), true)
    }

    func testForceToolsDoesNotExitBeforeFirstSuccessfulToolCall() async throws {
        let mode = try makeMode()
        let rootDescriptor = ProjectToolRootDescriptor(config: mode.projectFolder!)
        let contract = ProjectToolPromptContract(rootDescriptor: rootDescriptor)
        let client = ScriptedProjectToolLoopClient(responses: [
            ProjectToolLoopResponse(
                textSegments: ["I can answer without tools."],
                toolCalls: []
            ),
            ProjectToolLoopResponse(
                textSegments: [],
                toolCalls: [ToolCall(id: "call-1", name: "list_directory", arguments: JSONObject(["path": ""]))]
            ),
            ProjectToolLoopResponse(textSegments: [], toolCalls: []),
            ProjectToolLoopResponse(
                textSegments: ["I inspected the selected root and I am now answering from the gathered evidence."],
                toolCalls: []
            )
        ])
        let factory = ScriptedProjectToolLoopClientFactory(client: client)
        let runner = ProjectToolLoopRunner(clientFactory: factory)

        let result = try await runner.run(config: ProjectToolLoopRunner.Config(
            providerType: .openai,
            mode: mode,
            model: "gpt-5.2",
            apiKey: "test",
            systemPrompt: "system",
            userPromptText: "user",
            screenshotImagesBase64: [],
            rootDescriptor: rootDescriptor,
            promptContract: contract,
            sessionID: nil,
            threadID: nil,
            turnID: nil,
            forceTools: true,
            onToolEvent: nil
        ))

        XCTAssertTrue(client.userTextMessages.contains(contract.forcedToolRecoveryReminder))
        XCTAssertTrue(client.userTextMessages.contains(where: { $0.contains(contract.synthesisReminder) }))
        XCTAssertEqual(client.toolResultBatches.count, 1)
        XCTAssertEqual(result.finalText, "I inspected the selected root and I am now answering from the gathered evidence.")
    }

    func testRunnerFallsBackToRecordedFindingsWhenProviderReturnsNoFinalText() async throws {
        let mode = try makeMode()
        let rootDescriptor = ProjectToolRootDescriptor(config: mode.projectFolder!)
        let contract = ProjectToolPromptContract(rootDescriptor: rootDescriptor)
        let client = ScriptedProjectToolLoopClient(responses: [
            ProjectToolLoopResponse(
                textSegments: [],
                toolCalls: [ToolCall(id: "call-1", name: "read_file", arguments: JSONObject(["path": "Docs/Guide.md"]))]
            ),
            ProjectToolLoopResponse(textSegments: [], toolCalls: []),
            ProjectToolLoopResponse(textSegments: [], toolCalls: [])
        ])
        let factory = ScriptedProjectToolLoopClientFactory(client: client)
        let runner = ProjectToolLoopRunner(clientFactory: factory)

        let result = try await runner.run(config: ProjectToolLoopRunner.Config(
            providerType: .claude,
            mode: mode,
            model: "claude-opus-4-7",
            apiKey: "test",
            systemPrompt: "system",
            userPromptText: "user",
            screenshotImagesBase64: [],
            rootDescriptor: rootDescriptor,
            promptContract: contract,
            sessionID: nil,
            threadID: nil,
            turnID: nil,
            forceTools: true,
            onToolEvent: nil
        ))

        XCTAssertTrue(client.userTextMessages.contains(where: { $0.contains(contract.synthesisReminder) }))
        XCTAssertTrue(result.finalText.contains("provider returned no final answer text"))
        XCTAssertTrue(result.finalText.contains("Evidence from read_file"))
        XCTAssertTrue(result.finalText.contains("Docs/Guide.md"))
        XCTAssertTrue(result.finalText.contains("```text"))
    }

    func testRunnerRequestsEvidenceRepairWhenDraftLacksCitations() async throws {
        let mode = try makeMode()
        let rootDescriptor = ProjectToolRootDescriptor(config: mode.projectFolder!)
        let contract = ProjectToolPromptContract(rootDescriptor: rootDescriptor)
        let client = ScriptedProjectToolLoopClient(responses: [
            ProjectToolLoopResponse(
                textSegments: [],
                toolCalls: [ToolCall(id: "call-1", name: "read_file", arguments: JSONObject(["path": "Docs/Guide.md"]))]
            ),
            ProjectToolLoopResponse(
                textSegments: ["I would update the implementation to match the expected flow."],
                toolCalls: []
            ),
            ProjectToolLoopResponse(
                textSegments: ["I would add the new paragraph and keep the rest the same."],
                toolCalls: []
            ),
            ProjectToolLoopResponse(
                textSegments: [
                    """
                    In `Docs/Guide.md:1` the current guidance is:

                    ```text
                    1: # Guide
                    2: This file describes the current setup.
                    ```

                    I would add the new paragraph directly below that block.
                    """
                ],
                toolCalls: []
            )
        ])
        let runner = ProjectToolLoopRunner(
            clientFactory: ScriptedProjectToolLoopClientFactory(client: client)
        )

        let result = try await runner.run(config: ProjectToolLoopRunner.Config(
            providerType: .claude,
            mode: mode,
            model: "claude-opus-4-7",
            apiKey: "test",
            systemPrompt: "system",
            userPromptText: "user",
            screenshotImagesBase64: [],
            rootDescriptor: rootDescriptor,
            promptContract: contract,
            sessionID: nil,
            threadID: nil,
            turnID: nil,
            forceTools: true,
            onToolEvent: nil
        ))

        XCTAssertTrue(client.userTextMessages.contains(where: { $0.contains("Rewrite the answer using the gathered tool evidence") }))
        XCTAssertTrue(result.finalText.contains("Docs/Guide.md:1"))
        XCTAssertTrue(result.finalText.contains("```text"))
    }

    func testCapSynthesisFailurePreservesPartialTextAndCancellation() async throws {
        fixture.config.maxToolIterations = 1
        let mode = try makeMode()
        let root = ProjectToolRootDescriptor(config: mode.projectFolder!)
        let cases: [(text: String, error: Error, cancellation: Bool)] = [
            ("Partial synthesis", AIProviderError.networkError("Synthesis failed"), false),
            ("", AIProviderError.networkError("Synthesis failed"), false),
            ("", CancellationError(), true),
            ("", AIProviderError.cancelled, true)
        ]
        for sample in cases {
            let client = ScriptedProjectToolLoopClient(responses: [
                ProjectToolLoopResponse(textSegments: [], toolCalls: [
                    ToolCall(id: "read", name: "read_file", arguments: JSONObject(["path": "Docs/Guide.md"]))
                ])
            ], terminalFailure: (sample.text, sample.error))
            let runner = ProjectToolLoopRunner(clientFactory: ScriptedProjectToolLoopClientFactory(client: client))
            var drafts: [String] = []
            do {
                let result = try await runner.run(config: .init(
                    providerType: .openai, mode: mode, model: "test", apiKey: "test",
                    systemPrompt: "system", userPromptText: "user", screenshotImagesBase64: [],
                    rootDescriptor: root, promptContract: ProjectToolPromptContract(rootDescriptor: root),
                    sessionID: nil, threadID: nil, turnID: nil,
                    onResponseText: { drafts.append($0) }
                ))
                XCTAssertTrue(sample.text.isEmpty && !sample.cancellation, "Visible partials and cancellation must not become fallback successes")
                XCTAssertTrue(result.finalText.contains("Evidence from read_file"))
            } catch {
                if sample.cancellation {
                    if let providerError = error as? AIProviderError, case .cancelled = providerError { }
                    else { XCTAssertTrue(error is CancellationError) }
                } else if case ProjectToolLoopRunner.RunError.underlying(let underlying) = error {
                    XCTAssertFalse(sample.text.isEmpty)
                    XCTAssertEqual(underlying.localizedDescription, sample.error.localizedDescription)
                    XCTAssertEqual(drafts.last, sample.text)
                } else {
                    XCTFail("Unexpected synthesis error: \(error)")
                }
            }
            XCTAssertTrue(client.userTextMessages.contains { $0.contains("Tool iteration cap reached (1)") })
            XCTAssertEqual(client.toolResultBatches.count, 1)
            XCTAssertFalse(client.toolResultBatches[0][0].isError)
        }
    }

    private func makeMode() throws -> Mode {
        var config = fixture.config
        config.bookmarkData = try fixture.rootURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return Mode(title: "Project", prompt: "Prompt", projectFolder: config)
    }
}

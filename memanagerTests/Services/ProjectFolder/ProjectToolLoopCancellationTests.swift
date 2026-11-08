import XCTest
@testable import memanager

final class ProjectToolLoopCancellationTests: XCTestCase {
    func testCancelledBatchStartsNoTools() async throws {
        let runner = ProjectToolLoopRunner()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.executeCallsConcurrently(
                calls: (0..<8).map {
                    ToolCall(id: "call-\($0)", name: "list_directory", arguments: JSONObject(["path": ""]))
                },
                mode: Mode(title: "Test", prompt: ""),
                sessionID: nil,
                threadID: nil,
                turnID: nil,
                iteration: 1,
                onToolEvent: { _ in XCTFail("A cancelled batch must not start tool execution") }
            )
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
    }

    func testFirstIterationPreservesTypedCancellation() async throws {
        let fixture = try ProjectToolTestFixture()
        var config = fixture.config
        config.bookmarkData = Data([1]) // No tool executes for this provider-only failure.
        let root = ProjectToolRootDescriptor(config: config)
        for error in [CancellationError(), AIProviderError.cancelled] as [Error] {
            let client = ScriptedProjectToolLoopClient(responses: [], terminalFailure: ("", error))
            let runner = ProjectToolLoopRunner(clientFactory: ScriptedProjectToolLoopClientFactory(client: client))
            do {
                _ = try await runner.run(config: .init(
                    providerType: .openai, mode: Mode(title: "Test", prompt: "", projectFolder: config),
                    model: "test", apiKey: "test", systemPrompt: "", userPromptText: "",
                    screenshotImagesBase64: [], rootDescriptor: root,
                    promptContract: ProjectToolPromptContract(rootDescriptor: root),
                    sessionID: nil, threadID: nil, turnID: nil
                ))
                XCTFail("Expected cancellation")
            } catch is CancellationError { }
            catch AIProviderError.cancelled { }
            catch { XCTFail("Cancellation was replaced with \(error)") }
            XCTAssertTrue(client.toolResultBatches.isEmpty)
        }
    }
}

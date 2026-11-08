import XCTest
@testable import memanager

final class ScriptedProjectToolLoopClient: ProjectToolLoopClient {
    private var responses: [ProjectToolLoopResponse]
    private let terminalFailure: (text: String, error: Error)?
    private(set) var initialUserMessages: [String] = []
    private(set) var userTextMessages: [String] = []
    private(set) var toolResultBatches: [[ToolResult]] = []

    init(responses: [ProjectToolLoopResponse], terminalFailure: (text: String, error: Error)? = nil) {
        self.responses = responses
        self.terminalFailure = terminalFailure
    }

    func appendInitialUserMessage(text: String, imagesBase64: [String]) {
        initialUserMessages.append(text)
    }

    func appendToolResults(_ results: [ToolResult]) {
        toolResultBatches.append(results)
    }

    func appendUserTextMessage(_ text: String) {
        userTextMessages.append(text)
    }

    func send(onTextDelta: @escaping (String) -> Void) async throws -> ProjectToolLoopResponse {
        if responses.isEmpty {
            if let terminalFailure {
                if !terminalFailure.text.isEmpty { onTextDelta(terminalFailure.text) }
                throw terminalFailure.error
            }
            return ProjectToolLoopResponse(textSegments: [], toolCalls: [])
        }
        let response = responses.removeFirst()
        for (index, text) in response.textSegments.enumerated() {
            if index > 0 { onTextDelta("\n") }
            onTextDelta(text)
        }
        return response
    }
}

final class ScriptedProjectToolLoopClientFactory: ProjectToolLoopClientFactory {
    private let client: ScriptedProjectToolLoopClient

    init(client: ScriptedProjectToolLoopClient) {
        self.client = client
    }

    func makeClient(
        config: ProjectToolLoopRunner.Config,
        tools: [ToolDefinition]
    ) throws -> any ProjectToolLoopClient {
        client
    }
}

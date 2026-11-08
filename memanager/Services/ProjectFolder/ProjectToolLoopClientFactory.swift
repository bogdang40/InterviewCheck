import Foundation

protocol ProjectToolLoopClientFactory {
    func makeClient(
        config: ProjectToolLoopRunner.Config,
        tools: [ToolDefinition]
    ) throws -> any ProjectToolLoopClient
}

final class DefaultProjectToolLoopClientFactory: ProjectToolLoopClientFactory {
    static let shared = DefaultProjectToolLoopClientFactory()

    private init() {}

    func makeClient(
        config: ProjectToolLoopRunner.Config,
        tools: [ToolDefinition]
    ) throws -> any ProjectToolLoopClient {
        switch config.providerType {
        case .claude:
            return ProjectToolClaudeClient(
                apiKey: config.apiKey,
                model: config.model,
                systemPrompt: config.systemPrompt,
                tools: tools,
                forceToolsOnFirstTurn: config.forceTools
            )
        case .openai:
            return ProjectToolOpenAIClient(
                apiKey: config.apiKey,
                model: config.model,
                systemPrompt: config.systemPrompt,
                tools: tools,
                forceToolsOnFirstTurn: config.forceTools
            )
        case .azureOpenAI:
            throw ProjectToolLoopRunner.RunError.unsupportedProvider("Azure OpenAI")
        }
    }
}

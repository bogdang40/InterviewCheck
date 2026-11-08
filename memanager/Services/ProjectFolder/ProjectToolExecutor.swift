import Foundation

/// Routes a `ToolCall` to the matching `ProjectTool`, enforces the sandbox, and returns a
/// `ToolResult`. Never throws: unknown names or sandbox errors become error results so the
/// model can see what went wrong and recover.
final class ProjectToolExecutor {
    static let shared = ProjectToolExecutor()

    private let registry: ProjectToolRegistry
    private let access: ProjectFolderAccess
    private let budget: ToolOutputBudget
    private let pathNormalizer: ProjectToolPathNormalizer
    let fileTime: FileTimeRegistry

    init(
        registry: ProjectToolRegistry = .shared,
        access: ProjectFolderAccess = .shared,
        budget: ToolOutputBudget = .shared,
        pathNormalizer: ProjectToolPathNormalizer = .shared,
        fileTime: FileTimeRegistry = FileTimeRegistry()
    ) {
        self.registry = registry
        self.access = access
        self.budget = budget
        self.pathNormalizer = pathNormalizer
        self.fileTime = fileTime
    }

    /// Execute a single tool call for a Mode's project folder. Returns a `ToolResult` that
    /// can be sent back to the model.
    func execute(call: ToolCall, mode: Mode) async -> ToolResult {
        guard let config = mode.projectFolder, config.isEnabled else {
            return .error(toolCallID: call.id, message: "Project folder access is not enabled for this Mode.")
        }
        guard let tool = registry.tool(named: call.name) else {
            return .error(toolCallID: call.id, message: "Unknown tool: \(call.name)")
        }
        let resolved: ResolvedProjectFolder
        do {
            resolved = try access.resolve(config: config)
        } catch {
            return .error(toolCallID: call.id, message: error.localizedDescription)
        }
        defer { resolved.release() }
        let rootDescriptor = ProjectToolRootDescriptor(rootURL: resolved.rootURL, config: config)
        let normalizedCall: ToolCall
        switch pathNormalizer.normalize(call: call, rootURL: resolved.rootURL, rootDescriptor: rootDescriptor) {
        case .success(let rewritten):
            normalizedCall = rewritten
        case .failure(let result):
            return result
        }

        let fsIndex = await FSIndexStore.shared.index(for: resolved.rootURL)
        Task.detached { [root = resolved.rootURL] in
            await FSIndexStore.shared.ensureWatcher(for: root, index: fsIndex)
            try? await fsIndex.warm(root: root)
        }
        let context = ProjectToolContext(
            rootURL: resolved.rootURL,
            config: config,
            access: access,
            fileTime: fileTime,
            fsIndex: fsIndex
        )
        let raw = await tool.execute(callID: normalizedCall.id, arguments: normalizedCall.arguments.raw, context: context)
        if raw.isError { return raw }
        let budgeted = budget.apply(raw.content)
        return ToolResult(
            toolCallID: raw.toolCallID,
            isError: false,
            content: budgeted.content,
            contentTruncated: raw.contentTruncated || budgeted.truncated,
            overflowPath: budgeted.overflowPath
        )
    }

    /// Convenience that also logs the call to SQLite via `SessionDatabase`.
    func executeAndLog(
        call: ToolCall,
        mode: Mode,
        sessionID: String?,
        threadID: String?,
        turnID: String?,
        iteration: Int
    ) async -> ToolResult {
        let started = Date()
        let result = await execute(call: call, mode: mode)
        let duration = Int(Date().timeIntervalSince(started) * 1000)
        let argumentsJSON = ProjectToolCallFormatter.argumentsJSONString(call.arguments.raw)
        let displayInput = ProjectToolCallFormatter.displayInput(
            toolName: call.name,
            arguments: call.arguments.raw
        )
        let preview = String(result.content.prefix(1000))
        let record = SessionToolCallRecord(
            sessionID: sessionID ?? "",
            threadID: threadID,
            turnID: turnID,
            toolName: call.name,
            argumentsJSON: argumentsJSON,
            displayInput: displayInput,
            resultPreview: preview,
            resultContent: result.content,
            contentTruncated: result.contentTruncated,
            overflowPath: result.overflowPath,
            isError: result.isError,
            iteration: iteration,
            startedAt: started,
            durationMs: duration
        )
        SessionDatabase.shared.logToolCall(record)
        return result
    }
}

import Foundation

extension ProjectToolLoopRunner {
    struct ExecutedToolCall {
        let result: ToolResult
        let traceInput: QuickAssistToolTraceInput
    }

    static let maxConcurrentToolCalls = 4

    func executeCallsConcurrently(
        calls: [ToolCall],
        mode: Mode,
        sessionID: String?,
        threadID: String?,
        turnID: String?,
        iteration: Int,
        onToolEvent: (@Sendable (ProjectToolCallEvent) -> Void)?
    ) async throws -> [ExecutedToolCall] {
        try Task.checkCancellation()
        if calls.isEmpty { return [] }
        let executor = self.executor
        return try await withThrowingTaskGroup(of: (Int, ExecutedToolCall).self, returning: [ExecutedToolCall].self) { group in
            var nextIndex = 0
            let initialBatch = min(Self.maxConcurrentToolCalls, calls.count)
            for _ in 0..<initialBatch {
                try Task.checkCancellation()
                let index = nextIndex
                nextIndex += 1
                group.addTask {
                    let result = try await Self.runOneWithEvents(
                        call: calls[index],
                        executor: executor,
                        mode: mode,
                        sessionID: sessionID,
                        threadID: threadID,
                        turnID: turnID,
                        iteration: iteration,
                        onToolEvent: onToolEvent
                    )
                    return (index, result)
                }
            }
            var ordered = Array<ExecutedToolCall?>(repeating: nil, count: calls.count)
            while let pair = try await group.next() {
                try Task.checkCancellation()
                ordered[pair.0] = pair.1
                if nextIndex < calls.count {
                    let index = nextIndex
                    nextIndex += 1
                    group.addTask {
                        let result = try await Self.runOneWithEvents(
                            call: calls[index],
                            executor: executor,
                            mode: mode,
                            sessionID: sessionID,
                            threadID: threadID,
                            turnID: turnID,
                            iteration: iteration,
                            onToolEvent: onToolEvent
                        )
                        return (index, result)
                    }
                }
            }
            return ordered.compactMap { $0 }
        }
    }

    static func runOneWithEvents(
        call: ToolCall,
        executor: ProjectToolExecutor,
        mode: Mode,
        sessionID: String?,
        threadID: String?,
        turnID: String?,
        iteration: Int,
        onToolEvent: (@Sendable (ProjectToolCallEvent) -> Void)?
    ) async throws -> ExecutedToolCall {
        try Task.checkCancellation()
        let startedAt = Date()
        let displayInput = ProjectToolCallFormatter.displayInput(toolName: call.name, arguments: call.arguments.raw)
        let rawArgumentsJSON = ProjectToolCallFormatter.argumentsJSONString(call.arguments.raw)
        onToolEvent?(ProjectToolCallEvent.started(
            callID: call.id,
            toolName: call.name,
            displayInput: displayInput,
            rawArgumentsJSON: rawArgumentsJSON,
            startedAt: startedAt
        ))
        let result = await executor.executeAndLog(
            call: call,
            mode: mode,
            sessionID: sessionID,
            threadID: threadID,
            turnID: turnID,
            iteration: iteration
        )
        try Task.checkCancellation()
        let completedAt = Date()
        let traceInput = QuickAssistToolTraceInput(
            id: call.id,
            toolName: call.name,
            state: result.isError ? .failed : .completed,
            iteration: iteration,
            displayInput: displayInput,
            rawArgumentsJSON: rawArgumentsJSON,
            resultContent: result.content,
            contentTruncated: result.contentTruncated,
            overflowPath: result.overflowPath,
            startedAt: startedAt,
            durationMs: Int(completedAt.timeIntervalSince(startedAt) * 1000)
        )
        let traceStep = QuickAssistToolTracePresenter()
            .present(inputs: [traceInput], turnID: nil)
            .steps
            .first
        onToolEvent?(ProjectToolCallEvent.finished(
            callID: call.id,
            toolName: call.name,
            displayInput: displayInput,
            rawArgumentsJSON: rawArgumentsJSON,
            startedAt: startedAt,
            completedAt: completedAt,
            resultContent: result.content,
            contentTruncated: result.contentTruncated,
            overflowPath: result.overflowPath,
            referencedPaths: traceStep?.referencedFiles.map(\.path) ?? [],
            isError: result.isError
        ))
        return ExecutedToolCall(result: result, traceInput: traceInput)
    }
}

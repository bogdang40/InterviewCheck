import XCTest
@testable import memanager

final class ProjectToolStreamingClientTests: XCTestCase {
    func testOpenAIEmitsBeforeCompletionAndReassemblesParallelToolArguments() async throws {
        let transport = ProjectToolStreamingTransport()
        let source = transport.enqueue()
        let client = ProjectToolOpenAIClient(apiKey: "test", model: "test", systemPrompt: "system", tools: [], transport: transport)
        client.appendInitialUserMessage(text: "question", imagesBase64: [])
        let firstDelta = expectation(description: "Text visible while response is still open")
        var chunks: [String] = []
        let task = Task {
            try await client.send { chunk in
                chunks.append(chunk)
                if chunks.count == 1 { firstDelta.fulfill() }
            }
        }
        try source.event(["choices": [["index": 0, "delta": ["content": "Reading "]]]])
        await fulfillment(of: [firstDelta], timeout: 2)
        XCTAssertEqual(chunks, ["Reading "])
        try source.event(["choices": [["index": 0, "delta": ["content": "files", "tool_calls": [
            ["index": 1, "id": "b", "function": ["name": "list_directory", "arguments": "{\"path\":"]],
            ["index": 0, "id": "a", "function": ["name": "read_file", "arguments": "{\"path\":\"Docs/"]]
        ]]]]])
        try source.event(["choices": [["index": 0, "delta": ["tool_calls": [
            ["index": 0, "function": ["arguments": "Guide.md\"}"]],
            ["index": 1, "function": ["arguments": "\"\"}"]]
        ]], "finish_reason": "tool_calls"]]])
        source.yield("data: [DONE]")
        source.finish()
        let response = try await task.value
        XCTAssertEqual(response.textSegments, ["Reading files"])
        XCTAssertEqual(response.toolCalls.map(\.id), ["a", "b"])
        XCTAssertEqual(response.toolCalls[0].arguments.raw["path"] as? String, "Docs/Guide.md")
        let request = try XCTUnwrap(transport.requests.first?.httpBody)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: request) as? [String: Any])?["stream"] as? Bool, true)

        let next = transport.enqueue()
        try next.event(["choices": [["index": 0, "delta": ["content": "Answer"], "finish_reason": "stop"]]])
        next.yield("data: [DONE]")
        next.finish()
        _ = try await client.send { _ in }
        let nextBody = try JSONSerialization.jsonObject(with: XCTUnwrap(transport.requests.last?.httpBody)) as! [String: Any]
        let history = nextBody["messages"] as! [[String: Any]]
        let assistant = try XCTUnwrap(history.first { $0["role"] as? String == "assistant" })
        XCTAssertEqual((assistant["tool_calls"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(assistant["content"] as? String, "Reading files")
    }

    func testClaudeEmitsBeforeCompletionAndPreservesBlockOrderAndThinkingSignature() async throws {
        let transport = ProjectToolStreamingTransport()
        let source = transport.enqueue()
        let client = ProjectToolClaudeClient(apiKey: "test", model: "test", systemPrompt: "system", tools: [], transport: transport)
        let visible = expectation(description: "Claude text visible before message_stop")
        var chunks: [String] = []
        let task = Task {
            try await client.send { text in
                chunks.append(text)
                if chunks.count == 1 { visible.fulfill() }
            }
        }
        try source.event(["type": "message_start"])
        try source.event(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]])
        try source.event(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "First words"]])
        await fulfillment(of: [visible], timeout: 2)
        XCTAssertEqual(chunks, ["First words"])
        try source.event(["type": "content_block_stop", "index": 0])
        try source.event(["type": "content_block_start", "index": 1, "content_block": ["type": "thinking", "thinking": ""]])
        try source.event(["type": "content_block_delta", "index": 1, "delta": ["type": "thinking_delta", "thinking": "opaque"]])
        try source.event(["type": "content_block_delta", "index": 1, "delta": ["type": "signature_delta", "signature": "signature"]])
        try source.event(["type": "content_block_stop", "index": 1])
        try source.event(["type": "content_block_start", "index": 2, "content_block": ["type": "tool_use", "id": "tool", "name": "read_file", "input": [:]]])
        try source.event(["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": "{\"path\":"]])
        try source.event(["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": "\"Guide.md\"}"]])
        try source.event(["type": "content_block_stop", "index": 2])
        try source.event(["type": "message_delta", "delta": ["stop_reason": "tool_use"]])
        try source.event(["type": "message_stop"])
        source.finish()
        let response = try await task.value
        XCTAssertEqual(response.textSegments, ["First words"])
        XCTAssertEqual(response.toolCalls.first?.arguments.raw["path"] as? String, "Guide.md")
        XCTAssertEqual(response.orderedBlocks.count, 2)
        let next = transport.enqueue()
        try next.event(["type": "message_start"])
        try next.event(["type": "message_delta", "delta": ["stop_reason": "end_turn"]])
        try next.event(["type": "message_stop"])
        next.finish()
        _ = try await client.send { _ in }
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(transport.requests.last?.httpBody)) as! [String: Any]
        XCTAssertEqual(body["stream"] as? Bool, true)
        let assistant = (body["messages"] as! [[String: Any]]).first!
        let thinking = (assistant["content"] as! [[String: Any]])[1]
        XCTAssertEqual(thinking["signature"] as? String, "signature")
        XCTAssertEqual(thinking["thinking"] as? String, "opaque")
    }

    func testTruncatedStreamsFailAfterDeliveringTheirPartialText() async throws {
        for isClaude in [false, true] {
            let transport = ProjectToolStreamingTransport()
            let source = transport.enqueue()
            let client: any ProjectToolLoopClient = isClaude
                ? ProjectToolClaudeClient(apiKey: "test", model: "test", systemPrompt: "", tools: [], transport: transport)
                : ProjectToolOpenAIClient(apiKey: "test", model: "test", systemPrompt: "", tools: [], transport: transport)
            if isClaude {
                try source.event(["type": "message_start"])
                try source.event(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": "Partial"]])
            } else {
                try source.event(["choices": [["delta": ["content": "Partial"]]]])
            }
            source.finish()
            var chunks = ""
            do {
                _ = try await client.send { chunks += $0 }
                XCTFail("EOF must not commit a completed tool response")
            } catch { XCTAssertEqual(chunks, "Partial") }
        }
    }

    func testCancellationStopsBeforeAnyProviderRequest() async throws {
        let transport = ProjectToolStreamingTransport()
        let client = ProjectToolOpenAIClient(apiKey: "test", model: "test", systemPrompt: "", tools: [], transport: transport)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.send { _ in XCTFail("Cancelled request emitted text") }
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testStreamErrorPreservesPartialAnswerAndTypedProviderCause() async throws {
        let transport = ProjectToolStreamingTransport()
        let source = transport.enqueue()
        try source.event(["choices": [["delta": ["content": "Partial"]]]])
        try source.event(["error": ["type": "insufficient_quota", "code": "insufficient_quota", "message": "Credits exhausted"]])
        source.finish()
        let client = ProjectToolOpenAIClient(apiKey: "test", model: "test", systemPrompt: "", tools: [], transport: transport)
        var chunks = ""
        do { _ = try await client.send { chunks += $0 }; XCTFail("Expected stream failure") }
        catch let AIProviderError.responseError(error) {
            XCTAssertEqual(error.code, "insufficient_quota")
            XCTAssertEqual(error.message, "Credits exhausted")
            XCTAssertEqual(chunks, "Partial")
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testCancellingOpenStreamPreservesDeliveredTextAndThrowsCancellation() async throws {
        let transport = ProjectToolStreamingTransport()
        let source = transport.enqueue()
        let visible = expectation(description: "First text delivered")
        let client = ProjectToolOpenAIClient(apiKey: "test", model: "test", systemPrompt: "", tools: [], transport: transport)
        let task = Task { try await client.send { _ in visible.fulfill() } }
        try source.event(["choices": [["delta": ["content": "Partial"]]]])
        await fulfillment(of: [visible], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        source.finish()
    }

    func testOversizedEventFailsBeforePublishingText() async throws {
        let transport = ProjectToolStreamingTransport()
        let source = transport.enqueue()
        source.yield("data: " + String(repeating: "x", count: 1_048_577))
        source.finish()
        let client = ProjectToolOpenAIClient(apiKey: "test", model: "test", systemPrompt: "", tools: [], transport: transport)
        do { _ = try await client.send { _ in XCTFail("Oversized event emitted text") }; XCTFail("Expected size limit") }
        catch let AIProviderError.parsingError(message) { XCTAssertTrue(message.contains("size limit")) }
    }

    func testMalformedToolArgumentsAreNeverExecuted() async throws {
        let transport = ProjectToolStreamingTransport()
        let source = transport.enqueue()
        try source.event(["choices": [["delta": ["tool_calls": [
            ["index": 0, "id": "a", "function": ["name": "read_file", "arguments": "{broken"]]
        ]], "finish_reason": "tool_calls"]]])
        source.yield("data: [DONE]")
        source.finish()
        let client = ProjectToolOpenAIClient(apiKey: "test", model: "test", systemPrompt: "", tools: [], transport: transport)
        do { _ = try await client.send { _ in }; XCTFail("Malformed arguments must fail") }
        catch { XCTAssertFalse(error is CancellationError) }
    }
}

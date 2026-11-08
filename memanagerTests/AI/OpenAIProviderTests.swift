import XCTest
@testable import memanager

final class OpenAIProviderTests: XCTestCase {
    func testGPT52QuickAssistUsesConfiguredReasoningAndNoCaps() async throws {
        let responsesPayload = Data(
            #"{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"OK"}]}]}"#.utf8
        )
        let transport = RecordingTransport(
            dataResults: [
                .success((responsesPayload, makeHTTPResponse(statusCode: 200)))
            ]
        )
        let provider = OpenAIProvider(
            apiKey: "test-key",
            model: "gpt-5.2",
            quickAssistModel: "gpt-5.2",
            reasoningSettings: OpenAIReasoningSettings(
                primaryModelEffort: .xhigh,
                quickModelEffort: .none
            ),
            transport: transport
        )

        let result = try await provider.quickAssist(context: makeQuickAssistContext())

        XCTAssertEqual(result, "OK")
        XCTAssertEqual(transport.dataRequests.count, 1)
        let request = try XCTUnwrap(transport.dataRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")

        let body = try decodeJSONBody(request)
        let reasoning = body["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["effort"] as? String, "none")
        XCTAssertNil(body["max_output_tokens"])
        XCTAssertNil(body["max_completion_tokens"])

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input[0]["role"] as? String, "developer")
        XCTAssertEqual(input[1]["role"] as? String, "user")
        let developerContent = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        let developerPrompt = try XCTUnwrap(developerContent.first?["text"] as? String)
        XCTAssertTrue(developerPrompt.contains("On first mention, expand abbreviations as `Full Term (ABBR)`"))
        XCTAssertTrue(developerPrompt.contains("Do not introduce unexplained abbreviations"))
        XCTAssertTrue(developerPrompt.contains("use quoted labels"))
        XCTAssertTrue(developerPrompt.contains("natural, first-person, and speakable"))
    }

    func testResponsesCompatibilityErrorFallsBackToChatCompletions() async throws {
        let compatibilityError = Data(
            #"{"error":{"message":"Unsupported parameter: reasoning"}}"#.utf8
        )
        let chatPayload = Data(
            #"{"choices":[{"message":{"content":"chat fallback"}}]}"#.utf8
        )
        let transport = RecordingTransport(
            dataResults: [
                .success((compatibilityError, makeHTTPResponse(statusCode: 400))),
                .success((chatPayload, makeHTTPResponse(statusCode: 200)))
            ]
        )
        let provider = OpenAIProvider(
            apiKey: "test-key",
            model: "gpt-5.2",
            quickAssistModel: "gpt-5.2",
            transport: transport
        )

        let result = try await provider.quickAssist(context: makeQuickAssistContext())

        XCTAssertEqual(result, "chat fallback")
        XCTAssertEqual(transport.dataRequests.count, 2)
        XCTAssertEqual(transport.dataRequests[0].url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(transport.dataRequests[1].url?.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testQuotaFailurePreservesConfiguredModelWithoutEndpointFallback() async throws {
        let quota = #"{"error":{"code":"insufficient_quota","type":"insufficient_quota","message":"Check billing"}}"#
        for streaming in [false, true] {
            let transport = RecordingTransport(
                dataResults: [.success((Data(quota.utf8), makeHTTPResponse(statusCode: 429)))],
                streamResults: [.success((makeHTTPResponse(statusCode: 429), makeLineStream([quota])))]
            )
            let provider = OpenAIProvider(
                apiKey: "fixture-key", model: "gpt-5.6-sol", quickAssistModel: "gpt-5.6-sol",
                transport: transport
            )
            do {
                if streaming {
                    try await provider.quickAssistStreaming(context: makeQuickAssistContext()) { _ in
                        XCTFail("Quota errors cannot emit answer text")
                    }
                } else {
                    _ = try await provider.quickAssist(context: makeQuickAssistContext())
                }
                XCTFail("Expected quota error")
            } catch {
                guard case AIProviderError.responseError(let response) = error else {
                    return XCTFail("Expected typed quota response, got \(error)")
                }
                XCTAssertEqual(response.code, "insufficient_quota")
            }
            let requests = streaming ? transport.streamRequests : transport.dataRequests
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.url?.path, "/v1/responses")
            XCTAssertEqual(try decodeJSONBody(XCTUnwrap(requests.first))["model"] as? String, "gpt-5.6-sol")
        }
    }

    func testNonGPT5ModelUsesChatCompletionsDirectly() async throws {
        let chatPayload = Data(
            #"{"choices":[{"message":{"content":"chat direct"}}]}"#.utf8
        )
        let transport = RecordingTransport(
            dataResults: [
                .success((chatPayload, makeHTTPResponse(statusCode: 200)))
            ]
        )
        let provider = OpenAIProvider(
            apiKey: "test-key",
            model: "gpt-4o",
            quickAssistModel: "gpt-4o",
            transport: transport
        )

        let result = try await provider.quickAssist(context: makeQuickAssistContext())

        XCTAssertEqual(result, "chat direct")
        XCTAssertEqual(transport.dataRequests.count, 1)
        let request = transport.dataRequests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")

        let body = try decodeJSONBody(request)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let systemMessage = try XCTUnwrap(messages.first)
        let systemBlocks = try XCTUnwrap(systemMessage["content"] as? [[String: Any]])
        let systemPrompt = try XCTUnwrap(systemBlocks.first?["text"] as? String)
        XCTAssertTrue(systemPrompt.contains("Abbreviation policy (strict)"))
        XCTAssertTrue(systemPrompt.contains("If multiple abbreviations appear together"))
        XCTAssertTrue(systemPrompt.contains("Mermaid safety policy"))
    }

    func testResponsesStreamingParsesOutputTextDeltaEvents() async throws {
        let lines = [
            #"data: {"type":"response.output_text.delta","delta":"hello "}"#,
            #"data: {"type":"response.output_text.delta","delta":"world"}"#,
            #"data: {"type":"response.completed"}"#,
            "data: [DONE]"
        ]
        let transport = RecordingTransport(
            streamResults: [
                .success((makeHTTPResponse(statusCode: 200), makeLineStream(lines)))
            ]
        )
        let provider = OpenAIProvider(
            apiKey: "test-key",
            model: "gpt-5.2",
            quickAssistModel: "gpt-5.2",
            reasoningSettings: OpenAIReasoningSettings(
                primaryModelEffort: .xhigh,
                quickModelEffort: .low
            ),
            transport: transport
        )

        var chunks: [String] = []
        try await provider.quickAssistStreaming(context: makeQuickAssistContext()) { chunk in
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks.joined(), "hello world")
        XCTAssertEqual(transport.streamRequests.count, 1)
        let request = transport.streamRequests[0]
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        let body = try decodeJSONBody(request)
        let reasoning = body["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["effort"] as? String, "low")
    }

    func testStreamingCompatibilityFailureFallsBackToChatCompletions() async throws {
        let fallbackLines = [
            #"data: {"choices":[{"delta":{"content":"fallback "}}]}"#,
            #"data: {"choices":[{"delta":{"content":"stream"}}]}"#,
            "data: [DONE]"
        ]
        let transport = RecordingTransport(
            streamResults: [
                .success((makeHTTPResponse(statusCode: 400), makeLineStream([#"data: {"error":{"message":"Unsupported parameter: reasoning"}}"#]))),
                .success((makeHTTPResponse(statusCode: 200), makeLineStream(fallbackLines)))
            ]
        )
        let provider = OpenAIProvider(
            apiKey: "test-key",
            model: "gpt-5.2",
            quickAssistModel: "gpt-5.2",
            transport: transport
        )

        var chunks: [String] = []
        try await provider.quickAssistStreaming(context: makeQuickAssistContext()) { chunk in
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks.joined(), "fallback stream")
        XCTAssertEqual(transport.streamRequests.count, 2)
        XCTAssertEqual(transport.streamRequests[0].url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(transport.streamRequests[1].url?.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testResponsesStreamingParsesOutputTextDoneEvents() async throws {
        let lines = [
            #"data: {"type":"response.output_text.done","text":"hello world"}"#,
            #"data: {"type":"response.completed"}"#,
            "data: [DONE]"
        ]
        let transport = RecordingTransport(
            streamResults: [
                .success((makeHTTPResponse(statusCode: 200), makeLineStream(lines)))
            ]
        )
        let provider = OpenAIProvider(
            apiKey: "test-key",
            model: "gpt-5.4",
            quickAssistModel: "gpt-5.4",
            transport: transport
        )

        var chunks: [String] = []
        try await provider.quickAssistStreaming(context: makeQuickAssistContext()) { chunk in
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks.joined(), "hello world")
        XCTAssertEqual(transport.streamRequests.count, 1)
        XCTAssertEqual(transport.streamRequests[0].url?.absoluteString, "https://api.openai.com/v1/responses")
    }

    func testResponsesStreamingFallsBackWhenOnlyLifecycleEventsArrive() async throws {
        let lifecycleOnlyLines = [
            #"data: {"type":"response.created"}"#,
            #"data: {"type":"response.completed"}"#,
            "data: [DONE]"
        ]
        let fallbackLines = [
            #"data: {"choices":[{"delta":{"content":"chat "}}]}"#,
            #"data: {"choices":[{"delta":{"content":"fallback"}}]}"#,
            "data: [DONE]"
        ]
        let transport = RecordingTransport(
            streamResults: [
                .success((makeHTTPResponse(statusCode: 200), makeLineStream(lifecycleOnlyLines))),
                .success((makeHTTPResponse(statusCode: 200), makeLineStream(fallbackLines)))
            ]
        )
        let provider = OpenAIProvider(
            apiKey: "test-key",
            model: "gpt-5.2",
            quickAssistModel: "gpt-5.2",
            transport: transport
        )

        var chunks: [String] = []
        try await provider.quickAssistStreaming(context: makeQuickAssistContext()) { chunk in
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks.joined(), "chat fallback")
        XCTAssertEqual(transport.streamRequests.count, 2)
        XCTAssertEqual(transport.streamRequests[0].url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(transport.streamRequests[1].url?.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testQuickAssistDeepTierUsesPrimaryModelAndPrimaryEffort() async throws {
        let responsesPayload = Data(
            #"{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Deep OK"}]}]}"#.utf8
        )
        let transport = RecordingTransport(
            dataResults: [
                .success((responsesPayload, makeHTTPResponse(statusCode: 200)))
            ]
        )
        let provider = OpenAIProvider(
            apiKey: "test-key",
            model: "gpt-5.4",
            quickAssistModel: "gpt-5",
            reasoningSettings: OpenAIReasoningSettings(
                primaryModelEffort: .xhigh,
                quickModelEffort: .minimal
            ),
            transport: transport
        )

        let result = try await provider.quickAssist(
            context: makeQuickAssistContext(modelTier: .deep)
        )

        XCTAssertEqual(result, "Deep OK")
        let request = try XCTUnwrap(transport.dataRequests.first)
        let body = try decodeJSONBody(request)
        XCTAssertEqual(body["model"] as? String, "gpt-5.4")
        let reasoning = body["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["effort"] as? String, "xhigh")
    }

    func testServerErrorProseNeverTriggersChatCompletionsFallback() async throws {
        let serverError = Data(
            #"{"error":{"message":"unsupported reasoning backend responses input_text"}}"#.utf8
        )
        let transport = RecordingTransport(
            dataResults: [
                .success((serverError, makeHTTPResponse(statusCode: 500)))
            ]
        )
        let provider = OpenAIProvider(
            apiKey: "test-key",
            model: "gpt-5.2",
            quickAssistModel: "gpt-5.2",
            transport: transport
        )

        do {
            _ = try await provider.quickAssist(context: makeQuickAssistContext())
            XCTFail("Expected the 500 to surface as an error")
        } catch {
            guard case AIProviderError.responseError(let response) = error else {
                return XCTFail("Expected typed responseError, got \(error)")
            }
            XCTAssertEqual(response.statusCode, 500)
        }
        XCTAssertEqual(
            transport.dataRequests.count, 1,
            "A server side 500 must not retarget to Chat Completions, even when its prose mentions Responses API vocabulary"
        )
    }

    func testQuickAssistFastTierNormalizesUnsupportedEffortForGPT5() async throws {
        let responsesPayload = Data(
            #"{"output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Fast OK"}]}]}"#.utf8
        )
        let transport = RecordingTransport(
            dataResults: [
                .success((responsesPayload, makeHTTPResponse(statusCode: 200)))
            ]
        )
        let provider = OpenAIProvider(
            apiKey: "test-key",
            model: "gpt-5.4",
            quickAssistModel: "gpt-5",
            reasoningSettings: OpenAIReasoningSettings(
                primaryModelEffort: .high,
                quickModelEffort: .xhigh
            ),
            transport: transport
        )

        let result = try await provider.quickAssist(
            context: makeQuickAssistContext(modelTier: .fast)
        )

        XCTAssertEqual(result, "Fast OK")
        let request = try XCTUnwrap(transport.dataRequests.first)
        let body = try decodeJSONBody(request)
        XCTAssertEqual(body["model"] as? String, "gpt-5")
        let reasoning = body["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["effort"] as? String, "medium")
    }
}

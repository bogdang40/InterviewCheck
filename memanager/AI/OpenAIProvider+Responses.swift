import Foundation

extension OpenAIProvider {
    func executeResponsesNonStreaming(
        model: String,
        developerPrompt: String,
        userContent: [OpenAIContentBlock],
        profile: AINetworkSession.SessionProfile,
        reasoning: OpenAIResponsesReasoning?
    ) async throws -> String {
        let requestBody = OpenAIResponsesRequest(
            model: model,
            input: buildResponsesInput(
                developerPrompt: developerPrompt,
                userContent: userContent
            ),
            stream: nil,
            reasoning: reasoning,
            max_output_tokens: nil
        )
        let request = try makeRequest(url: responsesURL, body: requestBody)
        let data = try await requestExecutor.executeDataRequest(
            request,
            profile: profile
        )

        guard let text = Self.extractResponsesOutputText(from: data) else {
            throw AIProviderError.parsingError("No content in OpenAI Responses payload")
        }

        return text
    }

    func executeResponsesStreaming(
        model: String,
        developerPrompt: String,
        userContent: [OpenAIContentBlock],
        profile: AINetworkSession.SessionProfile,
        surface: OpenAISurface,
        reasoning: OpenAIResponsesReasoning?,
        onChunk: @escaping (String) -> Void
    ) async throws -> String {
        let requestBody = OpenAIResponsesRequest(
            model: model,
            input: buildResponsesInput(
                developerPrompt: developerPrompt,
                userContent: userContent
            ),
            stream: true,
            reasoning: reasoning,
            max_output_tokens: nil
        )
        let request = try makeRequest(url: responsesURL, body: requestBody)
        var streamState = OpenAIResponsesStreamState()
        var seenEventCount = 0
        var emittedChunkCount = 0
        let startedAt = Date()
        let text = try await requestExecutor.executeStreamingTextRequest(
            request,
            profile: profile,
            chunkPolicy: chunkPolicy(for: profile),
            lineParser: { data in
                let result = Self.parseResponsesStreamingEvent(data: data)
                if result.eventType != nil {
                    seenEventCount += 1
                }
                if let visibleText = result.visibleText,
                   !visibleText.isEmpty {
                    switch result.kind {
                    case .outputTextDelta:
                        streamState.registerDeltaEmitted(itemKey: result.itemKey)
                        return visibleText
                    case .outputTextDone:
                        // The done event repeats text its item already
                        // streamed as deltas; emit it only as the fallback
                        // for items that never produced deltas.
                        if streamState.shouldSuppressDoneText(itemKey: result.itemKey) {
                            return nil
                        }
                        streamState.markVisibleTextEmitted()
                        return visibleText
                    case .other:
                        streamState.markVisibleTextEmitted()
                        return visibleText
                    }
                }

                if result.didComplete {
                    streamState.markCompleted()
                }

                return Self.parseChatCompletionsStreamDelta(data: data)
            },
            onChunk: { chunk in
                if !streamState.hasVisibleText {
                    SessionLogger.shared.logDebugEvent(
                        category: "openai_stream",
                        name: "visible_text_emitted",
                        details: "surface=\(surface.rawValue),first_chunk_len=\(chunk.count)"
                    )
                    streamState.markVisibleTextEmitted()
                }
                emittedChunkCount += 1
                onChunk(chunk)
            }
        )

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SessionLogger.shared.logDebugEvent(
                category: "openai_stream",
                name: "responses_completed_without_visible_text",
                details: "surface=\(surface.rawValue),completed=\(streamState.completed),model=\(model)"
            )
            throw AIProviderError.parsingError("No content in OpenAI Responses stream")
        }

        // One summary row per stream replaces the deleted per event log that
        // wrote a debug_events row for every streamed token.
        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        SessionLogger.shared.logDebugEvent(
            category: "openai_stream",
            name: "stream_completed",
            details: "surface=\(surface.rawValue),model=\(model),events=\(seenEventCount),chunks=\(emittedChunkCount),chars=\(text.count),duration_ms=\(durationMs)"
        )
        return text
    }

    func buildResponsesInput(
        developerPrompt: String,
        userContent: [OpenAIContentBlock]
    ) -> [OpenAIResponsesInputMessage] {
        let developer = OpenAIResponsesInputMessage(
            role: "developer",
            content: [
                OpenAIResponsesInputContent(type: "input_text", text: developerPrompt, image_url: nil)
            ]
        )

        let convertedUserContent: [OpenAIResponsesInputContent] = userContent.compactMap { block in
            switch block.type {
            case "text":
                guard let text = block.text else { return nil }
                return OpenAIResponsesInputContent(type: "input_text", text: text, image_url: nil)
            case "image_url":
                guard let url = block.image_url?.url else { return nil }
                return OpenAIResponsesInputContent(type: "input_image", text: nil, image_url: url)
            default:
                return nil
            }
        }

        let userContentBlocks = convertedUserContent.isEmpty
            ? [OpenAIResponsesInputContent(type: "input_text", text: "", image_url: nil)]
            : convertedUserContent

        let user = OpenAIResponsesInputMessage(role: "user", content: userContentBlocks)
        return [developer, user]
    }

    static func parseStreamDelta(data: Data) -> String? {
        if let visibleText = parseResponsesStreamingEvent(data: data).visibleText {
            return visibleText
        }
        return parseChatCompletionsStreamDelta(data: data)
    }

    static func parseResponsesStreamingEvent(data: Data) -> OpenAIResponsesStreamingEventResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = root["type"] as? String else {
            return OpenAIResponsesStreamingEventResult(
                eventType: nil,
                kind: .other,
                visibleText: nil,
                itemKey: nil,
                didComplete: false
            )
        }

        let itemKey = responsesEventItemKey(from: root)

        if eventType == "response.output_text.delta" {
            if let delta = root["delta"] as? String {
                return OpenAIResponsesStreamingEventResult(
                    eventType: eventType,
                    kind: .outputTextDelta,
                    visibleText: delta,
                    itemKey: itemKey,
                    didComplete: false
                )
            }
            if let deltaObject = root["delta"] as? [String: Any],
               let value = deltaObject["text"] as? String {
                return OpenAIResponsesStreamingEventResult(
                    eventType: eventType,
                    kind: .outputTextDelta,
                    visibleText: value,
                    itemKey: itemKey,
                    didComplete: false
                )
            }
        }

        if eventType == "response.output_text.done" {
            if let text = root["text"] as? String {
                return OpenAIResponsesStreamingEventResult(
                    eventType: eventType,
                    kind: .outputTextDone,
                    visibleText: text,
                    itemKey: itemKey,
                    didComplete: false
                )
            }
            if let textObject = root["text"] as? [String: Any],
               let value = textObject["value"] as? String {
                return OpenAIResponsesStreamingEventResult(
                    eventType: eventType,
                    kind: .outputTextDone,
                    visibleText: value,
                    itemKey: itemKey,
                    didComplete: false
                )
            }
        }

        let completionEvents: Set<String> = [
            "response.completed",
            "response.failed",
            "response.incomplete",
            "response.cancelled"
        ]

        return OpenAIResponsesStreamingEventResult(
            eventType: eventType,
            kind: .other,
            visibleText: nil,
            itemKey: itemKey,
            didComplete: completionEvents.contains(eventType)
        )
    }

    /// Identity of the output item a text event belongs to, when present.
    /// Delta and done events for the same item share `item_id` and
    /// `content_index`, which is what lets done-text suppression stay scoped.
    static func responsesEventItemKey(from root: [String: Any]) -> String? {
        guard let itemID = root["item_id"] as? String else { return nil }
        let contentIndex = (root["content_index"] as? Int) ?? 0
        return "\(itemID)#\(contentIndex)"
    }

    static func parseChatCompletionsStreamDelta(data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any],
              let content = delta["content"] as? String else {
            return nil
        }
        return content
    }

    static func extractResponsesOutputText(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let outputText = root["output_text"] as? String,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return outputText
        }

        if let outputTextParts = root["output_text"] as? [String] {
            let joined = outputTextParts.joined()
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return joined
            }
        }

        if let output = root["output"] as? [Any] {
            let extracted = collectOutputText(from: output)
            if !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return extracted
            }
        }

        if let nestedResponse = root["response"] as? [String: Any] {
            if let nestedOutputText = nestedResponse["output_text"] as? String,
               !nestedOutputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nestedOutputText
            }
            if let nestedOutput = nestedResponse["output"] as? [Any] {
                let extracted = collectOutputText(from: nestedOutput)
                if !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return extracted
                }
            }
        }

        return nil
    }

    static func collectOutputText(from output: [Any]) -> String {
        var parts: [String] = []

        for outputItem in output {
            guard let itemObject = outputItem as? [String: Any],
                  let content = itemObject["content"] as? [Any] else {
                continue
            }

            for contentPart in content {
                guard let contentObject = contentPart as? [String: Any] else { continue }

                if let text = contentObject["text"] as? String {
                    parts.append(text)
                    continue
                }

                if let textObject = contentObject["text"] as? [String: Any],
                   let value = textObject["value"] as? String {
                    parts.append(value)
                }
            }
        }

        return parts.joined()
    }
}

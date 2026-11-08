import Foundation

/// Preserves Claude content block order and opaque thinking/signature fields.
struct ProjectToolClaudeStream {
    private var blocks: [Int: [String: Any]] = [:]
    private var arguments: [Int: String] = [:]
    private var closed: Set<Int> = []
    private var started = false
    private var completed = false
    private var stopReason: String?
    private var emittedTextBlocks: Set<Int> = []

    mutating func consume(_ payload: String, onTextDelta: (String) -> Void) throws -> Bool {
        guard let event = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let type = event["type"] as? String else {
            throw AIProviderError.parsingError("Invalid Claude tool stream event.")
        }
        switch type {
        case "message_start":
            started = true
        case "content_block_start":
            let index = try blockIndex(event)
            guard blocks[index] == nil, let block = event["content_block"] as? [String: Any] else {
                throw AIProviderError.parsingError("Invalid Claude content block start.")
            }
            blocks[index] = block
            if let text = block["text"] as? String { emit(text, index: index, onTextDelta: onTextDelta) }
        case "content_block_delta":
            let index = try blockIndex(event)
            guard var block = blocks[index], !closed.contains(index),
                  let delta = event["delta"] as? [String: Any], let kind = delta["type"] as? String else {
                throw AIProviderError.parsingError("Claude delta has no active content block.")
            }
            switch kind {
            case "text_delta":
                let chunk = delta["text"] as? String ?? ""
                block["text"] = (block["text"] as? String ?? "") + chunk
                emit(chunk, index: index, onTextDelta: onTextDelta)
            case "input_json_delta":
                arguments[index, default: ""] += delta["partial_json"] as? String ?? ""
            case "thinking_delta":
                block["thinking"] = (block["thinking"] as? String ?? "") + (delta["thinking"] as? String ?? "")
            case "signature_delta":
                block["signature"] = (block["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
            case "citations_delta":
                if let citation = delta["citation"] as? [String: Any] {
                    block["citations"] = (block["citations"] as? [[String: Any]] ?? []) + [citation]
                }
            default: break
            }
            blocks[index] = block
        case "content_block_stop":
            let index = try blockIndex(event)
            guard var block = blocks[index], !closed.contains(index) else {
                throw AIProviderError.parsingError("Claude closed an unknown content block.")
            }
            if block["type"] as? String == "tool_use" {
                if let raw = arguments[index] {
                    guard let input = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
                        throw AIProviderError.parsingError("Claude returned incomplete tool arguments.")
                    }
                    block["input"] = input
                }
                guard block["id"] is String, block["name"] is String, block["input"] is [String: Any] else {
                    throw AIProviderError.parsingError("Claude returned an incomplete tool call.")
                }
            }
            blocks[index] = block
            closed.insert(index)
        case "message_delta":
            stopReason = (event["delta"] as? [String: Any])?["stop_reason"] as? String
        case "message_stop":
            guard started, closed.count == blocks.count,
                  let reason = stopReason, ["end_turn", "tool_use", "stop_sequence", "refusal"].contains(reason) else {
                throw AIProviderError.parsingError("Claude tool response ended before it was complete.")
            }
            completed = true
            return true
        default: break
        }
        return false
    }

    func responseData() throws -> Data {
        guard completed else {
            throw AIProviderError.parsingError("Claude tool stream closed before its completion event.")
        }
        return try JSONSerialization.data(withJSONObject: ["content": blocks.keys.sorted().compactMap { blocks[$0] }])
    }

    private func blockIndex(_ event: [String: Any]) throws -> Int {
        guard let index = event["index"] as? Int, (0..<256).contains(index) else {
            throw AIProviderError.parsingError("Invalid Claude content block index.")
        }
        return index
    }

    private mutating func emit(_ text: String, index: Int, onTextDelta: (String) -> Void) {
        guard !text.isEmpty else { return }
        if !emittedTextBlocks.contains(index) {
            if !emittedTextBlocks.isEmpty { onTextDelta("\n") }
            emittedTextBlocks.insert(index)
        }
        onTextDelta(text)
    }
}

import Foundation

/// Reassembles indexed function arguments without executing incomplete JSON.
struct ProjectToolOpenAIStream {
    private struct FunctionDelta {
        var id = ""
        var name = ""
        var arguments = ""
    }

    private var text = ""
    private var functions: [Int: FunctionDelta] = [:]
    private var finishReason: String?
    private var completed = false

    mutating func consume(_ payload: String, onTextDelta: (String) -> Void) throws -> Bool {
        if payload == "[DONE]" {
            guard finishReason == "stop" || finishReason == "tool_calls" else {
                throw AIProviderError.parsingError("OpenAI tool stream ended without a complete response.")
            }
            completed = true
            return true
        }
        let object = try JSONSerialization.jsonObject(with: Data(payload.utf8))
        guard let json = object as? [String: Any],
              let choices = json["choices"] as? [[String: Any]] else {
            throw AIProviderError.parsingError("Invalid OpenAI tool stream event.")
        }
        guard let choice = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return false }
        if let reason = choice["finish_reason"] as? String { finishReason = reason }
        let delta = choice["delta"] as? [String: Any] ?? [:]
        for key in ["content", "refusal"] {
            if let chunk = delta[key] as? String, !chunk.isEmpty {
                text += chunk
                onTextDelta(chunk)
            }
        }
        for entry in delta["tool_calls"] as? [[String: Any]] ?? [] {
            guard let index = entry["index"] as? Int, (0..<128).contains(index) else {
                throw AIProviderError.parsingError("Invalid OpenAI tool call index.")
            }
            var function = functions[index] ?? FunctionDelta()
            if let id = entry["id"] as? String { function.id = id }
            if let fields = entry["function"] as? [String: Any] {
                function.name += fields["name"] as? String ?? ""
                function.arguments += fields["arguments"] as? String ?? ""
            }
            functions[index] = function
        }
        if let reason = finishReason, reason != "stop", reason != "tool_calls" {
            throw AIProviderError.parsingError("OpenAI tool response was interrupted (\(reason)).")
        }
        return false
    }

    func responseData() throws -> Data {
        guard completed else {
            throw AIProviderError.parsingError("OpenAI tool stream closed before its completion event.")
        }
        var message: [String: Any] = ["role": "assistant", "content": text]
        if !functions.isEmpty {
            message["tool_calls"] = try functions.keys.sorted().map { index -> [String: Any] in
                let function = functions[index]!
                guard !function.id.isEmpty, !function.name.isEmpty,
                      let input = try JSONSerialization.jsonObject(with: Data(function.arguments.utf8)) as? [String: Any] else {
                    throw AIProviderError.parsingError("OpenAI returned incomplete tool arguments.")
                }
                // Validate the full object before the legacy response adapter sees it.
                let arguments = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
                return ["id": function.id, "type": "function", "function": [
                    "name": function.name, "arguments": String(decoding: arguments, as: UTF8.self)
                ]]
            }
        }
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": message]]])
    }
}

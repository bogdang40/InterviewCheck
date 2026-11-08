import Foundation

/// Shared HTTP and SSE error decoding. Machine identifiers remain separate from
/// prose; only Retry-After headers are retained, never request credentials.
enum APIErrorBodyParser {
    static let maximumBodyBytes = 16_384
    static let maximumMessageCharacters = 2_048

    struct Details: Equatable {
        let code: String?
        let type: String?
        let parameter: String?
        let message: String

        // Compatibility for existing consumers that used a single identifier.
        var apiCode: String? { code ?? parameter ?? type }
    }

    static func parse(_ body: Data) -> Details {
        let bounded = Data(body.prefix(maximumBodyBytes))
        guard let root = try? JSONSerialization.jsonObject(with: bounded) as? [String: Any] else {
            return details([:], fallback: String(decoding: bounded, as: UTF8.self))
        }
        if let error = root["error"] as? [String: Any] {
            return details(error)
        }
        if root["type"] as? String == "error" {
            return details(root)
        }
        return details([:], fallback: root["error"] as? String ?? "Unknown error")
    }

    static func httpError(
        response: HTTPURLResponse,
        body: Data,
        now: Date = Date()
    ) -> AIProviderError {
        let parsed = parse(body)
        return .responseError(APIResponseError(
            statusCode: response.statusCode, code: parsed.code, type: parsed.type,
            parameter: parsed.parameter, message: parsed.message,
            retryAfter: retryAfter(response: response, now: now)
        ))
    }

    /// Recognizes terminal error envelopes only, not errors inside tool output.
    static func streamError(from payload: Data) -> AIProviderError? {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return nil
        }
        let event = root["type"] as? String
        let parsed: Details
        if let error = root["error"] as? [String: Any] {
            parsed = details(error)
        } else if event == "error" {
            parsed = details(root, fallback: "The provider reported a stream error.")
        } else if ["response.failed", "response.incomplete", "response.cancelled"].contains(event ?? "") {
            let response = root["response"] as? [String: Any] ?? [:]
            if let error = response["error"] as? [String: Any] {
                parsed = details(error)
            } else {
                let incomplete = response["incomplete_details"] as? [String: Any]
                parsed = details([
                    "type": event ?? "error",
                    "code": incomplete?["reason"] as? String ?? event ?? "error"
                ], fallback: "The provider ended the response before completion.")
            }
        } else {
            return nil
        }
        return .responseError(APIResponseError(
            statusCode: nil, code: parsed.code, type: parsed.type,
            parameter: parsed.parameter, message: parsed.message, retryAfter: nil
        ))
    }

    private static func details(_ object: [String: Any], fallback: String = "Unknown error") -> Details {
        Details(
            code: identifier(object["code"]), type: identifier(object["type"]),
            parameter: identifier(object["param"]),
            message: safeMessage(object["message"] as? String ?? fallback)
        )
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return String(value.prefix(128).filter { $0.isLetter || $0.isNumber || "_-.[]".contains($0) })
    }

    private static func safeMessage(_ raw: String) -> String {
        var message = String(raw.prefix(maximumMessageCharacters))
        // Providers sometimes echo a rejected key in an authentication message.
        for pattern in [#"\bsk-[A-Za-z0-9_-]+"#, #"(?i)\bBearer\s+\S+"#] {
            message = message.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        message = String(message.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Unknown error" : message
    }

    private static func retryAfter(response: HTTPURLResponse, now: Date) -> TimeInterval? {
        if let value = response.value(forHTTPHeaderField: "retry-after-ms"),
           let milliseconds = Double(value), milliseconds.isFinite, milliseconds >= 0 {
            return milliseconds / 1_000
        }
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = Double(raw), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

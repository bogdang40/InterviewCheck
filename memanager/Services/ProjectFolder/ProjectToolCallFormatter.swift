import Foundation

enum ProjectToolCallFormatter {
    static func argumentsJSONString(_ raw: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    static func displayInput(toolName: String, arguments: [String: Any]) -> String {
        let pairs = arguments
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(key): \(displayValue(value))"
            }
        let joined = pairs.joined(separator: "\n")
        return pairs.isEmpty ? "\(toolName)()" : "\(toolName)\n\(joined)"
    }

    static func compactArgumentPreview(_ raw: [String: Any]) -> String {
        let pairs = raw
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(previewValue($0.value))" }
        return String(pairs.joined(separator: ", ").prefix(120))
    }

    private static func displayValue(_ value: Any) -> String {
        if let string = value as? String {
            return string.isEmpty ? "\"\"" : string
        }
        if let array = value as? [Any] {
            let rendered = array.prefix(4).map(displayValue).joined(separator: ", ")
            let suffix = array.count > 4 ? ", ..." : ""
            return "[\(rendered)\(suffix)]"
        }
        if let dictionary = value as? [String: Any] {
            let rendered = dictionary
                .sorted { $0.key < $1.key }
                .prefix(4)
                .map { "\($0.key): \(displayValue($0.value))" }
                .joined(separator: ", ")
            let suffix = dictionary.count > 4 ? ", ..." : ""
            return "{\(rendered)\(suffix)}"
        }
        return "\(value)"
    }

    private static func previewValue(_ value: Any) -> String {
        if let string = value as? String {
            let truncated = string.count > 60 ? String(string.prefix(60)) + "..." : string
            return "\"\(truncated)\""
        }
        if let array = value as? [Any] {
            return "[\(array.count) items]"
        }
        if let dictionary = value as? [String: Any] {
            return "{\(dictionary.count) keys}"
        }
        return "\(value)"
    }
}

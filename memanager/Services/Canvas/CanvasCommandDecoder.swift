import Foundation

/// Turns a fenced YAML-ish body into a concrete `CanvasCommand`. The body
/// looks like:
///
///     id: main
///     values: [2, 4, 1, 7, 3, 5]
///     label: "Input"
///
/// Decoding is strict: missing required fields drops the block silently.
/// The parser treats a dropped block as a no-op, so the prose stream is not
/// affected.
enum CanvasCommandDecoder {

    static func decode(subtype: String, body: String) -> CanvasCommand? {
        let fields = parseFields(body)
        switch subtype {
        case "array":
            return decodeArray(fields: fields)
        case "window":
            return decodeWindow(fields: fields)
        case "pointer":
            return decodePointer(fields: fields)
        case "highlight":
            return decodeHighlight(fields: fields)
        case "clear":
            guard let id = fields["id"] ?? fields["target"] else { return nil }
            return .clear(sceneID: id)
        default:
            return nil
        }
    }

    // MARK: - Subtype decoders

    private static func decodeArray(fields: [String: String]) -> CanvasCommand? {
        guard let id = fields["id"],
              let valuesRaw = fields["values"]
        else { return nil }
        let values = parseArrayLiteral(valuesRaw)
        return .array(CanvasArrayPayload(id: id, values: values, label: fields["label"]))
    }

    private static func decodeWindow(fields: [String: String]) -> CanvasCommand? {
        guard let target = fields["target"],
              let opRaw = fields["op"],
              let op = CanvasWindowPayload.Op(rawValue: opRaw),
              let left = fields["left"].flatMap(Int.init),
              let right = fields["right"].flatMap(Int.init)
        else { return nil }
        return .window(CanvasWindowPayload(targetID: target, op: op, left: left, right: right))
    }

    private static func decodePointer(fields: [String: String]) -> CanvasCommand? {
        guard let id = fields["id"],
              let target = fields["target"],
              let opRaw = fields["op"],
              let op = CanvasPointerPayload.Op(rawValue: opRaw),
              let name = fields["name"],
              let index = fields["index"].flatMap(Int.init)
        else { return nil }
        return .pointer(CanvasPointerPayload(id: id, targetID: target, op: op, name: name, index: index))
    }

    private static func decodeHighlight(fields: [String: String]) -> CanvasCommand? {
        guard let target = fields["target"],
              let kindRaw = fields["kind"],
              let kind = CanvasHighlightPayload.Kind(rawValue: kindRaw),
              let value = fields["value"]
        else { return nil }
        let ttl = fields["ttl_ms"].flatMap(Int.init) ?? 1500
        return .highlight(CanvasHighlightPayload(targetID: target, kind: kind, value: value, ttlMs: ttl))
    }

    // MARK: - Field parsing

    /// Parses "key: value" lines into a dictionary. Quoted strings and array
    /// literals are preserved as raw values; the per-subtype decoders refine.
    private static func parseFields(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let colonIndex = line.firstIndex(of: ":")
            else { continue }
            let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    private static func parseArrayLiteral(_ raw: String) -> [String] {
        var trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

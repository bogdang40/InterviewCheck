import Foundation

/// Parses newline delimited JSON produced by `rg --json`. Ripgrep emits records
/// in this order per file: `begin`, then any number of `match` and `context`
/// records, then `end`. A trailing `summary` record arrives once. We assemble
/// each `match` together with the `context` records that surround it.
enum RipgrepJSONDecoder {
    static func decodeMatches(_ output: String) -> [RipgrepMatch] {
        var matches: [RipgrepMatch] = []
        var pendingBefore: [RipgrepContextLine] = []
        var lastMatchIndex: Int? = nil

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = rawLine.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = root["type"] as? String,
                  let payload = root["data"] as? [String: Any] else { continue }

            switch type {
            case "begin":
                pendingBefore.removeAll(keepingCapacity: true)
                lastMatchIndex = nil
            case "context":
                guard let ctx = parseContextLine(payload) else { continue }
                if let idx = lastMatchIndex {
                    matches[idx].appendContextAfter(ctx)
                    pendingBefore.append(ctx)
                } else {
                    pendingBefore.append(ctx)
                }
            case "match":
                guard let match = parseMatch(payload, before: pendingBefore) else { continue }
                matches.append(match)
                lastMatchIndex = matches.count - 1
                pendingBefore.removeAll(keepingCapacity: true)
            case "end":
                lastMatchIndex = nil
                pendingBefore.removeAll(keepingCapacity: true)
            default:
                continue
            }
        }
        return matches
    }

    static func decodeFiles(_ output: String) -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("./") { return String(trimmed.dropFirst(2)) }
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func parseContextLine(_ payload: [String: Any]) -> RipgrepContextLine? {
        guard let lineNumber = payload["line_number"] as? Int,
              let text = extractLinesText(payload) else { return nil }
        return RipgrepContextLine(lineNumber: lineNumber, text: stripTrailingNewline(text))
    }

    private static func parseMatch(_ payload: [String: Any], before: [RipgrepContextLine]) -> RipgrepMatch? {
        guard let pathBlock = payload["path"] as? [String: Any],
              let path = extractText(pathBlock),
              let lineNumber = payload["line_number"] as? Int,
              let byteOffset = payload["absolute_offset"] as? Int,
              let text = extractLinesText(payload) else { return nil }
        let subs = (payload["submatches"] as? [[String: Any]]) ?? []
        let ranges: [Range<Int>] = subs.compactMap { sub in
            guard let start = sub["start"] as? Int, let end = sub["end"] as? Int, start <= end else { return nil }
            return start..<end
        }
        let clean = stripTrailingNewline(text)
        let relative = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        return RipgrepMatch(
            relativePath: relative,
            lineNumber: lineNumber,
            byteOffset: byteOffset,
            lineText: clean,
            submatches: ranges,
            contextBefore: before,
            contextAfter: []
        )
    }

    private static func extractLinesText(_ payload: [String: Any]) -> String? {
        guard let linesBlock = payload["lines"] as? [String: Any] else { return nil }
        return extractText(linesBlock)
    }

    private static func extractText(_ block: [String: Any]) -> String? {
        if let text = block["text"] as? String { return text }
        if let bytes = block["bytes"] as? String,
           let data = Data(base64Encoded: bytes),
           let text = String(data: data, encoding: .utf8) { return text }
        return nil
    }

    private static func stripTrailingNewline(_ text: String) -> String {
        if text.hasSuffix("\r\n") { return String(text.dropLast(2)) }
        if text.hasSuffix("\n") { return String(text.dropLast()) }
        return text
    }
}

private extension RipgrepMatch {
    mutating func appendContextAfter(_ line: RipgrepContextLine) {
        contextAfter.append(line)
    }
}

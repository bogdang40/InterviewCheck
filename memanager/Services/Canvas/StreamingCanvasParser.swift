import Foundation

/// Line-level state machine that reads streaming LLM text and splits it into
/// (prose, commands). Prose is forwarded to the streaming text view
/// unchanged. Commands are forwarded to the director.
///
/// Fence format (the backtick fence language is `canvas:SUBTYPE`):
///
///     ```canvas:array
///     id: main
///     values: [1, 2, 3]
///     ```
///
/// The parser is re-entrant: partial chunks are buffered until the closing
/// fence arrives. On reset, any in-flight fence body is dropped. Malformed
/// fences drop silently (prose preservation is the priority).
final class StreamingCanvasParser {

    struct FeedResult {
        let prose: String
        let commands: [CanvasCommand]
    }

    private var buffer: String = ""
    private var pendingFence: PendingFence?

    func feed(_ chunk: String) -> FeedResult {
        buffer.append(chunk)
        return flush()
    }

    func reset() {
        buffer.removeAll()
        pendingFence = nil
    }

    // MARK: - Private

    private func flush() -> FeedResult {
        var prose = ""
        var commands: [CanvasCommand] = []

        while true {
            if let existing = pendingFence {
                guard let (body, remainder) = consumeUntilClosingFence(buffer: buffer, opener: existing.opener) else {
                    // Closing fence has not arrived yet. Keep buffer as-is.
                    return FeedResult(prose: prose, commands: commands)
                }
                if let command = CanvasCommandDecoder.decode(subtype: existing.subtype, body: body) {
                    commands.append(command)
                }
                pendingFence = nil
                buffer = remainder
                continue
            }

            guard let openerRange = buffer.range(of: canvasFencePattern, options: .regularExpression) else {
                // No fence start yet. Emit all buffered prose. Hold nothing back
                // so the text view keeps streaming unless a fence opener is
                // partially visible (unlikely given the full `canvas:` marker).
                prose += buffer
                buffer.removeAll()
                return FeedResult(prose: prose, commands: commands)
            }

            // Emit everything before the fence opener as prose.
            prose += String(buffer[..<openerRange.lowerBound])
            let openerLine = String(buffer[openerRange])
            buffer.removeSubrange(..<openerRange.upperBound)

            let (opener, subtype) = extractOpenerAndSubtype(openerLine: openerLine)
            pendingFence = PendingFence(opener: opener, subtype: subtype)
            // Drop the newline that follows the fence line, if any, so the body
            // starts cleanly on the next iteration.
            if buffer.first == "\n" {
                buffer.removeFirst()
            }
        }
    }

    private func consumeUntilClosingFence(
        buffer: String,
        opener: String
    ) -> (body: String, remainder: String)? {
        // A closing fence is any line that contains only the opener characters
        // (for example ``` ) and nothing else. We match the first such line
        // following the opener.
        let closingPattern = #"(?m)^[ ]{0,3}"# + NSRegularExpression.escapedPattern(for: opener) + #"[ ]*$"#
        guard let range = buffer.range(of: closingPattern, options: .regularExpression) else {
            return nil
        }
        let body = String(buffer[..<range.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        let remainder = String(buffer[range.upperBound...])
        let trimmedRemainder = remainder.hasPrefix("\n") ? String(remainder.dropFirst()) : remainder
        return (body, trimmedRemainder)
    }

    private func extractOpenerAndSubtype(openerLine: String) -> (opener: String, subtype: String) {
        let trimmed = openerLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            let subtype = trimmed.replacingOccurrences(of: "```canvas:", with: "")
            return ("```", subtype)
        }
        if trimmed.hasPrefix("~~~") {
            let subtype = trimmed.replacingOccurrences(of: "~~~canvas:", with: "")
            return ("~~~", subtype)
        }
        return ("```", "")
    }

    private let canvasFencePattern = #"(?m)^[ ]{0,3}(?:`{3}|~{3})canvas:[a-z_]+[ ]*$"#

    private struct PendingFence {
        let opener: String
        let subtype: String
    }
}

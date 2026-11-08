import Foundation

extension ResponseVoiceGuard {
    static func splitByFencedBlocks(_ text: String) -> [Segment] {
        guard let fenceRegex else {
            return [.prose(text)]
        }

        let matches = fenceRegex.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length)
        )
        if matches.isEmpty {
            return [.prose(text)]
        }

        var segments: [Segment] = []
        var cursor = text.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }
            if cursor < matchRange.lowerBound {
                segments.append(.prose(String(text[cursor..<matchRange.lowerBound])))
            }
            segments.append(.fenced(String(text[matchRange])))
            cursor = matchRange.upperBound
        }

        if cursor < text.endIndex {
            segments.append(.prose(String(text[cursor...])))
        }

        return segments
    }

    static func renderSegment(_ segment: Segment) -> String {
        switch segment {
        case .prose(let text):
            return text
        case .fenced(let block):
            return block
        }
    }

    static func normalizeWhitespace(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let segments = splitByFencedBlocks(text)
        let normalized = segments.map { segment -> Segment in
            switch segment {
            case .fenced:
                return segment
            case .prose(let prose):
                return .prose(normalizeProseWhitespace(prose))
            }
        }
        return normalized.map(renderSegment).joined()
    }

    static func normalizeProseWhitespace(_ prose: String) -> String {
        var normalized = prose
        normalized = normalized.replacingOccurrences(of: " ,", with: ",")
        while normalized.contains("  ") {
            normalized = normalized.replacingOccurrences(of: "  ", with: " ")
        }
        let lines = normalized.components(separatedBy: "\n")
        let trimmedLines = lines.map { line -> String in
            var line = line
            while line.first == " " {
                line.removeFirst()
            }
            return line
        }
        return trimmedLines.joined(separator: "\n")
    }
}

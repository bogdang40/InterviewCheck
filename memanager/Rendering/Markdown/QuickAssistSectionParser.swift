import Foundation
import SwiftUI


struct QuickAssistSectionModel: Identifiable {
    let id: Int
    let title: String?
    let subtitle: String?
    let contentBlocks: [QuickAssistContentBlock]
}

enum QuickAssistContentBlock: Identifiable {
    case markdown(id: Int, text: String)
    case code(id: Int, languageHint: String?, code: String)

    var id: Int {
        switch self {
        case .markdown(let id, _):
            return id
        case .code(let id, _, _):
            return id
        }
    }
}

enum QuickAssistContentPresentationKind: Equatable {
    case prose
    case code
    case mermaid
}

extension QuickAssistContentBlock {
    var presentationKind: QuickAssistContentPresentationKind {
        switch self {
        case .markdown:
            return .prose
        case .code(_, let languageHint, _):
            return FencedMarkdownLanguageClassifier.isMermaidLanguage(languageHint) ? .mermaid : .code
        }
    }
}

enum QuickAssistSectionParser {
    static func parse(_ text: String) -> [QuickAssistSectionModel] {
        let segments = FencedMarkdownParser.parse(text)
        var sections: [QuickAssistSectionModel] = []
        var current = SectionAccumulator()
        var nextSectionID = 0
        var nextBlockID = 0

        for segment in segments {
            switch segment.kind {
            case .text(let value):
                parseTextChunk(
                    value,
                    current: &current,
                    sections: &sections,
                    nextSectionID: &nextSectionID,
                    nextBlockID: &nextBlockID
                )
            case .code(let languageHint, let code):
                flushPendingMarkdown(in: &current, nextBlockID: &nextBlockID)
                current.blocks.append(
                    .code(id: nextBlockID, languageHint: languageHint, code: code)
                )
                nextBlockID += 1
            }
        }

        finalizeCurrentSection(
            current: &current,
            sections: &sections,
            nextSectionID: &nextSectionID,
            nextBlockID: &nextBlockID
        )

        if sections.isEmpty {
            let fallback = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fallback.isEmpty else { return [] }
            return [
                QuickAssistSectionModel(
                    id: 0,
                    title: nil,
                    subtitle: nil,
                    contentBlocks: [.markdown(id: 0, text: fallback)]
                )
            ]
        }

        return sections
    }

    private struct SectionAccumulator {
        var title: String?
        var subtitle: String?
        var blocks: [QuickAssistContentBlock] = []
        var pendingLines: [String] = []
    }

    private static func parseTextChunk(
        _ textChunk: String,
        current: inout SectionAccumulator,
        sections: inout [QuickAssistSectionModel],
        nextSectionID: inout Int,
        nextBlockID: inout Int
    ) {
        let lines = textChunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let heading = headingTitle(from: trimmed) {
                finalizeCurrentSection(
                    current: &current,
                    sections: &sections,
                    nextSectionID: &nextSectionID,
                    nextBlockID: &nextBlockID
                )
                current.title = heading
                continue
            }

            if let label = labelTitle(from: trimmed) {
                finalizeCurrentSection(
                    current: &current,
                    sections: &sections,
                    nextSectionID: &nextSectionID,
                    nextBlockID: &nextBlockID
                )
                current.title = label
                continue
            }

            if let subtitle = subtitleCandidate(from: trimmed, current: current) {
                current.subtitle = subtitle
                continue
            }

            current.pendingLines.append(line)
        }
    }

    private static func finalizeCurrentSection(
        current: inout SectionAccumulator,
        sections: inout [QuickAssistSectionModel],
        nextSectionID: inout Int,
        nextBlockID: inout Int
    ) {
        flushPendingMarkdown(in: &current, nextBlockID: &nextBlockID)

        guard !current.blocks.isEmpty || current.subtitle != nil else {
            current = SectionAccumulator()
            return
        }

        sections.append(
            QuickAssistSectionModel(
                id: nextSectionID,
                title: current.title,
                subtitle: current.subtitle,
                contentBlocks: current.blocks
            )
        )
        nextSectionID += 1
        current = SectionAccumulator()
    }

    private static func flushPendingMarkdown(
        in current: inout SectionAccumulator,
        nextBlockID: inout Int
    ) {
        guard !current.pendingLines.isEmpty else { return }
        let rawText = current.pendingLines.joined(separator: "\n")
        let cleanedText = trimmingOuterBlankLines(from: rawText)

        if !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.blocks.append(.markdown(id: nextBlockID, text: cleanedText))
            nextBlockID += 1
        }

        current.pendingLines.removeAll(keepingCapacity: true)
    }

    private static func headingTitle(from line: String) -> String? {
        guard line.hasPrefix("##") else { return nil }
        let hashCount = line.prefix(while: { $0 == "#" }).count
        guard hashCount == 2 || hashCount == 3 else { return nil }

        let content = line.dropFirst(hashCount).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = normalizeTitle(content)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func labelTitle(from line: String) -> String? {
        guard !line.isEmpty else { return nil }

        let unwrapped = stripMarkdownWrappers(from: line)
        guard unwrapped.hasSuffix(":") else { return nil }
        guard !unwrapped.hasPrefix("- "),
              !unwrapped.hasPrefix("* "),
              !unwrapped.hasPrefix("+ "),
              !looksLikeOrderedListPrefix(unwrapped) else {
            return nil
        }

        let rawTitle = String(unwrapped.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = normalizeTitle(rawTitle)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count <= 72 else { return nil }
        guard cleaned.split(whereSeparator: { $0.isWhitespace }).count <= 8 else { return nil }
        guard !cleaned.contains("://"),
              !cleaned.contains("."),
              !cleaned.contains("?"),
              !cleaned.contains("!") else {
            return nil
        }

        return cleaned
    }

    private static func subtitleCandidate(from line: String, current: SectionAccumulator) -> String? {
        guard current.subtitle == nil, current.blocks.isEmpty else { return nil }
        guard !current.pendingLines.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        guard !line.isEmpty else { return nil }

        if let tldr = tlDrSubtitle(from: line) {
            return tldr
        }

        if let italic = italicSubtitle(from: line), isShortSubtitle(italic) {
            return italic
        }

        return nil
    }

    private static func tlDrSubtitle(from line: String) -> String? {
        guard line.lowercased().hasPrefix("tl;dr") else { return nil }
        if let prefixRange = line.range(
            of: #"(?i)^tl;dr\s*[:\-–]?\s*"#,
            options: .regularExpression
        ) {
            let remainder = line[prefixRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? "TL;DR" : remainder
        }
        return "TL;DR"
    }

    private static func italicSubtitle(from line: String) -> String? {
        if let wrapped = unwrapSingleEmphasis(line, marker: "*") {
            return wrapped
        }
        if let wrapped = unwrapSingleEmphasis(line, marker: "_") {
            return wrapped
        }
        return nil
    }

    private static func unwrapSingleEmphasis(_ line: String, marker: Character) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3,
              trimmed.first == marker,
              trimmed.last == marker else {
            return nil
        }

        let markerString = String(marker)
        guard !trimmed.hasPrefix(markerString + markerString),
              !trimmed.hasSuffix(markerString + markerString) else {
            return nil
        }

        let value = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func isShortSubtitle(_ subtitle: String) -> Bool {
        let wordCount = subtitle.split(whereSeparator: { $0.isWhitespace }).count
        return subtitle.count <= 120 && wordCount <= 18
    }

    private static func looksLikeOrderedListPrefix(_ line: String) -> Bool {
        guard let firstToken = line.split(whereSeparator: { $0.isWhitespace }).first else {
            return false
        }

        guard firstToken.hasSuffix(".") else { return false }
        let numberPart = firstToken.dropLast()
        return !numberPart.isEmpty && numberPart.allSatisfy(\.isNumber)
    }

    private static func stripMarkdownWrappers(from value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true

        while changed {
            changed = false
            for token in ["**", "__", "`", "*", "_"] {
                guard text.count > token.count * 2,
                      text.hasPrefix(token),
                      text.hasSuffix(token) else {
                    continue
                }
                text = String(text.dropFirst(token.count).dropLast(token.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }

        return text
    }

    private static func normalizeTitle(_ value: String) -> String {
        let withoutWrappers = stripMarkdownWrappers(from: value)
        var normalized = withoutWrappers.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasSuffix(":") {
            normalized.removeLast()
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized
    }

    private static func trimmingOuterBlankLines(from value: String) -> String {
        var lines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        while let first = lines.first,
              first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }

        return lines.joined(separator: "\n")
    }
}

import Foundation

/// Splits parsed quick assist sections into the verbatim opener line and the
/// remaining sections. The opener is the playbook's "**Say first:**" line;
/// pulling it out lets the canvas render it as the dedicated card the
/// candidate speaks immediately while the rest of the answer streams in.
enum QuickAssistSayFirstExtractor {

    struct Extraction {
        let opener: String?
        let sections: [QuickAssistSectionModel]
    }

    private static let label = InterviewAnswerPlaybook.sayFirstLabel

    static func extract(from sections: [QuickAssistSectionModel]) -> Extraction {
        guard
            let first = sections.first,
            first.title == nil,
            case .markdown(let blockID, let text)? = first.contentBlocks.first
        else {
            return Extraction(opener: nil, sections: sections)
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(label.lowercased()) else {
            return Extraction(opener: nil, sections: sections)
        }

        // The opener is the label's own line; later lines stay in the body.
        let lines = trimmed.components(separatedBy: "\n")
        let opener = lines[0]
            .dropFirst(label.count)
            .trimmingCharacters(in: .whitespaces)
        guard !opener.isEmpty else {
            return Extraction(opener: nil, sections: sections)
        }

        let remainderText = lines
            .dropFirst()
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var remainingBlocks = Array(first.contentBlocks.dropFirst())
        if !remainderText.isEmpty {
            remainingBlocks.insert(.markdown(id: blockID, text: remainderText), at: 0)
        }

        var rebuilt = sections
        if remainingBlocks.isEmpty && first.subtitle == nil {
            rebuilt.removeFirst()
        } else {
            rebuilt[0] = QuickAssistSectionModel(
                id: first.id,
                title: first.title,
                subtitle: first.subtitle,
                contentBlocks: remainingBlocks
            )
        }
        return Extraction(opener: opener, sections: rebuilt)
    }
}

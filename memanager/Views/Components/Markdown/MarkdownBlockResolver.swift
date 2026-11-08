import Foundation

/// One block of a rich markdown document. Foundation's full markdown parse
/// drops the newlines between blocks and records the structure as block
/// intents instead, so the renderer has to rebuild paragraphs, headings,
/// lists and quotes from those intents before it can lay them out.
struct MarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        case listItem(marker: String, depth: Int)
        case blockQuote
        case codeBlock(language: String?)
    }

    let id: Int
    let kind: Kind
    let content: AttributedString
}

/// Groups the runs of a parsed markdown string into blocks. Pure so the
/// grouping can be unit tested against real Foundation output.
enum MarkdownBlockResolver {
    static let bulletMarker = "\u{2022}"

    static func blocks(from attributed: AttributedString) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var openIdentity: Int?
        var openKind: MarkdownBlock.Kind = .paragraph
        var openContent = AttributedString()
        var hasOpenBlock = false

        func close() {
            guard hasOpenBlock else { return }
            let trimmed = trimmed(openContent)
            if !trimmed.characters.isEmpty {
                blocks.append(MarkdownBlock(id: blocks.count, kind: openKind, content: trimmed))
            }
            openContent = AttributedString()
            hasOpenBlock = false
        }

        for run in attributed.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity
            if !hasOpenBlock || identity != openIdentity {
                close()
                openIdentity = identity
                openKind = kind(for: components)
                hasOpenBlock = true
            }
            openContent.append(AttributedString(attributed[run.range]))
        }
        close()
        return blocks
    }

    static func kind(for components: [PresentationIntent.IntentType]) -> MarkdownBlock.Kind {
        for component in components {
            if case .codeBlock(let languageHint) = component.kind {
                return .codeBlock(language: languageHint)
            }
        }
        for component in components {
            if case .header(let level) = component.kind {
                return .heading(level: level)
            }
        }
        if let itemIndex = components.firstIndex(where: { if case .listItem = $0.kind { return true }; return false }),
           case .listItem(let ordinal) = components[itemIndex].kind {
            let depth = components.filter(isList).count
            let container = components.indices.contains(itemIndex + 1) ? components[itemIndex + 1].kind : nil
            let marker: String
            if case .orderedList = container {
                marker = "\(ordinal)."
            } else {
                marker = bulletMarker
            }
            return .listItem(marker: marker, depth: max(depth, 1))
        }
        if components.contains(where: { if case .blockQuote = $0.kind { return true }; return false }) {
            return .blockQuote
        }
        return .paragraph
    }

    private static func isList(_ component: PresentationIntent.IntentType) -> Bool {
        switch component.kind {
        case .orderedList, .unorderedList: return true
        default: return false
        }
    }

    private static func trimmed(_ content: AttributedString) -> AttributedString {
        var result = content
        while let last = result.characters.last, last.isNewline {
            result.characters.removeLast()
        }
        return result
    }
}

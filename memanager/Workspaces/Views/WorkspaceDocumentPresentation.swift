import Foundation

/// How a document row reads its index state at a glance.
enum WorkspaceDocumentIndexState: Equatable {
    case indexed
    case truncated
    case noText
    case skipped

    static func resolve(_ document: WorkspaceDocument) -> WorkspaceDocumentIndexState {
        if document.hasText {
            return document.extractedTruncated ? .truncated : .indexed
        }
        return document.kind.isTextBearing ? .noText : .skipped
    }

    var label: String {
        switch self {
        case .indexed: return "Indexed"
        case .truncated: return "Truncated"
        case .noText: return "No text"
        case .skipped: return "Skipped"
        }
    }

    var tone: OverlayTone {
        switch self {
        case .indexed: return .success
        case .truncated, .noText: return .warning
        case .skipped: return .neutral
        }
    }
}

/// Symbols and formatting for document rows.
enum WorkspaceDocumentPresentation {
    static func symbol(for kind: WorkspaceDocumentKind) -> String {
        switch kind {
        case .pdf: return "doc.richtext"
        case .markdown, .text: return "doc.plaintext"
        case .image: return "photo"
        case .other: return "doc"
        }
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

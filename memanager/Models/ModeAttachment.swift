import Foundation

/// Kind of a file attached to a Mode. Used for routing to the right extractor / renderer.
enum ModeAttachmentKind: String, Codable, CaseIterable, Equatable {
    case pdf
    case image
    case text
    case markdown

    var displayName: String {
        switch self {
        case .pdf: return "PDF"
        case .image: return "Image"
        case .text: return "Text"
        case .markdown: return "Markdown"
        }
    }

    var defaultExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .image: return "png"
        case .text: return "txt"
        case .markdown: return "md"
        }
    }

    /// Map a UTI / file extension (without the dot) to a kind. Returns nil for unsupported.
    static func from(pathExtension ext: String) -> ModeAttachmentKind? {
        switch ext.lowercased() {
        case "pdf":
            return .pdf
        case "png", "jpg", "jpeg", "heic", "gif":
            return .image
        case "txt", "log":
            return .text
        case "md", "markdown":
            return .markdown
        default:
            return nil
        }
    }
}

/// A single file attached to a Mode. Content is stored on disk; this record holds only metadata
/// plus the extracted text payload used to inject into the model context.
struct ModeAttachment: Identifiable, Codable, Equatable {
    let id: UUID
    let modeID: UUID
    var kind: ModeAttachmentKind
    var originalFilename: String
    var storedFilename: String
    var byteSize: Int
    var sha256: String
    var extractedText: String?
    var extractedTextTruncated: Bool
    var pageCount: Int?
    var thumbnailRelativePath: String?
    var importedAt: Date

    init(
        id: UUID = UUID(),
        modeID: UUID,
        kind: ModeAttachmentKind,
        originalFilename: String,
        storedFilename: String,
        byteSize: Int,
        sha256: String,
        extractedText: String? = nil,
        extractedTextTruncated: Bool = false,
        pageCount: Int? = nil,
        thumbnailRelativePath: String? = nil,
        importedAt: Date = Date()
    ) {
        self.id = id
        self.modeID = modeID
        self.kind = kind
        self.originalFilename = originalFilename
        self.storedFilename = storedFilename
        self.byteSize = byteSize
        self.sha256 = sha256
        self.extractedText = extractedText
        self.extractedTextTruncated = extractedTextTruncated
        self.pageCount = pageCount
        self.thumbnailRelativePath = thumbnailRelativePath
        self.importedAt = importedAt
    }
}

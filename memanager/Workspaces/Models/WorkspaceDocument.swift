import Foundation

/// Which shelf of the workspace a file lives on. Derived from the top level
/// subfolder so the layout on disk is the source of truth.
enum WorkspaceDocumentCategory: String, Codable, CaseIterable, Identifiable {
    case jobDescription
    case resume
    case notes
    case interviews
    case projects
    case journal
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jobDescription: return "Job Description"
        case .resume: return "Resume"
        case .notes: return "Notes"
        case .interviews: return "Interviews"
        case .projects: return "Projects"
        case .journal: return "Journal"
        case .other: return "Other"
        }
    }

    var folderName: String {
        switch self {
        case .jobDescription: return "Job Description"
        case .resume: return "Resume"
        case .notes: return "Notes"
        case .interviews: return "Interviews"
        case .projects: return "Projects"
        case .journal: return "Journal"
        case .other: return ""
        }
    }

    var systemImage: String {
        switch self {
        case .jobDescription: return "doc.text.magnifyingglass"
        case .resume: return "person.text.rectangle"
        case .notes: return "note.text"
        case .interviews: return "person.2"
        case .projects: return "hammer"
        case .journal: return "book.closed"
        case .other: return "doc"
        }
    }

    /// Lower is more important when the prompt budget is tight.
    var contextPriority: Int {
        switch self {
        case .jobDescription: return 0
        case .resume: return 1
        case .projects: return 2
        case .interviews: return 3
        case .notes: return 4
        case .journal: return 5
        case .other: return 6
        }
    }
}

enum WorkspaceDocumentKind: String, Codable, CaseIterable {
    case pdf
    case markdown
    case text
    case image
    case other

    init(pathExtension ext: String) {
        switch ext.lowercased() {
        case "pdf": self = .pdf
        case "md", "markdown": self = .markdown
        case "txt", "log", "csv", "json", "yaml", "yml": self = .text
        case "png", "jpg", "jpeg", "heic", "gif", "webp": self = .image
        default: self = .other
        }
    }

    /// Kinds whose text can be pulled into the prompt.
    var isTextBearing: Bool {
        switch self {
        case .pdf, .markdown, .text: return true
        case .image, .other: return false
        }
    }

    /// Bridge to the existing Mode extractor so PDFs and text reuse one code path.
    var attachmentKind: ModeAttachmentKind? {
        switch self {
        case .pdf: return .pdf
        case .markdown: return .markdown
        case .text: return .text
        case .image, .other: return nil
        }
    }
}

/// Index row for one file inside a workspace folder. Content stays on disk;
/// the row carries a fingerprint and the extracted text used for retrieval.
struct WorkspaceDocument: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let workspaceID: UUID
    var relativePath: String
    var kind: WorkspaceDocumentKind
    var category: WorkspaceDocumentCategory
    var byteSize: Int
    var sha256: String
    var extractedText: String?
    var extractedTruncated: Bool
    var indexedAt: Date
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        workspaceID: UUID,
        relativePath: String,
        kind: WorkspaceDocumentKind,
        category: WorkspaceDocumentCategory,
        byteSize: Int,
        sha256: String,
        extractedText: String? = nil,
        extractedTruncated: Bool = false,
        indexedAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.relativePath = relativePath
        self.kind = kind
        self.category = category
        self.byteSize = byteSize
        self.sha256 = sha256
        self.extractedText = extractedText
        self.extractedTruncated = extractedTruncated
        self.indexedAt = indexedAt
        self.modifiedAt = modifiedAt
    }

    var fileName: String {
        (relativePath as NSString).lastPathComponent
    }

    var hasText: Bool {
        guard let extractedText else { return false }
        return !extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

import Foundation
import PDFKit

/// Typed result of running the extractor against an attachment on disk.
struct ExtractedText: Equatable {
    var raw: String
    var truncated: Bool
    var pageCount: Int?
}

enum ModeTextExtractorError: Error, LocalizedError {
    case fileTooLarge(bytes: Int, maxBytes: Int)
    case unreadable(reason: String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let bytes, let max):
            return "File is too large: \(bytes) bytes exceeds the cap of \(max) bytes."
        case .unreadable(let reason):
            return "File could not be read: \(reason)."
        }
    }
}

/// Protocol so tests can substitute a deterministic extractor.
protocol ModeTextExtracting {
    func extract(from url: URL, kind: ModeAttachmentKind) throws -> ExtractedText
}

/// Default extractor with PDFKit for PDFs and UTF 8 for text / markdown.
final class DefaultModeTextExtractor: ModeTextExtracting {
    static let shared = DefaultModeTextExtractor()

    /// Caps chosen for safety. PDFs produce text, not binary.
    private let maxPDFPages = 40
    private let maxCharacters = 200_000
    private let maxFileSizeBytes = 50_000_000

    init() {}

    func extract(from url: URL, kind: ModeAttachmentKind) throws -> ExtractedText {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size > maxFileSizeBytes {
            throw ModeTextExtractorError.fileTooLarge(bytes: size, maxBytes: maxFileSizeBytes)
        }
        switch kind {
        case .pdf:
            return try extractPDF(url: url)
        case .text:
            return try extractText(url: url)
        case .markdown:
            return try extractMarkdown(url: url)
        case .image:
            return ExtractedText(raw: "", truncated: false, pageCount: nil)
        }
    }

    private func extractPDF(url: URL) throws -> ExtractedText {
        guard let document = PDFDocument(url: url) else {
            throw ModeTextExtractorError.unreadable(reason: "PDFDocument could not open the file")
        }
        let totalPages = document.pageCount
        let pagesToRead = min(totalPages, maxPDFPages)
        var buffer = ""
        for index in 0..<pagesToRead {
            guard let page = document.page(at: index) else { continue }
            let pageText = page.string ?? ""
            buffer.append("[page \(index + 1)]\n")
            buffer.append(pageText)
            buffer.append("\n\n")
            if buffer.count > maxCharacters { break }
        }
        let overflow = totalPages > pagesToRead || buffer.count > maxCharacters
        let trimmed = buffer.count > maxCharacters
            ? String(buffer.prefix(maxCharacters))
            : buffer
        return ExtractedText(
            raw: trimmed,
            truncated: overflow,
            pageCount: totalPages
        )
    }

    private func extractText(url: URL) throws -> ExtractedText {
        let data = try Data(contentsOf: url)
        guard let string = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ModeTextExtractorError.unreadable(reason: "Unable to decode text content")
        }
        if string.count <= maxCharacters {
            return ExtractedText(raw: string, truncated: false, pageCount: nil)
        }
        return ExtractedText(raw: String(string.prefix(maxCharacters)), truncated: true, pageCount: nil)
    }

    private func extractMarkdown(url: URL) throws -> ExtractedText {
        let text = try extractText(url: url)
        let stripped = stripFrontmatter(text.raw)
        return ExtractedText(raw: stripped, truncated: text.truncated, pageCount: nil)
    }

    private func stripFrontmatter(_ input: String) -> String {
        guard input.hasPrefix("---") else { return input }
        let components = input.components(separatedBy: "---")
        if components.count >= 3 {
            return components.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return input
    }
}

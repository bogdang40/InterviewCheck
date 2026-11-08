import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Plain text from a document someone picks: PDF, Word, RTF, OpenDocument,
/// plain text or Markdown. Used for job descriptions and résumés.
enum DocumentText {
    static let maxCharacters = 200_000
    static let maxBytes = 50_000_000
    static let maxPDFPages = 40

    static let contentTypes: [UTType] = [.pdf, .plainText, .rtf, .rtfd] + [
        "org.openxmlformats.wordprocessingml.document",
        "com.microsoft.word.doc",
        "org.oasis-open.opendocument.text",
        "net.daringfireball.markdown",
    ].compactMap { UTType($0) }

    enum Failure: LocalizedError, Equatable {
        case tooLarge
        case unreadable
        case empty

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "That file is larger than 50 MB."
            case .unreadable: return "That file could not be read. Try a PDF, Word or text file."
            case .empty: return "No text was found in that file. A scanned PDF has no text to read."
            }
        }
    }

    static func read(_ url: URL) throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw Failure.tooLarge }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let text: String
        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url) else { throw Failure.unreadable }
            text = (0..<min(document.pageCount, maxPDFPages))
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")
        } else if type?.conforms(to: .plainText) == true {
            guard let data = try? Data(contentsOf: url),
                  let string = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                throw Failure.unreadable
            }
            text = string
        } else {
            // Word, RTF and OpenDocument through the system's readers, told the
            // format so a damaged file fails instead of reading as junk text.
            guard let format = richFormats[url.pathExtension.lowercased()],
                  let attributed = try? NSAttributedString(url: url, options: [.documentType: format],
                                                           documentAttributes: nil) else {
                throw Failure.unreadable
            }
            text = attributed.string
        }
        let cleaned = clean(text)
        guard !cleaned.isEmpty else { throw Failure.empty }
        return String(cleaned.prefix(maxCharacters))
    }

    private static let richFormats: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument, "rtf": .rtf, "rtfd": .rtfd,
    ]

    /// Unifies line breaks, drops control characters, trailing spaces and
    /// runs of blank lines.
    static func clean(_ text: String) -> String {
        let printable = String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar.properties.generalCategory != .control
        }))
        let unified = printable
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        var lines: [String] = []
        for line in unified.components(separatedBy: "\n") {
            let trimmed = line.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression)
            if trimmed.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(trimmed)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

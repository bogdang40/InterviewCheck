import Foundation

/// The structured output of a streaming file read. `kind` determines whether
/// `lines`, `imageBase64`, or neither carries the payload.
struct ReadResult: Equatable {
    let relativePath: String
    let kind: DetectedFileKind
    let lines: [String]
    let startLine: Int
    let endLine: Int
    let totalLines: Int?
    let byteSize: Int
    let cut: Bool
    let more: Bool
    let imageBase64: String?
    let imageMIME: String?

    /// Model facing text payload. For text files, a line numbered dump with
    /// continuation hints. For images and PDFs, a small descriptor record that
    /// includes the base64 payload so the model can forward it as an attachment
    /// in a follow up turn.
    var modelFacingText: String {
        switch kind {
        case .empty:
            return "(empty file)"
        case .image(let mime):
            let size = imageBase64?.count ?? 0
            return "(image) mime=\(mime) bytes=\(byteSize) base64_length=\(size)\n\(imageBase64 ?? "")"
        case .pdf:
            let size = imageBase64?.count ?? 0
            return "(pdf) bytes=\(byteSize) base64_length=\(size)\n\(imageBase64 ?? "")"
        case .binary:
            return "(binary file, \(byteSize) bytes, not shown)"
        case .utf8Text:
            return textPayload()
        }
    }

    var isTruncated: Bool { cut || more }

    private func textPayload() -> String {
        let numbered = lines.enumerated().map { index, line in
            let lineNumber = startLine + index
            return "\(String(format: "%6d", lineNumber))  \(line)"
        }
        var output = numbered.joined(separator: "\n")
        if more {
            if let total = totalLines {
                let remaining = max(total - endLine, 0)
                output.append("\n(more lines available, \(remaining) remaining; use offset=\(endLine + 1) to continue)")
            } else {
                output.append("\n(more lines available; use offset=\(endLine + 1) to continue)")
            }
        }
        if cut {
            output.append("\n(output truncated at byte budget)")
        }
        return output
    }
}

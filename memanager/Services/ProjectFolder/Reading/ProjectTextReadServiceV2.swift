import Foundation

/// Replacement for `ProjectTextReadService.readSlice`. Classifies the file,
/// streams text via `StreamingLineReader`, and base64 encodes images and PDFs.
/// Uses `ProjectToolContext` for path canonicalization, sensitivity policy, and
/// size caps.
final class ProjectTextReadServiceV2 {
    static let defaultByteBudget = 256 * 1024

    private let context: ProjectToolContext
    private let detector: BinaryFileDetector
    private let imageFormatter: ImageReadFormatter

    init(
        context: ProjectToolContext,
        detector: BinaryFileDetector = BinaryFileDetector(),
        imageFormatter: ImageReadFormatter = ImageReadFormatter()
    ) {
        self.context = context
        self.detector = detector
        self.imageFormatter = imageFormatter
    }

    func read(path: String, offset: Int, limit: Int, byteBudget: Int) throws -> ReadResult {
        if !context.config.allowSensitiveReads, ProjectToolHelpers.isSensitivePath(path) {
            throw ProjectEligibleFileError.sensitive(path: path)
        }
        let url = try context.access.canonicalize(relativePath: path, rootURL: context.rootURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        if (attrs[.type] as? FileAttributeType) == .typeDirectory {
            throw ProjectEligibleFileError.directory(path: path)
        }
        let fileSize = (attrs[.size] as? Int) ?? 0
        if fileSize > context.config.maxFileSizeBytes {
            throw ProjectEligibleFileError.tooLarge(
                path: path,
                size: fileSize,
                maxBytes: context.config.maxFileSizeBytes
            )
        }

        let kind = try detector.detect(url: url)
        switch kind {
        case .empty:
            return ReadResult(
                relativePath: path, kind: .empty, lines: [],
                startLine: max(offset, 1), endLine: max(offset, 1) - 1,
                totalLines: 0, byteSize: 0, cut: false, more: false,
                imageBase64: nil, imageMIME: nil
            )
        case .binary:
            throw ProjectEligibleFileError.binary(path: path)
        case .image(let mime):
            let encoded = try imageFormatter.encode(url: url)
            return ReadResult(
                relativePath: path, kind: .image(mime: mime), lines: [],
                startLine: 1, endLine: 0, totalLines: nil, byteSize: encoded.byteSize,
                cut: false, more: false, imageBase64: encoded.base64, imageMIME: mime
            )
        case .pdf:
            let encoded = try imageFormatter.encode(url: url)
            return ReadResult(
                relativePath: path, kind: .pdf, lines: [],
                startLine: 1, endLine: 0, totalLines: nil, byteSize: encoded.byteSize,
                cut: false, more: false, imageBase64: encoded.base64, imageMIME: "application/pdf"
            )
        case .utf8Text:
            let reader = StreamingLineReader(
                url: url,
                offset: max(offset, 1),
                limit: max(limit, 1),
                byteBudget: max(byteBudget, 1024)
            )
            let streamed = try reader.read()
            return ReadResult(
                relativePath: path,
                kind: .utf8Text,
                lines: streamed.lines,
                startLine: streamed.startLine,
                endLine: streamed.endLine,
                totalLines: streamed.totalLines,
                byteSize: fileSize,
                cut: streamed.cut,
                more: streamed.more,
                imageBase64: nil,
                imageMIME: nil
            )
        }
    }
}

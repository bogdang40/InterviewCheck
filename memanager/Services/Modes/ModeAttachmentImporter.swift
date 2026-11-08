import Foundation
import AppKit

/// Errors surfaced when importing a file into a Mode.
enum ModeImportError: Error, LocalizedError {
    case unsupportedKind(pathExtension: String)
    case fileTooLarge(bytes: Int)
    case copyFailed(underlying: Error)
    case extractionFailed(underlying: Error)
    case thumbnailFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedKind(let ext):
            return "Files of type .\(ext) cannot be attached to a Mode."
        case .fileTooLarge(let bytes):
            return "File exceeds the 50 MB attachment cap (\(bytes) bytes)."
        case .copyFailed(let error):
            return "Could not copy the file: \(error.localizedDescription)"
        case .extractionFailed(let error):
            return "Could not read the file: \(error.localizedDescription)"
        case .thumbnailFailed:
            return "Could not generate a thumbnail."
        }
    }
}

/// Orchestrates the full import pipeline for a Mode attachment: validate, copy, extract text,
/// generate thumbnail, produce the final `ModeAttachment` record.
final class ModeAttachmentImporter {
    static let shared = ModeAttachmentImporter(
        storage: FileSystemModeAttachmentStorage.shared,
        extractor: DefaultModeTextExtractor.shared
    )

    private let storage: ModeAttachmentStoring
    private let extractor: ModeTextExtracting
    private let maxFileSizeBytes: Int

    init(
        storage: ModeAttachmentStoring,
        extractor: ModeTextExtracting,
        maxFileSizeBytes: Int = 50_000_000
    ) {
        self.storage = storage
        self.extractor = extractor
        self.maxFileSizeBytes = maxFileSizeBytes
    }

    func importFile(at sourceURL: URL, intoMode modeID: UUID) throws -> ModeAttachment {
        let pathExtension = sourceURL.pathExtension.lowercased()
        guard let kind = ModeAttachmentKind.from(pathExtension: pathExtension) else {
            throw ModeImportError.unsupportedKind(pathExtension: pathExtension)
        }

        let size: Int
        do {
            size = try storage.size(of: sourceURL)
        } catch {
            throw ModeImportError.copyFailed(underlying: error)
        }
        if size > maxFileSizeBytes {
            throw ModeImportError.fileTooLarge(bytes: size)
        }

        let attachmentID = UUID()
        let normalizedExtension = normalize(extension: pathExtension, for: kind)

        let copiedURL: URL
        do {
            copiedURL = try storage.store(
                fileAt: sourceURL,
                modeID: modeID,
                attachmentID: attachmentID,
                pathExtension: normalizedExtension
            )
        } catch {
            throw ModeImportError.copyFailed(underlying: error)
        }

        let sha: String
        do {
            sha = try storage.sha256(of: copiedURL)
        } catch {
            throw ModeImportError.copyFailed(underlying: error)
        }

        var extractedText: String?
        var extractedTruncated = false
        var pageCount: Int?
        if kind != .image {
            do {
                let result = try extractor.extract(from: copiedURL, kind: kind)
                extractedText = result.raw
                extractedTruncated = result.truncated
                pageCount = result.pageCount
            } catch {
                throw ModeImportError.extractionFailed(underlying: error)
            }
        }

        var thumbnailRelativePath: String?
        if kind == .image {
            thumbnailRelativePath = try generateImageThumbnail(
                originalURL: copiedURL,
                modeID: modeID,
                attachmentID: attachmentID
            )
        }

        return ModeAttachment(
            id: attachmentID,
            modeID: modeID,
            kind: kind,
            originalFilename: sourceURL.lastPathComponent,
            storedFilename: copiedURL.lastPathComponent,
            byteSize: size,
            sha256: sha,
            extractedText: extractedText,
            extractedTextTruncated: extractedTruncated,
            pageCount: pageCount,
            thumbnailRelativePath: thumbnailRelativePath
        )
    }

    private func normalize(extension ext: String, for kind: ModeAttachmentKind) -> String {
        switch kind {
        case .image:
            return ["png", "jpg", "jpeg", "heic", "gif"].contains(ext) ? ext : kind.defaultExtension
        case .markdown:
            return ["md", "markdown"].contains(ext) ? ext : kind.defaultExtension
        case .text:
            return ["txt", "log"].contains(ext) ? ext : kind.defaultExtension
        case .pdf:
            return "pdf"
        }
    }

    private func generateImageThumbnail(originalURL: URL, modeID: UUID, attachmentID: UUID) throws -> String {
        guard let image = NSImage(contentsOf: originalURL) else {
            throw ModeImportError.thumbnailFailed
        }
        let targetSize = NSSize(width: 256, height: 256)
        let thumbnail = NSImage(size: targetSize, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        guard
            let tiff = thumbnail.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            throw ModeImportError.thumbnailFailed
        }
        let thumbDir = try storage.thumbnailsDirectory(for: modeID)
        let thumbURL = thumbDir.appendingPathComponent("\(attachmentID.uuidString).png")
        try pngData.write(to: thumbURL)
        return "\(modeID.uuidString)/thumbs/\(attachmentID.uuidString).png"
    }
}

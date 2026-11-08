import Foundation

/// Detected file kind. Drives whether the file is streamed as text, returned as
/// a base64 attachment, or refused entirely.
enum DetectedFileKind: Equatable, Sendable {
    case empty
    case utf8Text
    case image(mime: String)
    case pdf
    case binary
}

/// Inspects a file's header bytes to classify it without reading the whole
/// payload. Reads at most 8 KB. Safe to call on very large files because it
/// uses a file handle and reads a fixed prefix.
struct BinaryFileDetector {
    private static let sampleBytes = 8 * 1024

    func detect(url: URL) throws -> DetectedFileKind {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let sample: Data
        if #available(macOS 10.15.4, *) {
            sample = try handle.read(upToCount: Self.sampleBytes) ?? Data()
        } else {
            sample = handle.readData(ofLength: Self.sampleBytes)
        }

        if sample.isEmpty { return .empty }
        if let image = imageMIME(sample) { return .image(mime: image) }
        if isPDF(sample) { return .pdf }
        if containsNullByte(sample) { return .binary }
        if isValidUTF8(sample) { return .utf8Text }
        return .binary
    }

    private func imageMIME(_ data: Data) -> String? {
        let bytes = data.prefix(12)
        let array = Array(bytes)
        if array.count >= 8,
           array[0] == 0x89, array[1] == 0x50, array[2] == 0x4E, array[3] == 0x47,
           array[4] == 0x0D, array[5] == 0x0A, array[6] == 0x1A, array[7] == 0x0A {
            return "image/png"
        }
        if array.count >= 3, array[0] == 0xFF, array[1] == 0xD8, array[2] == 0xFF {
            return "image/jpeg"
        }
        if array.count >= 6,
           array[0] == 0x47, array[1] == 0x49, array[2] == 0x46, array[3] == 0x38,
           (array[4] == 0x37 || array[4] == 0x39), array[5] == 0x61 {
            return "image/gif"
        }
        if array.count >= 12,
           array[0] == 0x52, array[1] == 0x49, array[2] == 0x46, array[3] == 0x46,
           array[8] == 0x57, array[9] == 0x45, array[10] == 0x42, array[11] == 0x50 {
            return "image/webp"
        }
        return nil
    }

    private func isPDF(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let bytes = Array(data.prefix(4))
        return bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46
    }

    private func containsNullByte(_ data: Data) -> Bool {
        data.contains(0)
    }

    private func isValidUTF8(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8) != nil
    }
}

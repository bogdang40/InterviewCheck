import Foundation

/// Reads an image or PDF file, base64 encodes its bytes, and returns the raw
/// encoded string plus its source size. Kept tiny and single purpose so the
/// reading service can swap it out for a multimodal pipeline later without
/// touching the streaming text path.
struct ImageReadFormatter {
    enum FormatError: Error, LocalizedError {
        case cannotRead(String)

        var errorDescription: String? {
            switch self {
            case .cannotRead(let path):
                return "Could not read image bytes from \(path)."
            }
        }
    }

    func encode(url: URL) throws -> (base64: String, byteSize: Int) {
        guard let data = try? Data(contentsOf: url) else {
            throw FormatError.cannotRead(url.path)
        }
        return (data.base64EncodedString(), data.count)
    }
}

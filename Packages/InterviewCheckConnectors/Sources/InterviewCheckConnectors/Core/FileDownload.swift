import Foundation

/// Saves a résumé or recording into a folder, with the connector's auth
/// when the URL needs it (signed URLs are fetched without credentials).
public enum FileDownload {
    public static func save(_ file: ExternalFile, into folder: URL, client: APIClient?,
                            transport: HTTPTransport) async throws -> URL {
        var request = URLRequest(url: file.url)
        request.timeoutInterval = 60 * 30
        for (field, value) in client?.headers ?? [:] where field != "Accept" { request.setValue(value, forHTTPHeaderField: field) }
        let (temporary, response) = try await (client?.transport ?? transport).download(request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (200..<300).contains(response.statusCode) else {
            let body = (try? Data(contentsOf: temporary)).map { String(decoding: $0.prefix(300), as: UTF8.self) } ?? ""
            switch response.statusCode {
            case 401: throw ConnectorError.unauthorized
            case 403: throw ConnectorError.forbidden(body)
            case 404: throw ConnectorError.notFound
            default: throw ConnectorError.http(response.statusCode, body)
            }
        }
        let name = safeName(file.filename, fallbackExtension: suggestedExtension(response))
        let destination = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// A file name without paths or odd characters, with an extension.
    static func safeName(_ name: String, fallbackExtension: String?) -> String {
        var cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty || cleaned.hasPrefix(".") { cleaned = "file" + cleaned }
        if (cleaned as NSString).pathExtension.isEmpty, let ext = fallbackExtension { cleaned += ".\(ext)" }
        return String(cleaned.prefix(120))
    }

    static func suggestedExtension(_ response: HTTPURLResponse) -> String? {
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if type.contains("pdf") { return "pdf" }
        if type.contains("wordprocessingml") { return "docx" }
        if type.contains("msword") { return "doc" }
        if type.contains("text/plain") { return "txt" }
        if type.contains("rtf") { return "rtf" }
        if type.contains("audio/mp4") || type.contains("m4a") { return "m4a" }
        if type.contains("video/mp4") { return "mp4" }
        if type.contains("text/vtt") { return "vtt" }
        return nil
    }
}

import Foundation

/// Saves a résumé or recording into a folder, with the connector's auth
/// when the URL needs it (signed URLs are fetched without credentials).
public enum FileDownload {
    public static func save(_ file: ExternalFile, into folder: URL, client: APIClient?,
                            transport: HTTPTransport) async throws -> URL {
        let (data, response): (Data, HTTPURLResponse)
        if let client {
            (data, response) = try await client.send(method: "GET", url: file.url, body: nil)
        } else {
            (data, response) = try await APIClient(baseURL: file.url, transport: transport)
                .send(method: "GET", url: file.url, body: nil)
        }
        let name = safeName(file.filename, fallbackExtension: suggestedExtension(response))
        let destination = folder.appendingPathComponent(name)
        try data.write(to: destination, options: .atomic)
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

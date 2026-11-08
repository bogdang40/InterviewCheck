import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Sends a recorded interview to Deepgram's pre-recorded API and returns
/// every word with its time, speaker and filler flag.
struct RecordingTranscriber {
    let apiKey: String
    var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 60 * 60
        return URLSession(configuration: configuration)
    }()

    static let endpoint: URL = {
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: DeepgramStreamCore.Config.model),
            URLQueryItem(name: "diarize", value: "true"),
            URLQueryItem(name: "filler_words", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
        ]
        return components.url!
    }()

    private struct Response: Decodable {
        struct Results: Decodable { let channels: [Channel] }
        struct Channel: Decodable { let alternatives: [DeepgramAlternative] }
        let results: Results
    }

    func transcribe(audioFile: URL) async throws -> [DeepgramWord] {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.contentType(for: audioFile), forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: request, fromFile: audioFile)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let message = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw RecordingError.transcription("Deepgram answered \(http.statusCode): \(message)")
        }
        return try Self.words(from: data)
    }

    static func words(from data: Data) throws -> [DeepgramWord] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.results.channels.first?.alternatives.first?.words ?? []
    }

    static func contentType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "audio/*"
    }
}

enum RecordingError: LocalizedError, Equatable {
    case noAudio
    case transcription(String)
    case noQuestions
    case missingKey

    var errorDescription: String? {
        switch self {
        case .noAudio: return "That file has no audio track."
        case .transcription(let message): return message
        case .noQuestions: return "No question-and-answer pairs were found in the recording."
        case .missingKey: return "Add a Deepgram key in Settings \u{203A} Keys first."
        }
    }
}

/// Turns a video into an audio file Deepgram accepts; audio files pass through.
enum RecordingAudio {
    static func prepare(_ url: URL) async throws -> (file: URL, isTemporary: Bool) {
        let type = UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .audio) { return (url, false) }
        let asset = AVURLAsset(url: url)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecordingError.noAudio
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("interviewcheck-recording-\(UUID().uuidString).m4a")
        export.outputURL = output
        export.outputFileType = .m4a
        // exportAsynchronously keeps macOS 14 support (export(to:as:) is 15+).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else {
            throw RecordingError.transcription(export.error?.localizedDescription ?? "Could not read the recording's audio.")
        }
        return (output, true)
    }

    static func duration(of url: URL) async -> TimeInterval? {
        guard let duration = try? await AVURLAsset(url: url).load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : nil
    }
}

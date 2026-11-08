import Foundation

/// Every connector can check its credentials.
public protocol Connector: Sendable {
    var kind: ConnectorKind { get }
    /// Checks the credentials with one cheap call; returns a short account
    /// label to show ("acme.greenhouse.io", "jane@acme.com").
    func verify() async throws -> String
}

/// Upcoming interviews (ATS schedules, calendars).
public protocol InterviewSource: Connector {
    func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview]
}

/// Full job descriptions.
public protocol JobSource: Connector {
    func job(id: String) async throws -> ExternalJob
}

/// Candidates and their résumés.
public protocol CandidateSource: Connector {
    func candidate(id: String) async throws -> ExternalCandidate
    /// Downloads a file this connector returned into `folder`.
    func download(_ file: ExternalFile, into folder: URL) async throws -> URL
}

/// Writes a private note back to the source system.
public protocol NoteDestination: Connector {
    func addNote(_ text: String, to interview: ExternalInterview) async throws
}

/// Finished meetings with recordings or transcripts.
public protocol RecordingSource: Connector {
    func recordings(since: Date) async throws -> [ExternalRecording]
    func download(_ file: ExternalFile, into folder: URL) async throws -> URL
}

public enum ConnectorError: LocalizedError, Equatable {
    case notConnected
    case missingCredential(String)
    case unauthorized
    case forbidden(String)
    case notFound
    case rateLimited
    case http(Int, String)
    case invalidResponse(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "This connector is not set up yet."
        case .missingCredential(let field): return "Missing \(field)."
        case .unauthorized: return "The key or sign-in was not accepted. Check it and connect again."
        case .forbidden(let detail): return "The account is missing a permission\(detail.isEmpty ? "" : ": \(detail)")."
        case .notFound: return "Not found."
        case .rateLimited: return "The service asked us to slow down. Try again in a minute."
        case .http(let status, let message): return "The service answered \(status)\(message.isEmpty ? "" : ": \(message)")."
        case .invalidResponse(let detail): return "Unexpected answer from the service (\(detail))."
        case .unsupported(let detail): return detail
        }
    }
}

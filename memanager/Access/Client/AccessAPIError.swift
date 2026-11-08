import Foundation

enum AccessAPIError: Error, LocalizedError, Equatable {
    case invalidServerURL(String)
    case network(String)
    case server(status: Int, code: String, message: String)
    case decoding(String)
    case unauthenticated

    var errorDescription: String? {
        switch self {
        case .invalidServerURL(let raw): return "The access server address is not a valid URL: \(raw)"
        case .network(let message): return "Could not reach the access server. \(message)"
        case .server(_, _, let message): return message
        case .decoding(let message): return "Unexpected response from the access server. \(message)"
        case .unauthenticated: return "Please sign in again."
        }
    }

    /// True only when the server itself said the session is gone. Thrown
    /// locally when no token exists, or returned by the server with one of
    /// its own codes; a bare 401 from anything else is not trusted.
    var invalidatesSession: Bool {
        switch self {
        case .unauthenticated: return true
        case .server(let status, let code, _): return status == 401 && ["session_invalid", "unauthenticated"].contains(code)
        default: return false
        }
    }
}

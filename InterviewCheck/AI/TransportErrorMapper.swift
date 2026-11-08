import Foundation

/// Maps raw transport failures into the errors the AI layer reasons about.
///
/// Cancellation must survive the mapping untouched: wrapping it as a network
/// error forces every caller to consult `Task.isCancelled` defensively before
/// trusting the error it received.
enum TransportErrorMapper {
    static func map(_ error: Error) -> Error {
        if error is AIProviderError {
            return error
        }
        if error is CancellationError {
            return error
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled {
                return CancellationError()
            }
            if urlError.code == .timedOut {
                return AIProviderError.timeout(stage: .request)
            }
        }
        return AIProviderError.networkError(error.localizedDescription)
    }
}

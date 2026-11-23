import Foundation

/// The URLSession settings for Deepgram's streaming sockets. A socket lives
/// for the whole interview, and Apple does not rule out the resource timeout
/// ending a task that runs longer, so it is set well beyond any interview;
/// the request timeout still catches a connection that stalls.
enum DeepgramSessionConfiguration {
    static let requestTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 24 * 3600

    static func make() -> URLSessionConfiguration {
        let config = TestRuntime.isRunningUnitTests ? URLSessionConfiguration.ephemeral : .default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        return config
    }
}

import Foundation
import Network

/// Receives an OAuth redirect on http://127.0.0.1:<port>/callback, the way
/// Google, Microsoft and Zoom recommend for desktop apps. Answers the
/// browser with a short page and hands back the authorization code.
public final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "interviewcheck.oauth.loopback")
    private var continuation: CheckedContinuation<URL, Error>?
    /// A result that arrived before anyone was waiting for it.
    private var early: Result<URL, Error>?
    private var finished = false

    public init(port: UInt16 = 0) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns the redirect URI to register/use.
    /// `host` is what the URI says ("localhost" for Microsoft); the listener
    /// is always on 127.0.0.1.
    public func start(host: String = "127.0.0.1") async throws -> URL {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<URL, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready where !resumed:
                    resumed = true
                    ready.resume(returning: URL(string: "http://\(host):\(self.listener.port?.rawValue ?? 0)/callback")!)
                case .failed(let error), .waiting(let error):
                    if !resumed {
                        resumed = true
                        ready.resume(throwing: error)
                    } else {
                        self.finish(.failure(error))
                    }
                case .cancelled:
                    if !resumed {
                        resumed = true
                        ready.resume(throwing: CancellationError())
                    } else {
                        self.finish(.failure(CancellationError()))
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    /// Waits for the browser to come back; returns the full callback URL.
    /// Cancelling the calling task (closing the sheet) ends the wait at once.
    public func waitForCallback(timeout: TimeInterval = 300) async throws -> URL {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(ConnectorError.unsupported("Sign-in timed out. Try connecting again.")))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let early = self.early {
                        self.early = nil
                        continuation.resume(with: early)
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    public func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let target = Self.requestTarget(request)
            let page = "<html><body style=\"font-family:-apple-system;padding:40px\"><h2>You can close this window.</h2>" +
                "<p>Return to the app to finish connecting.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\n" +
                "Connection: close\r\n\r\n\(page)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if let target, target.hasPrefix("/callback"), let url = URL(string: "http://127.0.0.1\(target)") {
                self.finish(.success(url))
            }
        }
    }

    /// "/callback?code=..." from "GET /callback?code=... HTTP/1.1".
    static func requestTarget(_ request: String) -> String? {
        guard let line = request.split(separator: "\r\n").first ?? request.split(separator: "\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    private func finish(_ result: Result<URL, Error>) {
        queue.async {
            guard !self.finished else { return }
            self.finished = true
            if let continuation = self.continuation {
                self.continuation = nil
                continuation.resume(with: result)
            } else {
                self.early = result
            }
            self.listener.cancel()
        }
    }

    /// The code from a callback URL, after checking `state`.
    public static func code(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw ConnectorError.unsupported("Sign-in was cancelled or refused (\(value("error_description") ?? error)).")
        }
        guard value("state") == expectedState else { throw ConnectorError.unsupported("Sign-in state did not match.") }
        guard let code = value("code") else { throw ConnectorError.invalidResponse("no code in the redirect") }
        return code
    }
}

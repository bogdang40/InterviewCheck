import Foundation
@testable import InterviewCheckConnectors

/// Answers requests from a table of routes; records every request.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Route {
        let method: String
        let pathContains: String
        let status: Int
        let body: Data
        let headers: [String: String]
    }

    private var routes: [Route] = []
    private(set) var requests: [URLRequest] = []
    private let lock = NSLock()

    /// Adds a route; earlier routes win, and a route with `once` is used once.
    func on(_ method: String = "GET", _ pathContains: String, status: Int = 200, json: String = "{}",
            headers: [String: String] = [:]) {
        lock.lock(); defer { lock.unlock() }
        routes.append(Route(method: method, pathContains: pathContains, status: status, body: Data(json.utf8), headers: headers))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        let target = request.url?.absoluteString ?? ""
        guard let index = routes.firstIndex(where: { $0.method == request.httpMethod && target.contains($0.pathContains) }) else {
            return (Data("{\"error\":\"no stub for \(request.httpMethod ?? "") \(target)\"}".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 599, httpVersion: nil, headerFields: nil)!)
        }
        let route = routes[index]
        // Non-2xx routes are used once so a retry can reach the next route.
        if !(200..<300).contains(route.status) { routes.remove(at: index) }
        return (route.body, HTTPURLResponse(url: request.url!, statusCode: route.status, httpVersion: nil, headerFields: route.headers)!)
    }

    func requests(containing text: String) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { ($0.url?.absoluteString ?? "").contains(text) }
    }

    func bodyJSON(_ request: URLRequest) -> JSONValue {
        (try? JSONValue.parse(request.httpBody ?? Data())) ?? .null
    }
}

func date(_ iso: String) -> Date { DateParsing.parse(iso)! }

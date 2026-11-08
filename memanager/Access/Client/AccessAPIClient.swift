import Foundation

/// Transport abstraction so the controller and tests never touch URLSession.
protocol AccessAPITransporting {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionAccessTransport: AccessAPITransporting {
    let session: URLSession

    init(session: URLSession = URLSessionAccessTransport.makeSession()) {
        self.session = session
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AccessAPIError.decoding("Non HTTP response")
            }
            return (data, http)
        } catch let error as AccessAPIError {
            throw error
        } catch {
            throw AccessAPIError.network(error.localizedDescription)
        }
    }
}

protocol AccessAPIClienting {
    func signup(email: String, password: String, adminSecret: String?) async throws -> SignedInResponse
    func login(email: String, password: String) async throws -> SignedInResponse
    func logout(token: String) async throws
    func me(token: String) async throws -> AccessSnapshot
    func plans() async throws -> BillingPlans
    func checkoutURL(token: String, plan: String) async throws -> URL
    func portalURL(token: String) async throws -> URL
}

/// Typed client over the access server. Decodes success bodies and turns
/// error bodies into AccessAPIError.server with the server's code.
final class AccessAPIClient: AccessAPIClienting {
    private let baseURLProvider: () -> String
    private let transport: AccessAPITransporting
    private let deviceName: String
    private let decoder = JSONDecoder()

    init(
        baseURLProvider: @escaping () -> String = { AccessServerAddress.current() },
        transport: AccessAPITransporting = URLSessionAccessTransport(),
        deviceName: String = Host.current().localizedName ?? "Mac"
    ) {
        self.baseURLProvider = baseURLProvider
        self.transport = transport
        self.deviceName = AccessAPIClient.boundedDeviceName(deviceName)
    }

    /// Mirrors the server's schema limit so a long computer name cannot
    /// turn every sign in into a validation error.
    static let maximumDeviceNameLength = 120

    static func boundedDeviceName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Mac" }
        return String(trimmed.prefix(maximumDeviceNameLength))
    }

    func signup(email: String, password: String, adminSecret: String?) async throws -> SignedInResponse {
        try await perform(.signup(email: email, password: password, deviceName: deviceName, adminSecret: adminSecret), token: nil)
    }

    func login(email: String, password: String) async throws -> SignedInResponse {
        try await perform(.login(email: email, password: password, deviceName: deviceName), token: nil)
    }

    func logout(token: String) async throws {
        _ = try await performRaw(.logout, token: token)
    }

    func me(token: String) async throws -> AccessSnapshot {
        try await perform(.me, token: token)
    }

    func plans() async throws -> BillingPlans {
        try await perform(.plans, token: nil)
    }

    func checkoutURL(token: String, plan: String) async throws -> URL {
        let response: RedirectURLResponse = try await perform(.checkout(plan: plan), token: token)
        guard let url = URL(string: response.url) else { throw AccessAPIError.decoding("Bad checkout URL") }
        return url
    }

    func portalURL(token: String) async throws -> URL {
        let response: RedirectURLResponse = try await perform(.portal, token: token)
        guard let url = URL(string: response.url) else { throw AccessAPIError.decoding("Bad portal URL") }
        return url
    }

    // MARK: - Shared plumbing (also used by the admin client)

    func perform<Response: Decodable>(_ endpoint: AccessAPIEndpoint, token: String?) async throws -> Response {
        let data = try await performRaw(endpoint, token: token)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw AccessAPIError.decoding(error.localizedDescription)
        }
    }

    func performRaw(_ endpoint: AccessAPIEndpoint, token: String?) async throws -> Data {
        let baseURL = try AccessServerAddress.url(from: baseURLProvider())
        let request = try endpoint.makeRequest(baseURL: baseURL, token: token)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw AccessAPIClient.serverError(status: response.statusCode, data: data)
        }
        return data
    }

    /// Only the server's own error envelope may say a session is invalid; a
    /// bodyless 401 from a proxy or captive portal must not sign anyone out.
    static func serverError(status: Int, data: Data) -> AccessAPIError {
        if let body = try? JSONDecoder().decode(AccessErrorBody.self, from: data) {
            return .server(status: status, code: body.error.code, message: body.error.message)
        }
        return .server(status: status, code: "http_\(status)", message: "The access server answered with HTTP \(status).")
    }
}

/// Where the access server lives. Debug builds let the developer point the
/// app anywhere; release builds are pinned to the shipped origin so the
/// paywall cannot be redirected to a look alike server from the UI.
enum AccessServerAddress {
    /// Set this to the deployed origin before shipping a release build.
    static let releaseOrigin = "https://access.memanager.app"

    #if DEBUG
    static let isEditable = true
    #else
    static let isEditable = false
    #endif

    static func current(settings: SettingsManager = .shared) -> String {
        resolve(stored: settings.accessServerBaseURL, editable: isEditable)
    }

    /// Release builds honor a stored address only when it targets loopback,
    /// so a developer can test a release build against a local server with
    /// `defaults write com.memanager.app memanager.accessServerBaseURL http://localhost:8787`
    /// while nobody can redirect the app to a look alike host.
    static func resolve(stored: String, editable: Bool) -> String {
        if editable { return stored }
        if let url = try? url(from: stored), isLoopbackHost(url.host) { return stored }
        return releaseOrigin
    }

    static func isLoopbackHost(_ host: String?) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(host?.lowercased() ?? "")
    }

    /// Normalizes what the user typed into a usable base URL. Plain http is
    /// only accepted for loopback so a bearer token never crosses a network
    /// in clear text.
    static func url(from raw: String) throws -> URL {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty { throw AccessAPIError.invalidServerURL(raw) }
        if !candidate.contains("://") { candidate = "https://" + candidate }
        while candidate.hasSuffix("/") { candidate.removeLast() }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            throw AccessAPIError.invalidServerURL(raw)
        }
        guard scheme == "https" || (scheme == "http" && isLoopbackHost(host)) else {
            throw AccessAPIError.invalidServerURL(raw)
        }
        return url
    }
}

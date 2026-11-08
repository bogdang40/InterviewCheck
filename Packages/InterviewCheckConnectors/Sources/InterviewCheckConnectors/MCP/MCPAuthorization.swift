import Foundation

/// MCP authorization: find the server's OAuth endpoints (protected-resource
/// and authorization-server metadata), register this app as a public client
/// (dynamic client registration) and sign in with PKCE.
public enum MCPAuthorization {
    public struct Endpoints: Equatable, Sendable {
        public var authorizeURL: URL
        public var tokenURL: URL
        public var registrationURL: URL?
        public var scopes: [String]

        public init(authorizeURL: URL, tokenURL: URL, registrationURL: URL?, scopes: [String]) {
            self.authorizeURL = authorizeURL
            self.tokenURL = tokenURL
            self.registrationURL = registrationURL
            self.scopes = scopes
        }
    }

    public static func discover(server: URL, transport: HTTPTransport) async throws -> Endpoints {
        let probe = APIClient(baseURL: server, transport: NoThrowTransport(transport))
        let (_, response) = try await probe.send(method: "POST", url: server, body: Data("{}".utf8))
        var authorizationServer = origin(server)
        var scopes: [String] = []
        if let metadata = resourceMetadataURL(response) ?? URL(string: "\(origin(server))/.well-known/oauth-protected-resource\(server.path)"),
           let resource = try? await probe.send(method: "GET", url: metadata, body: nil), resource.1.statusCode == 200,
           let json = try? JSONValue.parse(resource.0) {
            if let first = json["authorization_servers"][0].string { authorizationServer = first }
            scopes = json["scopes_supported"].array.compactMap(\.string)
        }
        for candidate in metadataURLs(for: authorizationServer) {
            guard let (data, response) = try? await probe.send(method: "GET", url: candidate, body: nil), response.statusCode == 200,
                  let json = try? JSONValue.parse(data), let authorize = json["authorization_endpoint"].url,
                  let token = json["token_endpoint"].url else { continue }
            // The sign-in page, the token exchange and registration must all be
            // https on the authorization server's own host (and its issuer):
            // otherwise a server could send the code and PKCE verifier elsewhere,
            // or have the app open a non-web link.
            let host = URL(string: authorizationServer)?.host?.lowercased()
            let onServer = { (url: URL) in url.scheme?.lowercased() == "https" && url.host?.lowercased() == host }
            let issuerHost = json["issuer"].url?.host?.lowercased()
            guard host != nil, onServer(authorize), onServer(token), issuerHost == nil || issuerHost == host else {
                throw ConnectorError.unsupported("This MCP server's sign-in addresses are not https on its authorization server. Paste a token instead.")
            }
            // Only the scopes the MCP resource asks for: requesting everything the
            // authorization server knows can be refused (invalid_scope).
            return Endpoints(authorizeURL: authorize, tokenURL: token,
                             registrationURL: json["registration_endpoint"].url.flatMap { onServer($0) ? $0 : nil },
                             scopes: scopes)
        }
        throw ConnectorError.unsupported("This MCP server does not publish OAuth sign-in details. Paste a token instead.")
    }

    /// Registers a public client for this redirect; returns its client id.
    public static func register(at url: URL, redirectURI: URL, transport: HTTPTransport) async throws -> String {
        let client = APIClient(baseURL: url, transport: transport)
        let json = try await client.postJSON(url.absoluteString, body: [
            "client_name": "InterviewCheck", "redirect_uris": [.string(redirectURI.absoluteString)],
            "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        guard let id = json["client_id"].string else { throw ConnectorError.invalidResponse("no client_id from registration") }
        return id
    }

    /// The OAuth provider for this server, with the RFC 8707 resource.
    public static func provider(_ endpoints: Endpoints, server: URL) -> OAuthProvider {
        OAuthProvider(authorizeURL: endpoints.authorizeURL, tokenURL: endpoints.tokenURL, scopes: endpoints.scopes,
                      extraParameters: ["resource": server.absoluteString], extraTokenFields: ["resource": server.absoluteString])
    }

    static func origin(_ url: URL) -> String {
        "\(url.scheme ?? "https")://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")"
    }

    /// `resource_metadata="…"` from a 401's WWW-Authenticate header.
    static func resourceMetadataURL(_ response: HTTPURLResponse) -> URL? {
        guard let header = response.value(forHTTPHeaderField: "WWW-Authenticate"),
              let range = header.range(of: #"resource_metadata="([^"]+)""#, options: .regularExpression) else { return nil }
        return URL(string: String(header[range]).replacingOccurrences(of: "resource_metadata=", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
    }

    /// RFC 8414 (path inserted after the well-known part) and OpenID forms.
    static func metadataURLs(for issuer: String) -> [URL] {
        guard let url = URL(string: issuer) else { return [] }
        let base = origin(url)
        let path = url.path == "/" ? "" : url.path
        return ["\(base)/.well-known/oauth-authorization-server\(path)", "\(base)/.well-known/openid-configuration\(path)",
                "\(issuer.hasSuffix("/") ? String(issuer.dropLast()) : issuer)/.well-known/openid-configuration"]
            .compactMap(URL.init(string:))
    }
}

/// Passes every status through, so discovery can read a 401's headers.
struct NoThrowTransport: HTTPTransport {
    let base: HTTPTransport
    init(_ base: HTTPTransport) { self.base = base }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await base.send(request)
        guard (200..<300).contains(response.statusCode) else {
            return (data, HTTPURLResponse(url: response.url!, statusCode: 200, httpVersion: nil,
                                          headerFields: (response.allHeaderFields as? [String: String] ?? [:])
                                              .merging(["X-Original-Status": "\(response.statusCode)"]) { $1 })!)
        }
        return (data, response)
    }
}

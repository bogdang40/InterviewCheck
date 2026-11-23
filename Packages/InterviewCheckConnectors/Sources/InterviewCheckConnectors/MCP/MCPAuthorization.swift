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
        let probe = MCPProbe(transport: transport)
        let (_, response) = try await probe.send(method: "POST", url: server, body: Data("{}".utf8))
        var authorizationServer = origin(server)
        var scopes: [String] = []
        if let metadata = resourceMetadataURL(response) ?? URL(string: "\(origin(server))/.well-known/oauth-protected-resource\(server.path)"),
           let json = await probe.json(at: metadata) {
            if let first = json["authorization_servers"][0].string { authorizationServer = first }
            scopes = json["scopes_supported"].array.compactMap(\.string)
        }
        var rejected = false
        for candidate in metadataURLs(for: authorizationServer) {
            guard let json = await probe.json(at: candidate), let authorize = json["authorization_endpoint"].url,
                  let token = json["token_endpoint"].url else { continue }
            // Every address must be https (the sign-in page is opened in the
            // browser). The code and PKCE verifier go only to the token endpoint,
            // so it and registration must be on the authorization server's own
            // host, as must the issuer; the sign-in page may be elsewhere (RFC 8414).
            let host = URL(string: authorizationServer)?.host?.lowercased()
            let https = { (url: URL) in url.scheme?.lowercased() == "https" }
            let onServer = { (url: URL) in https(url) && url.host?.lowercased() == host }
            let issuerHost = json["issuer"].url?.host?.lowercased()
            guard host != nil, https(authorize), onServer(token), issuerHost == nil || issuerHost == host else {
                rejected = true
                continue
            }
            // Only the scopes the MCP resource asks for: requesting everything the
            // authorization server knows can be refused (invalid_scope).
            return Endpoints(authorizeURL: authorize, tokenURL: token,
                             registrationURL: json["registration_endpoint"].url.flatMap { onServer($0) ? $0 : nil },
                             scopes: scopes)
        }
        throw ConnectorError.unsupported(rejected
            ? "This MCP server's sign-in addresses are not https on its authorization server. Paste a token instead."
            : "This MCP server does not publish OAuth sign-in details. Paste a token instead.")
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

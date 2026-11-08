import CryptoKit
import Foundation

/// Tokens from an OAuth 2.0 sign-in.
public struct OAuthTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scope: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    /// Expired, or about to expire within a minute.
    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < 60
    }
}

/// An OAuth 2.0 authorization-code provider (Google, Microsoft, Zoom, ...).
public struct OAuthProvider: Equatable, Sendable {
    public var authorizeURL: URL
    public var tokenURL: URL
    public var scopes: [String]
    public var extraParameters: [String: String]
    /// Some providers want the client id and secret as Basic auth on the
    /// token call (Zoom) instead of form fields.
    public var basicAuthOnTokenCall: Bool
    /// Microsoft wants the scopes again on the token calls.
    public var scopeOnTokenCalls: Bool

    public init(authorizeURL: URL, tokenURL: URL, scopes: [String], extraParameters: [String: String] = [:],
                basicAuthOnTokenCall: Bool = false, scopeOnTokenCalls: Bool = false) {
        self.authorizeURL = authorizeURL
        self.tokenURL = tokenURL
        self.scopes = scopes
        self.extraParameters = extraParameters
        self.basicAuthOnTokenCall = basicAuthOnTokenCall
        self.scopeOnTokenCalls = scopeOnTokenCalls
    }
}

/// PKCE (RFC 7636) verifier and S256 challenge.
public enum PKCE {
    public static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Builds the sign-in URL and exchanges or refreshes tokens.
public struct OAuthClient: Sendable {
    public var provider: OAuthProvider
    public var clientID: String
    public var clientSecret: String?
    public var transport: HTTPTransport
    public var now: @Sendable () -> Date = { Date() }

    public init(provider: OAuthProvider, clientID: String, clientSecret: String? = nil,
                transport: HTTPTransport = URLSession.shared) {
        self.provider = provider
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.transport = transport
    }

    public func authorizationURL(redirectURI: URL, state: String, codeChallenge: String) -> URL {
        var components = URLComponents(url: provider.authorizeURL, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if !provider.scopes.isEmpty { items.append(URLQueryItem(name: "scope", value: provider.scopes.joined(separator: " "))) }
        items += provider.extraParameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items
        return components.url!
    }

    public func exchange(code: String, verifier: String, redirectURI: URL) async throws -> OAuthTokens {
        try await tokenCall([
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
            "redirect_uri": redirectURI.absoluteString,
        ], previous: nil)
    }

    public func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else { throw ConnectorError.unauthorized }
        return try await tokenCall(["grant_type": "refresh_token", "refresh_token": refreshToken], previous: tokens)
    }

    /// The tokens, refreshed first when they are about to expire.
    public func fresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        tokens.isExpired(now: now()) ? try await refresh(tokens) : tokens
    }

    private func tokenCall(_ fields: [String: String], previous: OAuthTokens?) async throws -> OAuthTokens {
        var fields = fields
        var client = APIClient(baseURL: provider.tokenURL, transport: transport)
        client.maxRetries = 1
        // Public clients (no secret) send only the client id; confidential
        // ones send the secret as Basic auth or as a form field.
        if provider.basicAuthOnTokenCall, let clientSecret, !clientSecret.isEmpty {
            client.headers["Authorization"] = APIClient.basic(clientID, clientSecret)
        } else {
            fields["client_id"] = clientID
            if let clientSecret, !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
        }
        if provider.scopeOnTokenCalls, !provider.scopes.isEmpty { fields["scope"] = provider.scopes.joined(separator: " ") }
        let json: JSONValue
        do {
            json = try await client.postForm(provider.tokenURL.absoluteString, fields: fields)
        } catch ConnectorError.http(400, _) {
            throw ConnectorError.unauthorized
        }
        guard let access = json["access_token"].string else { throw ConnectorError.invalidResponse("no access_token") }
        return OAuthTokens(
            accessToken: access,
            // Providers may omit the refresh token on refresh: keep the old one.
            refreshToken: json["refresh_token"].string ?? previous?.refreshToken,
            expiresAt: json["expires_in"].double.map { now().addingTimeInterval($0) },
            scope: json["scope"].string ?? previous?.scope
        )
    }
}

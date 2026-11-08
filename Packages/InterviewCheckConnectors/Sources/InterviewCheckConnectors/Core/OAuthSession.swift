import Foundation

/// Hands out a valid access token, refreshing it when needed and reporting
/// new tokens so the app can save them.
public actor OAuthSession {
    private var tokens: OAuthTokens
    private let client: OAuthClient
    private let onUpdate: @Sendable (OAuthTokens) -> Void

    public init(tokens: OAuthTokens, client: OAuthClient, onUpdate: @escaping @Sendable (OAuthTokens) -> Void) {
        self.tokens = tokens
        self.client = client
        self.onUpdate = onUpdate
    }

    public func accessToken() async throws -> String {
        let fresh = try await client.fresh(tokens)
        if fresh != tokens {
            tokens = fresh
            onUpdate(fresh)
        }
        return fresh.accessToken
    }
}

/// How OAuth connectors get a bearer token.
public typealias AccessTokenProvider = @Sendable () async throws -> String

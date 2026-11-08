import Foundation

/// Hands out a valid access token, refreshing it when needed and reporting
/// new tokens so the app can save them.
public actor OAuthSession {
    private var tokens: OAuthTokens
    private let client: OAuthClient
    private let onUpdate: @Sendable (OAuthTokens) -> Void
    /// One refresh at a time: callers that arrive meanwhile share it, so a
    /// rotating refresh token is never spent twice.
    private var refreshing: Task<OAuthTokens, Error>?

    public init(tokens: OAuthTokens, client: OAuthClient, onUpdate: @escaping @Sendable (OAuthTokens) -> Void) {
        self.tokens = tokens
        self.client = client
        self.onUpdate = onUpdate
    }

    public func accessToken() async throws -> String {
        guard tokens.isExpired(now: client.now()) else { return tokens.accessToken }
        if let refreshing { return try await refreshing.value.accessToken }
        let current = tokens
        let task = Task { [client] in try await client.refresh(current) }
        refreshing = task
        defer { refreshing = nil }
        let fresh = try await task.value
        tokens = fresh
        onUpdate(fresh)
        return fresh.accessToken
    }
}

/// How OAuth connectors get a bearer token.
public typealias AccessTokenProvider = @Sendable () async throws -> String

import Foundation

/// OAuth 2.0 client-credentials tokens (Greenhouse Harvest v3, Personio):
/// fetched on first use and again shortly before they expire.
public actor ClientCredentialsToken {
    private let tokenURL: URL
    private let clientID: String
    private let clientSecret: String
    private let extraFields: [String: String]
    private let basicAuth: Bool
    private let transport: HTTPTransport
    private var cached: OAuthTokens?

    public init(tokenURL: URL, clientID: String, clientSecret: String, extraFields: [String: String] = [:],
                basicAuth: Bool = true, transport: HTTPTransport) {
        self.tokenURL = tokenURL
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.extraFields = extraFields
        self.basicAuth = basicAuth
        self.transport = transport
    }

    public func accessToken() async throws -> String {
        if let cached, !cached.isExpired() { return cached.accessToken }
        var client = APIClient(baseURL: tokenURL, transport: transport)
        client.maxRetries = 1
        var fields = extraFields
        fields["grant_type"] = "client_credentials"
        if basicAuth {
            client.headers["Authorization"] = APIClient.basic(clientID, clientSecret)
        } else {
            fields["client_id"] = clientID
            fields["client_secret"] = clientSecret
        }
        let json: JSONValue
        do {
            json = try await client.postForm(tokenURL.absoluteString, fields: fields)
        } catch ConnectorError.http(400, _) {
            throw ConnectorError.unauthorized
        }
        guard let access = json["access_token"].string ?? json.at("data.token").string else {
            throw ConnectorError.invalidResponse("no access token")
        }
        let token = OAuthTokens(accessToken: access, expiresAt: Date().addingTimeInterval(json["expires_in"].double ?? 3000))
        cached = token
        return token.accessToken
    }
}

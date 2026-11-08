import Foundation
import InterviewCheckConnectors

extension ConnectorManager {
    /// MCP servers: a pasted token connects directly; otherwise the server's
    /// OAuth details are discovered, this app registers itself as a public
    /// client, and the interviewer signs in in the browser.
    func signInMCP(_ kind: ConnectorKind, fields: [String: String]) async throws {
        var fields = fields
        guard let server = URL(string: fields["url"].flatMap { $0.isEmpty ? nil : $0 } ?? MCPPresets.url(for: kind) ?? ""),
              server.scheme == "https" else { throw ConnectorError.missingCredential("the server's https URL") }
        fields["url"] = server.absoluteString
        if let token = fields["token"], !token.trimmingCharacters(in: .whitespaces).isEmpty {
            try await connect(kind, fields: fields)
            return
        }
        let endpoints = try await MCPAuthorization.discover(server: server, transport: transport)
        let receiver = try LoopbackReceiver()
        defer { receiver.stop() }
        let redirect = try await receiver.start()
        guard let registration = endpoints.registrationURL else {
            throw ConnectorError.unsupported("This server needs a client registered by its admin. Ask them for a token and paste it.")
        }
        let clientID = try await MCPAuthorization.register(at: registration, redirectURI: redirect, transport: transport)
        let client = OAuthClient(provider: MCPAuthorization.provider(endpoints, server: server), clientID: clientID, transport: transport)
        let verifier = PKCE.verifier()
        let state = UUID().uuidString
        openURL(client.authorizationURL(redirectURI: redirect, state: state, codeChallenge: PKCE.challenge(for: verifier)))
        let code = try LoopbackReceiver.code(from: try await receiver.waitForCallback(), expectedState: state)
        let tokens = try await client.exchange(code: code, verifier: verifier, redirectURI: redirect)
        fields["clientID"] = clientID
        fields["authorizeURL"] = endpoints.authorizeURL.absoluteString
        fields["tokenURL"] = endpoints.tokenURL.absoluteString
        fields["scopes"] = endpoints.scopes.joined(separator: " ")
        try store.save(ConnectorCredentials(fields: fields, tokens: tokens), for: kind.rawValue)
        sessions[kind] = nil
        let label = try await makeConnector(kind).verify()
        upsert(Account(kind: kind, label: label, connectedAt: now()))
        await sync(kind)
    }

    /// The saved provider for an MCP sign-in, for refreshing its token.
    static func mcpProvider(_ credentials: ConnectorCredentials) -> OAuthProvider? {
        guard let authorize = credentials["authorizeURL"].flatMap(URL.init(string:)),
              let token = credentials["tokenURL"].flatMap(URL.init(string:)),
              let server = credentials["url"].flatMap(URL.init(string:)) else { return nil }
        let endpoints = MCPAuthorization.Endpoints(authorizeURL: authorize, tokenURL: token, registrationURL: nil,
                                                   scopes: credentials["scopes"]?.split(separator: " ").map(String.init) ?? [])
        return MCPAuthorization.provider(endpoints, server: server)
    }

    /// The tools an MCP account offers, for the Connections screen.
    func mcpTools(_ kind: ConnectorKind) async -> [MCPClient.Tool] {
        guard let connector = try? makeConnector(kind) as? MCPConnector else { return [] }
        return (try? await connector.tools()) ?? []
    }
}

import Foundation

/// OAuth endpoints and scopes for the meeting platforms. Each company uses
/// its own OAuth app (client ID), so nothing here is a secret.
public enum GoogleConnectorProvider {
    /// Calendar and Meet scopes are "sensitive"; Gmail and Drive would be
    /// "restricted" (security assessment), so they are not requested.
    public static let provider = OAuthProvider(
        authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
        scopes: ["openid", "email",
                 "https://www.googleapis.com/auth/calendar.events.readonly",
                 "https://www.googleapis.com/auth/meetings.space.readonly"],
        extraParameters: ["access_type": "offline", "prompt": "consent"]
    )
}

public enum MicrosoftConnectorProvider {
    public static let baseScopes = ["offline_access", "User.Read", "Calendars.Read", "OnlineMeetings.Read"]
    /// Need a tenant admin's consent.
    public static let transcriptScopes = ["OnlineMeetingTranscript.Read.All", "OnlineMeetingRecording.Read.All"]

    /// Shared calendars (another person's or a team's) need Calendars.Read.Shared,
    /// asked for only when other calendars are named.
    public static func provider(tenant: String = "organizations", transcripts: Bool = false,
                                sharedCalendars: Bool = false, mail: Bool = false) -> OAuthProvider {
        OAuthProvider(authorizeURL: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize")!,
                      tokenURL: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!,
                      scopes: baseScopes + (sharedCalendars ? ["Calendars.Read.Shared"] : []) + (mail ? ["Mail.Read"] : [])
                        + (transcripts ? transcriptScopes : []),
                      scopeOnTokenCalls: true)
    }

    public static func provider(_ credentials: ConnectorCredentials) -> OAuthProvider {
        provider(tenant: credentials["tenant"] ?? "organizations", transcripts: credentials["transcripts"] == "true",
                 sharedCalendars: !OtherCalendars.list(credentials).isEmpty, mail: credentials["mailResumes"] == "true")
    }
}

public enum ZoomConnectorProvider {
    /// Zoom takes its scopes from the app's settings, not the request.
    public static let provider = OAuthProvider(
        authorizeURL: URL(string: "https://zoom.us/oauth/authorize")!,
        tokenURL: URL(string: "https://zoom.us/oauth/token")!,
        scopes: [],
        basicAuthOnTokenCall: true
    )
}

/// Where each OAuth connector signs in, from its saved settings.
public enum ConnectorOAuth {
    /// Vendors that match redirect URIs exactly, port included, get this port:
    /// http://127.0.0.1:53871/callback.
    public static let fixedRedirectPort: UInt16 = 53_871

    public static func provider(_ kind: ConnectorKind, _ credentials: ConnectorCredentials) -> OAuthProvider? {
        switch kind {
        case .microsoft365: return MicrosoftConnectorProvider.provider(credentials)
        case .bullhorn: return BullhornConnectorProvider.provider(credentials)
        default:
            if case .oauth(let provider, _) = kind.descriptor.auth { return provider }
            return nil
        }
    }

    /// 0 lets the system pick a port (loopback redirects with any port).
    public static func redirectPort(_ kind: ConnectorKind) -> UInt16 {
        [.webex, .bullhorn, .jobAdder].contains(kind) ? fixedRedirectPort : 0
    }

    /// Settings looked up before the browser opens (Bullhorn's data center).
    public static func prepareSignIn(_ kind: ConnectorKind, fields: [String: String],
                                     transport: HTTPTransport) async throws -> [String: String] {
        guard kind == .bullhorn else { return fields }
        guard let username = fields["username"]?.trimmingCharacters(in: .whitespaces), !username.isEmpty else {
            throw ConnectorError.missingCredential("API user name")
        }
        let located = try await BullhornConnectorProvider.locate(username: username, transport: transport)
        var updated = fields
        updated["oauthURL"] = located.oauthURL
        updated["restURL"] = located.restURL
        return updated
    }
}

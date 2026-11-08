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

    public static func provider(tenant: String = "organizations", transcripts: Bool = false) -> OAuthProvider {
        OAuthProvider(authorizeURL: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize")!,
                      tokenURL: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!,
                      scopes: baseScopes + (transcripts ? transcriptScopes : []),
                      scopeOnTokenCalls: true)
    }

    public static func provider(_ credentials: ConnectorCredentials) -> OAuthProvider {
        provider(tenant: credentials["tenant"] ?? "organizations", transcripts: credentials["transcripts"] == "true")
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

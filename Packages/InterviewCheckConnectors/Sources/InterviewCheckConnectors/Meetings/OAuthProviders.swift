import Foundation

/// OAuth endpoints and scopes for the meeting platforms. Each company uses
/// its own OAuth app (client ID), so nothing here is a secret.
public enum GoogleConnector {
    public static let provider = OAuthProvider(
        authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
        scopes: ["openid", "email",
                 "https://www.googleapis.com/auth/calendar.readonly",
                 "https://www.googleapis.com/auth/gmail.readonly",
                 "https://www.googleapis.com/auth/meetings.space.readonly",
                 "https://www.googleapis.com/auth/drive.readonly"],
        extraParameters: ["access_type": "offline", "prompt": "consent"]
    )
}

public enum MicrosoftConnector {
    public static let scopes = ["offline_access", "User.Read", "Calendars.Read", "Mail.Read", "OnlineMeetings.Read",
                                "OnlineMeetingTranscript.Read.All", "OnlineMeetingRecording.Read.All"]

    public static func provider(tenant: String = "organizations") -> OAuthProvider {
        OAuthProvider(authorizeURL: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize")!,
                      tokenURL: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!,
                      scopes: scopes)
    }

    public static let provider = provider()
}

public enum ZoomConnector {
    public static let provider = OAuthProvider(
        authorizeURL: URL(string: "https://zoom.us/oauth/authorize")!,
        tokenURL: URL(string: "https://zoom.us/oauth/token")!,
        scopes: [],
        basicAuthOnTokenCall: true
    )
}

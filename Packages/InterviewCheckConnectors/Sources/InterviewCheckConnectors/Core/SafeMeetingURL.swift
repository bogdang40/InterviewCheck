import Foundation

/// A meeting link that may be handed to the system to open. Links come from
/// ATS, calendar and mail data, so anything but https (file, smb, custom app
/// schemes) is refused; only a known meeting platform may open without a click.
public struct SafeMeetingURL: Equatable, Hashable, Sendable {
    public let url: URL
    public let platform: MeetingLinks.Platform

    public init?(_ url: URL?) {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        self.url = url
        self.platform = MeetingLinks.platform(of: url)
    }

    /// Zoom, Meet, Teams or Webex: safe to open on a schedule or from a link.
    public var opensAutomatically: Bool { platform != .other }
}

public extension ExternalInterview {
    /// The meeting link when it is safe to open; nil for any other scheme.
    var safeMeetingLink: SafeMeetingURL? { SafeMeetingURL(meetingURL) }
}

import Foundation

/// Finds video-meeting links in event text (location, notes, invites).
public enum MeetingLinks {
    public enum Platform: String, Codable, Sendable { case zoom, googleMeet, teams, webex, other

        public var title: String {
            switch self {
            case .zoom: return "Zoom"
            case .googleMeet: return "Google Meet"
            case .teams: return "Microsoft Teams"
            case .webex: return "Webex"
            case .other: return "Video call"
            }
        }
    }

    private static let patterns: [(Platform, String)] = [
        (.zoom, #"https://(?:[\w-]+\.)?zoom(?:gov)?\.us/(?:j|my|w|s)/[^\s<>"')\]]+"#),
        (.googleMeet, #"https://meet\.google\.com/[a-z]{3,4}-[a-z]{4}-[a-z]{3,4}(?:\?[^\s<>"')\]]*)?"#),
        (.googleMeet, #"https://meet\.google\.com/lookup/[^\s<>"')\]]+"#),
        (.teams, #"https://teams\.microsoft\.com/l/meetup-join/[^\s<>"')\]]+"#),
        (.teams, #"https://teams\.live\.com/meet/[^\s<>"')\]]+"#),
        (.teams, #"https://teams\.microsoft\.com/meet/[^\s<>"')\]]+"#),
        (.webex, #"https://[\w-]+\.webex\.com/(?:meet|join|[\w-]+/j\.php)[^\s<>"')\]]*"#),
    ]

    /// The first meeting link in any of the texts, searched in order.
    public static func first(in texts: [String?]) -> URL? {
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            var best: (range: Range<String.Index>, url: URL)?
            for (_, pattern) in patterns {
                guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
                      let url = URL(string: String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;>"))) else { continue }
                if best == nil || range.lowerBound < best!.range.lowerBound { best = (range, url) }
            }
            if let best { return best.url }
        }
        return nil
    }

    public static func platform(of url: URL) -> Platform {
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix("zoom.us") || host.hasSuffix("zoomgov.us") { return .zoom }
        if host == "meet.google.com" { return .googleMeet }
        if host.hasSuffix("teams.microsoft.com") || host.hasSuffix("teams.live.com") { return .teams }
        if host.hasSuffix("webex.com") { return .webex }
        return .other
    }
}

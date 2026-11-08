import Foundation

/// Interviews from calendar feeds: the secret iCal (.ics) address that
/// Google Calendar, Outlook, iCloud, Fastmail and many schedulers publish.
/// No sign-in and no admin: the address itself is the key, kept in the Keychain.
public struct CalendarFeedConnector: InterviewSource {
    public let kind = ConnectorKind.icsFeed
    let feeds: [URL]
    let keywords: [String]
    let everyEvent: Bool
    let transport: HTTPTransport
    /// A feed larger than this is refused (years of history can run to tens of MB).
    static let maxBytes = 25 * 1024 * 1024

    public init(credentials: ConnectorCredentials, transport: HTTPTransport) throws {
        let typed = (credentials["url"] ?? "").split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        let feeds = try typed.map(Self.feedURL)
        guard !feeds.isEmpty else { throw ConnectorError.missingCredential("calendar feed address") }
        self.feeds = feeds
        keywords = BookingFilter.keywords(credentials)
        everyEvent = credentials["everyEvent"] == "true"
        self.transport = transport
    }

    /// webcal:// is the same feed over https; plain http is refused (the
    /// address is a secret).
    static func feedURL(_ text: String) throws -> URL {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("webcal://") { value = "https://" + value.dropFirst("webcal://".count) }
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil else {
            throw ConnectorError.missingCredential("calendar feed address starting with https:// or webcal://")
        }
        return url
    }

    public func verify() async throws -> String {
        var events = 0
        for feed in feeds { events += try await self.events(feed).count }
        return "\(feeds.count == 1 ? feeds[0].host ?? "Calendar feed" : "\(feeds.count) feeds") \u{00B7} \(events) events"
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        // A feed that cannot be read fails the sync, so the interviews from the
        // last good sync are kept instead of disappearing (offline, a dead feed).
        var found: [CalendarEvent] = []
        for feed in feeds {
            do {
                found += try await events(feed)
            } catch {
                throw feeds.count > 1
                    ? ConnectorError.unsupported("The feed on \(feed.host ?? "a calendar") could not be read: \(error.localizedDescription)")
                    : error
            }
        }
        var seen = Set<String>()
        return found
            .filter { !$0.isCancelled && $0.startsAt >= start && $0.startsAt <= end && seen.insert($0.id).inserted }
            .filter { everyEvent || InterviewEventClassifier.isInterview($0, extraKeywords: keywords) }
            .map { InterviewEventClassifier.interview(from: $0, source: .icsFeed) }
            .sorted { $0.startsAt < $1.startsAt }
    }

    private func events(_ feed: URL) async throws -> [CalendarEvent] {
        var request = URLRequest(url: feed)
        request.setValue("text/calendar", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw ConnectorError.unauthorized
        case 404: throw ConnectorError.unsupported("The calendar feed address was not found. It may have been reset; copy it again.")
        default: throw ConnectorError.http(response.statusCode, "")
        }
        guard data.count <= Self.maxBytes else { throw ConnectorError.invalidResponse("the feed is larger than 25 MB") }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              text.contains("BEGIN:VCALENDAR") else {
            throw ConnectorError.invalidResponse("not a calendar feed")
        }
        return ICSParser.events(in: text)
    }
}

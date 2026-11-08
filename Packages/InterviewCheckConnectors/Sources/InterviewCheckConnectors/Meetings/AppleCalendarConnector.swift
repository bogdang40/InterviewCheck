import EventKit
import Foundation

/// Interviews from the calendars this Mac already syncs (iCloud, Google,
/// Exchange): no keys, just Calendar permission.
public struct AppleCalendarConnector: InterviewSource {
    public let kind = ConnectorKind.appleCalendar
    public var extraKeywords: [String]
    private let store: EKEventStore

    public init(extraKeywords: [String] = [], store: EKEventStore = EKEventStore()) {
        self.extraKeywords = extraKeywords
        self.store = store
    }

    public static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    public static func requestAccess(store: EKEventStore = EKEventStore()) async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func verify() async throws -> String {
        var allowed = Self.hasAccess
        if !allowed { allowed = await Self.requestAccess(store: store) }
        guard allowed else {
            throw ConnectorError.forbidden("allow Calendar in System Settings \u{203A} Privacy & Security \u{203A} Calendars")
        }
        let count = store.calendars(for: .event).count
        return "\(count) calendar\(count == 1 ? "" : "s")"
    }

    public func upcomingInterviews(from start: Date, to end: Date) async throws -> [ExternalInterview] {
        guard Self.hasAccess else { throw ConnectorError.forbidden("Calendar access") }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .map(Self.calendarEvent)
            .filter { InterviewEventClassifier.isInterview($0, extraKeywords: extraKeywords) }
            .map { InterviewEventClassifier.interview(from: $0, source: .appleCalendar) }
    }

    static func calendarEvent(_ event: EKEvent) -> CalendarEvent {
        let person = { (participant: EKParticipant) -> ExternalPerson in
            let email = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            return ExternalPerson(name: participant.name ?? email, email: email.contains("@") ? email : nil)
        }
        let start = event.startDate ?? Date()
        return CalendarEvent(
            id: "\(event.calendarItemIdentifier)@\(Int(start.timeIntervalSince1970))",
            title: event.title ?? "",
            startsAt: start,
            endsAt: event.endDate,
            location: event.location,
            notes: event.notes,
            url: event.url,
            organizer: event.organizer.map(person),
            attendees: (event.attendees ?? []).map(person)
        )
    }
}

/// Interviews from .ics invite files the interviewer drops in.
public enum InviteFileImporter {
    public static func interviews(from url: URL) throws -> [ExternalInterview] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw ConnectorError.invalidResponse("not a readable .ics file")
        }
        let events = ICSParser.events(in: text)
        guard !events.isEmpty else { throw ConnectorError.invalidResponse("no events in the invite") }
        return events.map { InterviewEventClassifier.interview(from: $0, source: .icsFile) }
    }
}

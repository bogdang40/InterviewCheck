import Foundation

/// Reads VEVENTs from an iCalendar (.ics) invite, as attached to interview
/// emails by every ATS and calendar.
public enum ICSParser {
    public static func events(in text: String) -> [CalendarEvent] {
        // Unfold continuation lines (RFC 5545 3.1).
        let unfolded = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")
        var found: [[(name: String, params: [String: String], value: String)]] = []
        var current: [(name: String, params: [String: String], value: String)]?
        var method: String?
        var nested = 0
        for line in unfolded.components(separatedBy: "\n") {
            if line == "BEGIN:VEVENT" { current = []; continue }
            if line == "END:VEVENT" {
                if let fields = current { found.append(fields) }
                current = nil
                continue
            }
            // An alarm inside the event has its own DESCRIPTION and SUMMARY.
            if current != nil, line.hasPrefix("BEGIN:") { nested += 1; continue }
            if current != nil, line.hasPrefix("END:") { nested = max(0, nested - 1); continue }
            if current == nil, line.uppercased().hasPrefix("METHOD:") {
                method = line.dropFirst(7).trimmingCharacters(in: .whitespaces).uppercased()
                continue
            }
            guard current != nil, nested == 0, let colon = valueSeparator(in: line) else { continue }
            let head = line[..<colon].split(separator: ";").map(String.init)
            var params: [String: String] = [:]
            for param in head.dropFirst() {
                let pair = param.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { params[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            }
            current?.append((head.first?.uppercased() ?? "", params, String(line[line.index(after: colon)...])))
        }
        return found.compactMap { event(from: $0, method: method) }
    }

    private static func event(from fields: [(name: String, params: [String: String], value: String)],
                              method: String?) -> CalendarEvent? {
        func field(_ name: String) -> (params: [String: String], value: String)? {
            fields.first { $0.name == name }.map { ($0.params, $0.value) }
        }
        let cancelled = method == "CANCEL" || field("STATUS")?.value.uppercased() == "CANCELLED"
        // A cancellation may leave out the time (RFC 5546); it still cancels the UID.
        let startsAt = field("DTSTART").flatMap { date($0.value, params: $0.params) } ?? (cancelled ? Date.distantPast : nil)
        guard let startsAt, field("DTSTART") != nil || field("UID") != nil else { return nil }
        let person = { (entry: (params: [String: String], value: String)) -> ExternalPerson in
            let email = entry.value.replacingOccurrences(of: "(?i)^mailto:", with: "", options: .regularExpression)
            return ExternalPerson(name: entry.params["CN"].map(unescape) ?? email, email: email.contains("@") ? email : nil)
        }
        return CalendarEvent(
            id: field("UID")?.value ?? UUID().uuidString,
            title: unescape(field("SUMMARY")?.value ?? ""),
            startsAt: startsAt,
            endsAt: field("DTEND").flatMap { date($0.value, params: $0.params) },
            location: field("LOCATION").map { unescape($0.value) },
            notes: field("DESCRIPTION").map { unescape($0.value) },
            url: field("URL").flatMap { URL(string: $0.value) },
            organizer: field("ORGANIZER").map(person),
            attendees: fields.filter { $0.name == "ATTENDEE" }.map { person(($0.params, $0.value)) },
            isCancelled: cancelled,
            sequence: field("SEQUENCE").flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) } ?? 0,
            method: method,
            isAllDay: field("DTSTART").map { $0.value.count == 8 || $0.params["VALUE"] == "DATE" } ?? false
        )
    }

    static func date(_ value: String, params: [String: String]) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if value.hasSuffix("Z") {
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        } else if value.count == 8 {
            formatter.timeZone = .current
            formatter.dateFormat = "yyyyMMdd"
        } else {
            formatter.timeZone = params["TZID"].flatMap(WindowsTimeZones.zone) ?? .current
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        }
        return formatter.date(from: value)
    }

    /// The colon that starts the value: the first one outside quoted
    /// parameters (`ORGANIZER;SENT-BY="mailto:a@b.com":mailto:c@d.com`).
    static func valueSeparator(in line: String) -> String.Index? {
        var quoted = false
        for index in line.indices {
            if line[index] == "\"" { quoted.toggle() }
            if line[index] == ":", !quoted { return index }
        }
        return nil
    }

    static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

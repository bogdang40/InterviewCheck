import Foundation

/// The "Other calendars" field: extra calendars read for interviews.
enum OtherCalendars {
    static func list(_ credentials: ConnectorCredentials) -> [String] {
        credentials["calendars"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
    }
}

import Foundation

/// Labels for a session row: a short date, the duration, and count phrases.
enum SessionCardFormatter {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// Time only for sessions started today, date and time otherwise.
    static func dateLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return timeFormatter.string(from: date)
        }
        return dateTimeFormatter.string(from: date)
    }

    /// A missing end timestamp can mean an interrupted app, not a live session.
    static func durationLabel(startedAt: Date, endedAt: Date?, isActive: Bool = false) -> String {
        if isActive { return "Active" }
        guard let endedAt else { return "Unfinished" }
        let total = max(Int(endedAt.timeIntervalSince(startedAt)), 0)
        return String(format: "%dm %02ds", total / 60, total % 60)
    }

    static func countLabel(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}

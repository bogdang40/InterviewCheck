import Foundation

/// "Today, 3:00 PM · in 25 min", "Tomorrow, 9:00 AM", "Mon 9 Nov, 10:30 AM".
enum UpcomingTime {
    static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Today, \(time)"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            day = "Tomorrow, \(time)"
        } else {
            day = "\(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))), \(time)"
        }
        let minutes = Int(date.timeIntervalSince(now) / 60)
        if minutes >= 0, minutes < 120 { return "\(day) \u{00B7} in \(minutes) min" }
        if minutes < 0, date.timeIntervalSince(now) > -3 * 3600 { return "\(day) \u{00B7} started \(-minutes) min ago" }
        return day
    }

    static func isSoon(_ date: Date, now: Date = Date()) -> Bool {
        (-15 * 60...60 * 60).contains(date.timeIntervalSince(now))
    }
}

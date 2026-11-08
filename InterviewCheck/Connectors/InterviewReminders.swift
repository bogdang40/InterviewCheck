import AppKit
import InterviewCheckConnectors
import UserNotifications

/// A notification a few minutes before each upcoming interview; clicking it
/// (or Prepare) opens the app with the candidate, role and résumé filled in.
@MainActor
final class InterviewReminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = InterviewReminders()
    static let minutesKey = "interviewcheck.reminderMinutes"
    static let choices = [0, 5, 10, 15, 30]
    private static let prefix = "interview."
    private static let category = "interviewcheck.upcoming"
    private static let prepareAction = "prepare"

    /// Minutes before the start; 0 turns reminders off.
    static var minutes: Int {
        get { AppDefaults.standard.object(forKey: minutesKey) as? Int ?? 10 }
        set { AppDefaults.standard.set(newValue, forKey: minutesKey) }
    }

    private var center: UNUserNotificationCenter { .current() }

    func install() {
        center.delegate = self
        let prepare = UNNotificationAction(identifier: Self.prepareAction, title: "Prepare", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [prepare],
                                                                 intentIdentifiers: [])])
    }

    /// Replaces the pending reminders with ones for these interviews.
    func schedule(_ interviews: [ExternalInterview], now: Date = Date()) {
        let minutes = Self.minutes
        Task {
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
            center.removePendingNotificationRequests(withIdentifiers: pending)
            guard minutes > 0 else { return }
            let due = Self.requests(for: interviews, minutes: minutes, now: now)
            guard !due.isEmpty else { return }
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            } else if settings.authorizationStatus == .denied {
                return
            }
            for request in due { try? await center.add(request) }
        }
    }

    /// One request per interview that has not started yet, at most 30.
    static func requests(for interviews: [ExternalInterview], minutes: Int, now: Date) -> [UNNotificationRequest] {
        interviews.filter { $0.startsAt.addingTimeInterval(-Double(minutes) * 60) > now }.prefix(30).map { interview in
            let content = UNMutableNotificationContent()
            content.title = "Interview in \(minutes) minutes"
            content.body = [interview.candidate?.name ?? interview.title, interview.job?.title]
                .compactMap { $0 }.joined(separator: " \u{00B7} ")
            content.sound = .default
            content.categoryIdentifier = category
            content.userInfo = ["interviewID": interview.id]
            let fire = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                       from: interview.startsAt.addingTimeInterval(-Double(minutes) * 60))
            return UNNotificationRequest(identifier: prefix + interview.id, content: content,
                                         trigger: UNCalendarNotificationTrigger(dateMatching: fire, repeats: false))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["interviewID"] as? String else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            // No window open: a reopen event brings the main window back.
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                NSWorkspace.shared.open(Bundle.main.bundleURL)
            }
            guard let interview = ConnectorManager.shared.upcoming.first(where: { $0.id == id }) else { return }
            Task { await ConnectorManager.shared.prepare(interview, controller: .shared) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

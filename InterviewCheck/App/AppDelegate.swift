import AppKit
import Combine
import SwiftUI

/// App lifecycle for the native app. Windows belong to SwiftUI scenes; this
/// delegate only starts background services, handles billing links, keeps
/// the interview shortcuts in step with the interview, and guards Quit while
/// an interview is recording.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let accessController = AccessController.shared
    private var phaseSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Under XCTest this process is only the test host: no services, and
        // the main window SwiftUI opens is put away so it cannot take focus.
        guard !TestRuntime.isRunningUnitTests else {
            DispatchQueue.main.async { NSApp.windows.forEach { $0.orderOut(nil) } }
            return
        }

        // First touch of the database (schema and migrations) off the main thread.
        let retentionDays = DetectorSettings.shared.retentionDays
        let weights = DetectorSettings.shared.weights
        DispatchQueue.global(qos: .utility).async {
            SessionDatabase.shared.warmUp()
            InterviewRetention.apply(days: retentionDays, database: .shared)
            InterviewRecovery.finishUnended(database: .shared, weights: weights)
        }
        accessController.startPeriodicVerification()
        // Connected ATS, calendars and meeting tools sync now and every 15
        // minutes; each change reschedules the reminders before interviews.
        InterviewReminders.shared.install()
        ConnectorManager.shared.onUpcomingChanged = { InterviewReminders.shared.schedule($0) }
        AutoScorer.shared.onReport = { InterviewReminders.shared.notifyReport($0) }
        ConnectorManager.shared.onSynced = { Task { await AutoScorer.shared.run() } }
        ConnectorManager.shared.startAutoSync()
        AutoPrepare.shared.start()
        Task { @MainActor [weak self] in
            await self?.accessController.evaluate()
        }

        // The two interview shortcuts exist only while an interview is live,
        // and the Dock icon says when one is.
        phaseSubscription = InterviewController.shared.$phase
            .removeDuplicates()
            .sink { phase in
                if phase == .live {
                    GlobalShortcuts.shared.activate()
                } else {
                    GlobalShortcuts.shared.deactivate()
                }
                NSApp.dockTile.badgeLabel = phase == .live ? "Live" : nil
            }
    }

    /// interviewcheck://billing/... from the Stripe return page.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if InterviewAutomation.handle(url) { continue }
            if accessController.handleDeepLink(url) {
                NSLog("[\(AppBrand.name)] Handled access deep link: \(url.absoluteString)")
            }
        }
    }

    /// Right-click on the Dock icon: the next interviews, each with Prepare.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let upcoming = ConnectorManager.shared.upcoming.filter { ($0.endsAt ?? $0.startsAt.addingTimeInterval(3600)) > Date() }
        if !upcoming.isEmpty {
            menu.addItem(withTitle: "Prepare", action: nil, keyEquivalent: "").isEnabled = false
            for interview in upcoming.prefix(5) {
                let title = "\(interview.candidate?.name ?? interview.title) \u{00B7} "
                    + interview.startsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
                let item = NSMenuItem(title: title, action: #selector(prepareFromDock(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = interview.id
                item.indentationLevel = 1
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        if !ConnectorManager.shared.accounts.isEmpty {
            let sync = NSMenuItem(title: "Sync Connections", action: #selector(syncFromDock), keyEquivalent: "")
            sync.target = self
            menu.addItem(sync)
        }
        return menu.items.isEmpty ? nil : menu
    }

    @objc private func prepareFromDock(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String,
              let interview = ConnectorManager.shared.upcoming.first(where: { $0.id == id }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        Task { await InterviewAutomation.prepare(interview) }
    }

    @objc private func syncFromDock() {
        Task { await ConnectorManager.shared.syncAll() }
    }

    /// Closing the window does not quit: an interview may still be running
    /// and the Live Companion may be open. The Dock icon brings it back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Returning true lets SwiftUI reopen the main window.
        !TestRuntime.isRunningUnitTests
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard InterviewController.shared.phase == .live else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "End the interview and quit?"
        alert.informativeText = "The interview is still recording. Ending it saves the report so far."
        alert.addButton(withTitle: "End and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        InterviewController.shared.end()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalShortcuts.shared.deactivate()
        AudioCaptureService.shared.stopCapture()
    }
}

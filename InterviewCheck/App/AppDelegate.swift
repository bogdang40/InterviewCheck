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
        for url in urls where accessController.handleDeepLink(url) {
            NSLog("[\(AppBrand.name)] Handled access deep link: \(url.absoluteString)")
        }
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
